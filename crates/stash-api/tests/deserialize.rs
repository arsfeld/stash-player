//! Deserialization tests against sanitized fixtures captured from a real
//! Stash server. The fixtures live in `tests/fixtures/` and exercise the
//! shapes the UI layer depends on (full data, all-nulls, missing optional
//! fields, GraphQL error envelopes).

use stash_api::{FindScenesPage, Scene};

fn fixture(name: &str) -> String {
    let path = std::path::Path::new(env!("CARGO_MANIFEST_DIR"))
        .join("tests/fixtures")
        .join(name);
    std::fs::read_to_string(&path).unwrap_or_else(|e| panic!("read {path:?}: {e}"))
}

#[derive(serde::Deserialize)]
struct Envelope<T> {
    data: T,
}

#[derive(serde::Deserialize)]
struct FindScenesData {
    #[serde(rename = "findScenes")]
    find_scenes: FindScenesPage,
}

#[derive(serde::Deserialize)]
struct FindSceneData {
    #[serde(rename = "findScene")]
    find_scene: Option<Scene>,
}

#[derive(serde::Deserialize)]
struct VersionData {
    version: VersionInner,
}

#[derive(serde::Deserialize)]
struct VersionInner {
    version: Option<String>,
}

#[derive(serde::Deserialize)]
struct SaveActivityData {
    #[serde(rename = "sceneSaveActivity")]
    scene_save_activity: bool,
}

#[test]
fn version_response_round_trips() {
    let env: Envelope<VersionData> = serde_json::from_str(&fixture("version.json")).unwrap();
    assert_eq!(env.data.version.version.as_deref(), Some("v0.31.0"));
}

#[test]
fn find_scenes_default_full_shape() {
    let env: Envelope<FindScenesData> =
        serde_json::from_str(&fixture("find_scenes_default.json")).unwrap();
    let page = env.data.find_scenes;

    assert_eq!(page.count, 357);
    assert_eq!(page.scenes.len(), 3);

    // Scene 1: every optional field populated.
    let s = &page.scenes[0];
    assert_eq!(s.id, "1001");
    assert_eq!(s.title.as_deref(), Some("Sample Scene Alpha"));
    assert_eq!(s.rating100, Some(80));
    assert_eq!(s.resume_time, Some(120.5));
    assert_eq!(s.play_count, Some(2));
    assert_eq!(s.play_duration, Some(300.0));
    assert_eq!(s.studio.as_ref().map(|st| st.name.as_str()), Some("Studio Foo"));
    assert_eq!(s.performers.len(), 2);
    assert_eq!(s.performers[0].name, "Performer Alpha");
    assert_eq!(s.duration_seconds(), Some(1800.0));
    assert_eq!(s.files[0].video_codec.as_deref(), Some("h264"));
    assert!(s.paths.stream.as_deref().unwrap().contains("apikey="));
}

#[test]
fn find_scenes_handles_all_null_optionals() {
    // Scene 2 in the fixture has every optional field set to null and
    // empty arrays for studio/performers/files. This is the shape the
    // server returns for newly imported scenes with no metadata.
    let env: Envelope<FindScenesData> =
        serde_json::from_str(&fixture("find_scenes_default.json")).unwrap();
    let s = &env.data.find_scenes.scenes[1];

    assert_eq!(s.id, "1002");
    assert!(s.title.is_none());
    assert!(s.details.is_none());
    assert!(s.date.is_none());
    assert!(s.rating100.is_none());
    assert!(s.studio.is_none());
    assert!(s.performers.is_empty());
    assert!(s.files.is_empty());
    assert_eq!(s.duration_seconds(), None);
    // display_title falls back to "Scene <id>" when title is null/empty.
    assert_eq!(s.display_title(), "Scene 1002");
}

#[test]
fn find_scenes_partial_schema_uses_defaults_for_omitted_fields() {
    // This fixture omits details/date/resume_time/play_count/play_duration
    // entirely (rather than returning them as null). #[serde(default)] on
    // the Scene struct should let it deserialize without error.
    let env: Envelope<FindScenesData> =
        serde_json::from_str(&fixture("find_scenes_partial_schema.json")).unwrap();
    let s = &env.data.find_scenes.scenes[0];

    assert_eq!(s.id, "1004");
    assert!(s.details.is_none());
    assert!(s.date.is_none());
    assert!(s.resume_time.is_none());
    assert!(s.play_count.is_none());
    assert!(s.play_duration.is_none());
    assert_eq!(s.rating100, Some(100));
}

#[test]
fn find_scene_full_shape() {
    let env: Envelope<FindSceneData> =
        serde_json::from_str(&fixture("find_scene.json")).unwrap();
    let scene = env.data.find_scene.expect("scene should be Some");
    assert_eq!(scene.id, "1001");
    assert_eq!(scene.display_title(), "Sample Scene Alpha");
}

#[test]
fn find_scene_missing_returns_none() {
    let env: Envelope<FindSceneData> =
        serde_json::from_str(&fixture("find_scene_missing.json")).unwrap();
    assert!(env.data.find_scene.is_none());
}

#[test]
fn save_activity_response_decodes_to_bool() {
    let env: Envelope<SaveActivityData> =
        serde_json::from_str(&fixture("scene_save_activity.json")).unwrap();
    assert!(env.data.scene_save_activity);
}
