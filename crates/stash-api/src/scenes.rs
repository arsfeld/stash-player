//! Scene queries. Hand-rolled types matching the subset of the Stash schema
//! the UI cares about today.

use serde::{Deserialize, Serialize};

#[derive(Debug, Clone, Copy, PartialEq, Eq, Serialize, Default)]
#[serde(rename_all = "UPPERCASE")]
pub enum SortDirection {
    Asc,
    #[default]
    Desc,
}

impl SortDirection {
    pub fn toggled(self) -> Self {
        match self {
            SortDirection::Asc => SortDirection::Desc,
            SortDirection::Desc => SortDirection::Asc,
        }
    }
}

/// Sort keys we expose in the UI. The string Stash expects on the wire is
/// returned by [`SortKey::as_stash`]; the human label by [`SortKey::label`].
#[derive(Debug, Clone, Copy, PartialEq, Eq, Default)]
pub enum SortKey {
    Date,
    Title,
    Rating,
    PlayCount,
    Duration,
    // Default to "Date added" (Stash's `created_at`) so newly imported
    // scenes surface at the top of the library. Sorting by `date` — the
    // scene's release/content metadata — buries unscraped imports at the
    // bottom because their `date` is NULL.
    #[default]
    CreatedAt,
    UpdatedAt,
    Random,
}

impl SortKey {
    pub const ALL: &'static [SortKey] = &[
        SortKey::Date,
        SortKey::Title,
        SortKey::Rating,
        SortKey::PlayCount,
        SortKey::Duration,
        SortKey::CreatedAt,
        SortKey::UpdatedAt,
        SortKey::Random,
    ];

    pub fn as_stash(self) -> &'static str {
        match self {
            SortKey::Date => "date",
            SortKey::Title => "title",
            SortKey::Rating => "rating",
            SortKey::PlayCount => "play_count",
            SortKey::Duration => "duration",
            SortKey::CreatedAt => "created_at",
            SortKey::UpdatedAt => "updated_at",
            SortKey::Random => "random",
        }
    }

    pub fn label(self) -> &'static str {
        match self {
            SortKey::Date => "Date",
            SortKey::Title => "Title",
            SortKey::Rating => "Rating",
            SortKey::PlayCount => "Play count",
            SortKey::Duration => "Duration",
            SortKey::CreatedAt => "Date added",
            SortKey::UpdatedAt => "Last updated",
            SortKey::Random => "Random",
        }
    }
}

#[derive(Debug, Clone, Default)]
pub struct SceneFilter {
    /// Free-text search applied across title/details/etc by Stash's `q`.
    pub query: Option<String>,
    pub sort: SortKey,
    pub direction: SortDirection,
    /// Minimum rating on Stash's 1–100 scale. The UI exposes 1–5 stars and
    /// converts (1 star = 20, 5 stars = 100).
    pub min_rating: Option<i32>,
    /// `Some(true)` keeps only organized scenes, `Some(false)` keeps only
    /// unorganized; `None` doesn't filter on this field.
    pub organized: Option<bool>,
    /// `Some(true)` keeps only scenes Stash marked interactive (funscript
    /// present), `Some(false)` keeps only non-interactive; `None` doesn't
    /// filter on this field. Wire shape is a plain `Boolean` on Stash's
    /// `SceneFilterType.interactive`, same as `organized`.
    pub interactive: Option<bool>,
    /// When true, restrict results to `o_counter = 0` (untracked scenes).
    /// Maps to Stash's `IntCriterionInput { value: 0, modifier: EQUALS }`.
    pub hide_tracked: bool,
    /// Seed used when `sort == Random` so that paging and prev/next produce
    /// a stable order across requests. Stash treats `random_<seed>` as a
    /// seeded random sort. Ignored when sort isn't Random.
    pub random_seed: Option<u32>,
}

impl SceneFilter {
    pub fn new() -> Self {
        Self {
            query: None,
            sort: SortKey::default(),
            direction: SortDirection::Desc,
            min_rating: None,
            organized: None,
            interactive: None,
            hide_tracked: false,
            random_seed: None,
        }
    }
}

#[derive(Debug, Clone, Deserialize)]
pub struct FindScenesPage {
    pub count: i64,
    pub scenes: Vec<Scene>,
}

#[derive(Debug, Clone, Deserialize)]
pub struct Scene {
    pub id: String,
    pub title: Option<String>,
    pub details: Option<String>,
    pub date: Option<String>,
    pub rating100: Option<i32>,
    pub paths: ScenePaths,
    #[serde(default)]
    pub files: Vec<SceneFile>,
    pub studio: Option<StudioRef>,
    #[serde(default)]
    pub performers: Vec<PerformerRef>,
    /// Stash's saved resume position in seconds. Absent or zero means
    /// "play from the start". Set by `sceneSaveActivity`.
    #[serde(default)]
    pub resume_time: Option<f64>,
    #[serde(default)]
    pub play_count: Option<i32>,
    /// Cumulative wall-clock seconds the user has spent watching this
    /// scene across all sessions. Stash increments this from the
    /// `playDuration` deltas we send via `sceneSaveActivity`.
    #[serde(default)]
    pub play_duration: Option<f64>,
    /// Stash's per-scene "O counter" tally. Bumped via `sceneIncrementO`,
    /// zeroed via `sceneResetO`. Absent or zero means "untracked".
    #[serde(default)]
    pub o_counter: Option<i32>,
}

impl Scene {
    /// Best-effort title for display. Falls back to the first file's
    /// basename (extension stripped) — same fallback Stash's own UI shows
    /// for untitled scenes — and to the scene id only when no file path is
    /// available either.
    pub fn display_title(&self) -> String {
        if let Some(t) = self.title.as_deref()
            && !t.is_empty()
        {
            return t.to_owned();
        }
        if let Some(name) = self
            .files
            .iter()
            .find_map(|f| f.path.as_deref().and_then(filename_stem))
        {
            return name;
        }
        format!("Scene {}", self.id)
    }

    pub fn duration_seconds(&self) -> Option<f64> {
        self.files.first().and_then(|f| f.duration)
    }

    /// Resume position the UI should actually seek to, or `None` to start
    /// from the beginning. Stash saves a `resume_time` near the duration
    /// when the user watches a scene to completion; honouring that on the
    /// next open lands playback at the tail, which immediately fires
    /// end-of-stream (and, on macOS, auto-advances to the next scene).
    /// Treat resumes within the last 10s — or anything past 97% of the
    /// known duration — as "finished, play from the start".
    pub fn effective_resume_secs(&self) -> Option<f64> {
        let resume = self.resume_time?;
        if resume <= 0.0 {
            return None;
        }
        if let Some(duration) = self.duration_seconds()
            && duration > 0.0
            && (resume >= duration - 10.0 || resume / duration >= 0.97)
        {
            return None;
        }
        Some(resume)
    }
}

/// Extract the basename (final path component) of `path`, with any trailing
/// extension stripped. Returns `None` for empty paths or paths whose final
/// component is empty (e.g. trailing separator). Handles both `/` and `\`
/// so Windows-side Stash servers still produce useful labels.
fn filename_stem(path: &str) -> Option<String> {
    let basename = path.rsplit(['/', '\\']).next()?;
    if basename.is_empty() {
        return None;
    }
    let stem = match basename.rsplit_once('.') {
        Some((stem, _ext)) if !stem.is_empty() => stem,
        _ => basename,
    };
    Some(stem.to_owned())
}

#[derive(Debug, Clone, Deserialize)]
pub struct ScenePaths {
    pub screenshot: Option<String>,
    pub preview: Option<String>,
    pub sprite: Option<String>,
    pub stream: Option<String>,
    pub webp: Option<String>,
}

#[derive(Debug, Clone, Deserialize)]
pub struct SceneFile {
    pub duration: Option<f64>,
    pub width: Option<i32>,
    pub height: Option<i32>,
    pub video_codec: Option<String>,
    pub frame_rate: Option<f64>,
    /// Absolute filesystem path Stash sees for this file. Used as the
    /// `display_title` fallback when Stash has no scene title, matching
    /// Stash's own UI behaviour.
    #[serde(default)]
    pub path: Option<String>,
}

#[derive(Debug, Clone, Deserialize)]
pub struct StudioRef {
    pub id: String,
    pub name: String,
}

#[derive(Debug, Clone, Deserialize)]
pub struct PerformerRef {
    pub id: String,
    pub name: String,
}

pub(crate) const FIND_SCENES_QUERY: &str = r#"
query FindScenes($filter: FindFilterType, $scene_filter: SceneFilterType) {
  findScenes(filter: $filter, scene_filter: $scene_filter) {
    count
    scenes {
      id
      title
      details
      date
      rating100
      resume_time
      play_count
      play_duration
      o_counter
      paths { screenshot preview sprite stream webp }
      files { path duration width height video_codec frame_rate }
      studio { id name }
      performers { id name }
    }
  }
}
"#;

#[derive(Deserialize)]
pub(crate) struct FindScenesResponse {
    #[serde(rename = "findScenes")]
    pub find_scenes: FindScenesPage,
}

pub(crate) const FIND_SCENE_QUERY: &str = r#"
query FindScene($id: ID!) {
  findScene(id: $id) {
    id
    title
    details
    date
    rating100
    resume_time
    play_count
    play_duration
    o_counter
    paths { screenshot preview sprite stream webp }
    files { duration width height video_codec frame_rate }
    studio { id name }
    performers { id name }
  }
}
"#;

#[derive(Deserialize)]
pub(crate) struct FindSceneResponse {
    #[serde(rename = "findScene")]
    pub find_scene: Option<Scene>,
}

pub(crate) fn find_scenes_variables(
    filter: &SceneFilter,
    page: u32,
    per_page: u32,
) -> serde_json::Value {
    let sort_value = match (filter.sort, filter.random_seed) {
        (SortKey::Random, Some(seed)) => format!("random_{seed}"),
        (k, _) => k.as_stash().to_string(),
    };
    let mut find_filter = serde_json::json!({
        "page": page,
        "per_page": per_page,
        "sort": sort_value,
        "direction": match filter.direction {
            SortDirection::Asc => "ASC",
            SortDirection::Desc => "DESC",
        },
    });
    if let Some(q) = filter.query.as_deref()
        && !q.is_empty()
    {
        find_filter["q"] = serde_json::Value::String(q.to_owned());
    }

    let mut scene_filter = serde_json::Map::new();
    if let Some(min) = filter.min_rating {
        // Stash IntCriterionInput's GREATER_THAN is exclusive, so subtract 1
        // to get a "≥ min" predicate. Clamp at 0 so we don't produce -1.
        scene_filter.insert(
            "rating100".into(),
            serde_json::json!({
                "value": (min - 1).max(0),
                "modifier": "GREATER_THAN",
            }),
        );
    }
    if let Some(org) = filter.organized {
        scene_filter.insert("organized".into(), serde_json::Value::Bool(org));
    }
    if let Some(interactive) = filter.interactive {
        scene_filter.insert("interactive".into(), serde_json::Value::Bool(interactive));
    }
    if filter.hide_tracked {
        scene_filter.insert(
            "o_counter".into(),
            serde_json::json!({
                "value": 0,
                "modifier": "EQUALS",
            }),
        );
    }

    serde_json::json!({
        "filter": find_filter,
        "scene_filter": serde_json::Value::Object(scene_filter),
    })
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn sort_direction_toggles_round_trip() {
        assert_eq!(SortDirection::Asc.toggled(), SortDirection::Desc);
        assert_eq!(SortDirection::Desc.toggled(), SortDirection::Asc);
        assert_eq!(SortDirection::default(), SortDirection::Desc);
    }

    #[test]
    fn sort_keys_serialize_to_stash_strings() {
        let pairs = [
            (SortKey::Date, "date"),
            (SortKey::Title, "title"),
            (SortKey::Rating, "rating"),
            (SortKey::PlayCount, "play_count"),
            (SortKey::Duration, "duration"),
            (SortKey::CreatedAt, "created_at"),
            (SortKey::UpdatedAt, "updated_at"),
            (SortKey::Random, "random"),
        ];
        for (k, expected) in pairs {
            assert_eq!(k.as_stash(), expected);
        }
        assert_eq!(SortKey::ALL.len(), 8);
    }

    #[test]
    fn variables_default_filter_omits_optional_fields() {
        let f = SceneFilter::new();
        let v = find_scenes_variables(&f, 1, 40);
        assert_eq!(v["filter"]["page"], 1);
        assert_eq!(v["filter"]["per_page"], 40);
        assert_eq!(v["filter"]["sort"], "created_at");
        assert_eq!(v["filter"]["direction"], "DESC");
        assert!(v["filter"].get("q").is_none(), "no q without query");
        assert_eq!(v["scene_filter"], serde_json::json!({}));
    }

    #[test]
    fn variables_query_string_populates_q() {
        let mut f = SceneFilter::new();
        f.query = Some("hello".into());
        let v = find_scenes_variables(&f, 1, 10);
        assert_eq!(v["filter"]["q"], "hello");
    }

    #[test]
    fn variables_empty_query_string_does_not_populate_q() {
        // Empty searches shouldn't send `q: ""`, which Stash treats as a
        // nontrivial filter and may slow down the query.
        let mut f = SceneFilter::new();
        f.query = Some(String::new());
        let v = find_scenes_variables(&f, 1, 10);
        assert!(v["filter"].get("q").is_none());
    }

    #[test]
    fn variables_min_rating_uses_exclusive_greater_than() {
        // Stash's IntCriterion GREATER_THAN is exclusive; the UI exposes
        // 1–5 stars (20/40/60/80/100 on the wire). For a "≥ 60" filter
        // we send GREATER_THAN 59.
        let mut f = SceneFilter::new();
        f.min_rating = Some(60);
        let v = find_scenes_variables(&f, 1, 10);
        assert_eq!(v["scene_filter"]["rating100"]["value"], 59);
        assert_eq!(v["scene_filter"]["rating100"]["modifier"], "GREATER_THAN");
    }

    #[test]
    fn variables_min_rating_zero_does_not_underflow() {
        // The (min - 1) computation must clamp at 0 so we never send -1.
        let mut f = SceneFilter::new();
        f.min_rating = Some(0);
        let v = find_scenes_variables(&f, 1, 10);
        assert_eq!(v["scene_filter"]["rating100"]["value"], 0);
    }

    #[test]
    fn variables_organized_passes_through() {
        let mut f = SceneFilter::new();
        f.organized = Some(false);
        let v = find_scenes_variables(&f, 1, 10);
        assert_eq!(v["scene_filter"]["organized"], false);
    }

    #[test]
    fn variables_interactive_false_excludes_funscript_scenes() {
        // Stash's SceneFilterType.interactive is a plain Boolean (same shape
        // as `organized`), not an IntCriterion. Sending `false` is the
        // "hide interactive scenes" path the library toggle exercises.
        let mut f = SceneFilter::new();
        f.interactive = Some(false);
        let v = find_scenes_variables(&f, 1, 10);
        assert_eq!(v["scene_filter"]["interactive"], false);
    }

    #[test]
    fn variables_interactive_true_keeps_only_funscript_scenes() {
        let mut f = SceneFilter::new();
        f.interactive = Some(true);
        let v = find_scenes_variables(&f, 1, 10);
        assert_eq!(v["scene_filter"]["interactive"], true);
    }

    #[test]
    fn variables_default_filter_omits_interactive() {
        let f = SceneFilter::new();
        let v = find_scenes_variables(&f, 1, 10);
        assert!(v["scene_filter"].get("interactive").is_none());
    }

    #[test]
    fn variables_default_filter_omits_o_counter() {
        let f = SceneFilter::new();
        let v = find_scenes_variables(&f, 1, 10);
        assert!(v["scene_filter"].get("o_counter").is_none());
    }

    #[test]
    fn variables_hide_tracked_filters_o_counter_zero() {
        // Stash IntCriterion EQUALS with value 0 == "untracked scenes only".
        let mut f = SceneFilter::new();
        f.hide_tracked = true;
        let v = find_scenes_variables(&f, 1, 10);
        assert_eq!(v["scene_filter"]["o_counter"]["value"], 0);
        assert_eq!(v["scene_filter"]["o_counter"]["modifier"], "EQUALS");
    }

    #[test]
    fn variables_random_with_seed_emits_random_n() {
        let mut f = SceneFilter::new();
        f.sort = SortKey::Random;
        f.random_seed = Some(2026);
        let v = find_scenes_variables(&f, 1, 10);
        assert_eq!(v["filter"]["sort"], "random_2026");
    }

    #[test]
    fn variables_random_without_seed_falls_back_to_plain_random() {
        let mut f = SceneFilter::new();
        f.sort = SortKey::Random;
        let v = find_scenes_variables(&f, 1, 10);
        assert_eq!(v["filter"]["sort"], "random");
    }

    #[test]
    fn variables_seed_ignored_for_non_random_sorts() {
        let mut f = SceneFilter::new();
        f.sort = SortKey::Title;
        f.random_seed = Some(99);
        let v = find_scenes_variables(&f, 1, 10);
        assert_eq!(v["filter"]["sort"], "title");
    }

    #[test]
    fn scene_display_title_prefers_title_then_filename_then_id() {
        let with_title = Scene {
            id: "9".into(),
            title: Some("Hello".into()),
            details: None,
            date: None,
            rating100: None,
            paths: ScenePaths {
                screenshot: None,
                preview: None,
                sprite: None,
                stream: None,
                webp: None,
            },
            files: vec![],
            studio: None,
            performers: vec![],
            resume_time: None,
            play_count: None,
            play_duration: None,
            o_counter: None,
        };
        assert_eq!(with_title.display_title(), "Hello");

        let mut empty = with_title.clone();
        empty.title = Some(String::new());
        // No file path and an empty-string title — fall through to the
        // id-based label so the UI never shows a blank row.
        assert_eq!(empty.display_title(), "Scene 9");

        let mut none = with_title.clone();
        none.title = None;
        assert_eq!(none.display_title(), "Scene 9");

        // With a file path the fallback prefers the basename (no
        // extension) over the scene id, matching Stash's own UI.
        let with_path = Scene {
            files: vec![SceneFile {
                duration: None,
                width: None,
                height: None,
                video_codec: None,
                frame_rate: None,
                path: Some("/media/library/cool video.mp4".into()),
            }],
            title: None,
            ..with_title.clone()
        };
        assert_eq!(with_path.display_title(), "cool video");
    }

    #[test]
    fn effective_resume_skips_finished_scenes() {
        let base = Scene {
            id: "1".into(),
            title: None,
            details: None,
            date: None,
            rating100: None,
            paths: ScenePaths {
                screenshot: None,
                preview: None,
                sprite: None,
                stream: None,
                webp: None,
            },
            files: vec![SceneFile {
                duration: Some(600.0),
                width: None,
                height: None,
                video_codec: None,
                frame_rate: None,
                path: None,
            }],
            studio: None,
            performers: vec![],
            resume_time: None,
            play_count: None,
            play_duration: None,
            o_counter: None,
        };

        // Fresh / unset → start from the beginning.
        assert_eq!(base.clone().effective_resume_secs(), None);

        let mut zero = base.clone();
        zero.resume_time = Some(0.0);
        assert_eq!(zero.effective_resume_secs(), None);

        // Mid-playback → honour the resume.
        let mut middle = base.clone();
        middle.resume_time = Some(120.0);
        assert_eq!(middle.effective_resume_secs(), Some(120.0));

        // Within the last 10s → treat as finished.
        let mut tail = base.clone();
        tail.resume_time = Some(595.0);
        assert_eq!(tail.effective_resume_secs(), None);

        // Past the 97% mark on a long scene → treat as finished even
        // though the absolute gap is bigger than 10s.
        let mut long = base.clone();
        long.files[0].duration = Some(3600.0);
        long.resume_time = Some(3500.0);
        assert_eq!(long.effective_resume_secs(), None);

        // No duration metadata → fall back to honouring the resume.
        let mut no_duration = base.clone();
        no_duration.files.clear();
        no_duration.resume_time = Some(595.0);
        assert_eq!(no_duration.effective_resume_secs(), Some(595.0));
    }

    #[test]
    fn filename_stem_handles_common_path_shapes() {
        assert_eq!(filename_stem("/a/b/c.mp4").as_deref(), Some("c"));
        assert_eq!(filename_stem("c.mp4").as_deref(), Some("c"));
        // Backslash separator (Windows-side Stash servers).
        assert_eq!(
            filename_stem(r"C:\videos\clip 01.mkv").as_deref(),
            Some("clip 01"),
        );
        // No extension → keep the whole basename.
        assert_eq!(filename_stem("/a/b/README").as_deref(), Some("README"));
        // Dotfile-style names: nothing before the dot, so don't strip.
        assert_eq!(filename_stem("/a/b/.hidden").as_deref(), Some(".hidden"));
        // Empty / trailing-separator cases stay None so the caller can
        // fall through to the id-based label.
        assert!(filename_stem("").is_none());
        assert!(filename_stem("/a/b/").is_none());
    }
}

