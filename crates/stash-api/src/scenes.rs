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
#[derive(Debug, Clone, Copy, PartialEq, Eq)]
pub enum SortKey {
    Date,
    Title,
    Rating,
    PlayCount,
    Duration,
    CreatedAt,
    UpdatedAt,
    Random,
}

impl Default for SortKey {
    fn default() -> Self {
        SortKey::Date
    }
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
}

impl Scene {
    /// Best-effort title for display. Falls back to the first file's basename
    /// or the scene id when Stash has no metadata title.
    pub fn display_title(&self) -> String {
        if let Some(t) = self.title.as_deref()
            && !t.is_empty()
        {
            return t.to_owned();
        }
        format!("Scene {}", self.id)
    }

    pub fn duration_seconds(&self) -> Option<f64> {
        self.files.first().and_then(|f| f.duration)
    }
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
      paths { screenshot preview sprite stream webp }
      files { duration width height video_codec frame_rate }
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

    serde_json::json!({
        "filter": find_filter,
        "scene_filter": serde_json::Value::Object(scene_filter),
    })
}
