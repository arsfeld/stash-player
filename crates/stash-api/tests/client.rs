//! End-to-end Client tests using wiremock. These verify the wire-format
//! contract: the ApiKey header is forwarded, requests carry the expected
//! GraphQL query+variables, and server responses (success, GraphQL errors,
//! HTTP errors, null findScene) map onto the Client's public surface.

use serde_json::json;
use stash_api::{Client, Error, JobStatus, SceneFilter, SortDirection, SortKey};
use wiremock::matchers::{header, method, path};
use wiremock::{Mock, MockServer, Request, ResponseTemplate};

fn fixture(name: &str) -> String {
    let path = std::path::Path::new(env!("CARGO_MANIFEST_DIR"))
        .join("tests/fixtures")
        .join(name);
    std::fs::read_to_string(path).unwrap()
}

fn fixture_json(name: &str) -> serde_json::Value {
    serde_json::from_str(&fixture(name)).unwrap()
}

#[tokio::test]
async fn version_query_round_trips() {
    let server = MockServer::start().await;
    Mock::given(method("POST"))
        .and(path("/graphql"))
        .and(header("ApiKey", "test-key"))
        .respond_with(ResponseTemplate::new(200).set_body_json(fixture_json("version.json")))
        .mount(&server)
        .await;

    let client = Client::new(&server.uri(), "test-key").unwrap();
    let v = client.version().await.unwrap();
    assert_eq!(v, "v0.31.0");
}

#[tokio::test]
async fn find_scenes_sends_expected_request_shape() {
    let server = MockServer::start().await;
    Mock::given(method("POST"))
        .and(path("/graphql"))
        .and(header("ApiKey", "test-key"))
        .respond_with(
            ResponseTemplate::new(200).set_body_json(fixture_json("find_scenes_default.json")),
        )
        .mount(&server)
        .await;

    let client = Client::new(&server.uri(), "test-key").unwrap();
    let mut filter = SceneFilter::new();
    filter.query = Some("alpha".into());
    filter.sort = SortKey::Rating;
    filter.direction = SortDirection::Asc;
    filter.min_rating = Some(60);
    filter.organized = Some(true);
    filter.interactive = Some(false);

    let page = client.find_scenes(&filter, 2, 25).await.unwrap();
    assert_eq!(page.count, 357);
    assert_eq!(page.scenes.len(), 3);

    // Inspect the request the mock recorded so we know what hit the wire.
    let received: Vec<Request> = server.received_requests().await.unwrap();
    assert_eq!(received.len(), 1);
    let body: serde_json::Value = serde_json::from_slice(&received[0].body).unwrap();

    assert!(body["query"].as_str().unwrap().contains("findScenes"));
    let vars = &body["variables"];
    assert_eq!(vars["filter"]["page"], 2);
    assert_eq!(vars["filter"]["per_page"], 25);
    assert_eq!(vars["filter"]["sort"], "rating");
    assert_eq!(vars["filter"]["direction"], "ASC");
    assert_eq!(vars["filter"]["q"], "alpha");
    // min_rating = 60 → IntCriterion GREATER_THAN 59 (exclusive).
    assert_eq!(vars["scene_filter"]["rating100"]["value"], 59);
    assert_eq!(vars["scene_filter"]["rating100"]["modifier"], "GREATER_THAN");
    assert_eq!(vars["scene_filter"]["organized"], true);
    // `interactive: false` is the "hide interactive scenes" wire shape.
    assert_eq!(vars["scene_filter"]["interactive"], false);
}

#[tokio::test]
async fn find_scenes_random_sort_includes_seed() {
    let server = MockServer::start().await;
    Mock::given(method("POST"))
        .and(path("/graphql"))
        .respond_with(
            ResponseTemplate::new(200).set_body_json(fixture_json("find_scenes_default.json")),
        )
        .mount(&server)
        .await;

    let client = Client::new(&server.uri(), "test-key").unwrap();
    let mut filter = SceneFilter::new();
    filter.sort = SortKey::Random;
    filter.random_seed = Some(42);
    client.find_scenes(&filter, 1, 10).await.unwrap();

    let req = &server.received_requests().await.unwrap()[0];
    let body: serde_json::Value = serde_json::from_slice(&req.body).unwrap();
    assert_eq!(body["variables"]["filter"]["sort"], "random_42");
}

#[tokio::test]
async fn find_scene_missing_maps_to_none() {
    let server = MockServer::start().await;
    Mock::given(method("POST"))
        .and(path("/graphql"))
        .respond_with(
            ResponseTemplate::new(200).set_body_json(fixture_json("find_scene_missing.json")),
        )
        .mount(&server)
        .await;

    let client = Client::new(&server.uri(), "test-key").unwrap();
    assert!(client.find_scene("999").await.unwrap().is_none());
}

#[tokio::test]
async fn graphql_errors_envelope_maps_to_error_graphql() {
    let server = MockServer::start().await;
    Mock::given(method("POST"))
        .and(path("/graphql"))
        .respond_with(
            ResponseTemplate::new(200).set_body_json(fixture_json("graphql_error.json")),
        )
        .mount(&server)
        .await;

    let client = Client::new(&server.uri(), "test-key").unwrap();
    let err = client.version().await.unwrap_err();
    match err {
        Error::GraphQl(msg) => assert!(msg.contains("thisFieldDoesNotExist")),
        other => panic!("expected Error::GraphQl, got {other:?}"),
    }
}

#[tokio::test]
async fn http_error_maps_to_error_status() {
    let server = MockServer::start().await;
    Mock::given(method("POST"))
        .and(path("/graphql"))
        .respond_with(ResponseTemplate::new(500).set_body_string("upstream boom"))
        .mount(&server)
        .await;

    let client = Client::new(&server.uri(), "test-key").unwrap();
    let err = client.version().await.unwrap_err();
    match err {
        Error::Status { status, body } => {
            assert_eq!(status, 500);
            assert_eq!(body, "upstream boom");
        }
        other => panic!("expected Error::Status, got {other:?}"),
    }
}

#[tokio::test]
async fn save_scene_activity_serializes_optional_floats() {
    let server = MockServer::start().await;
    Mock::given(method("POST"))
        .and(path("/graphql"))
        .respond_with(
            ResponseTemplate::new(200).set_body_json(fixture_json("scene_save_activity.json")),
        )
        .mount(&server)
        .await;

    let client = Client::new(&server.uri(), "test-key").unwrap();
    let ok = client
        .save_scene_activity("1001", Some(90.5), None)
        .await
        .unwrap();
    assert!(ok);

    let req = &server.received_requests().await.unwrap()[0];
    let body: serde_json::Value = serde_json::from_slice(&req.body).unwrap();
    assert_eq!(body["variables"]["id"], "1001");
    assert_eq!(body["variables"]["resume_time"], 90.5);
    // None should serialize to JSON null, not omit the key.
    assert_eq!(body["variables"]["playDuration"], json!(null));
}

#[tokio::test]
async fn increment_o_returns_new_count_and_sends_id_variable() {
    let server = MockServer::start().await;
    Mock::given(method("POST"))
        .and(path("/graphql"))
        .respond_with(
            ResponseTemplate::new(200).set_body_json(fixture_json("scene_increment_o.json")),
        )
        .mount(&server)
        .await;

    let client = Client::new(&server.uri(), "test-key").unwrap();
    let new_count = client.increment_o("1001").await.unwrap();
    assert_eq!(new_count, 4);

    let req = &server.received_requests().await.unwrap()[0];
    let body: serde_json::Value = serde_json::from_slice(&req.body).unwrap();
    assert!(body["query"].as_str().unwrap().contains("sceneIncrementO"));
    assert_eq!(body["variables"]["id"], "1001");
}

#[tokio::test]
async fn reset_o_returns_zero_and_sends_id_variable() {
    let server = MockServer::start().await;
    Mock::given(method("POST"))
        .and(path("/graphql"))
        .respond_with(
            ResponseTemplate::new(200).set_body_json(fixture_json("scene_reset_o.json")),
        )
        .mount(&server)
        .await;

    let client = Client::new(&server.uri(), "test-key").unwrap();
    let new_count = client.reset_o("1001").await.unwrap();
    assert_eq!(new_count, 0);

    let req = &server.received_requests().await.unwrap()[0];
    let body: serde_json::Value = serde_json::from_slice(&req.body).unwrap();
    assert!(body["query"].as_str().unwrap().contains("sceneResetO"));
    assert_eq!(body["variables"]["id"], "1001");
}

#[tokio::test]
async fn empty_api_key_omits_header_but_request_still_reaches_server() {
    // Servers behind reverse proxies sometimes don't require auth; the
    // client should still build and send the request without an ApiKey
    // header. wiremock treats an absent header as not-matching when we
    // explicitly require it, so we *don't* require it here and instead
    // assert via the recorded request that the header was not sent.
    let server = MockServer::start().await;
    Mock::given(method("POST"))
        .and(path("/graphql"))
        .respond_with(ResponseTemplate::new(200).set_body_json(fixture_json("version.json")))
        .mount(&server)
        .await;

    let client = Client::new(&server.uri(), "").unwrap();
    client.version().await.unwrap();

    let req = &server.received_requests().await.unwrap()[0];
    assert!(req.headers.get("ApiKey").is_none());
}

#[tokio::test]
async fn metadata_scan_returns_job_id() {
    let server = MockServer::start().await;
    Mock::given(method("POST"))
        .and(path("/graphql"))
        .respond_with(
            ResponseTemplate::new(200).set_body_json(fixture_json("metadata_scan.json")),
        )
        .mount(&server)
        .await;

    let client = Client::new(&server.uri(), "test-key").unwrap();
    let job_id = client.metadata_scan().await.unwrap();
    assert_eq!(job_id, "42");
}

#[tokio::test]
async fn jobs_returns_running_jobs() {
    let server = MockServer::start().await;
    Mock::given(method("POST"))
        .and(path("/graphql"))
        .respond_with(ResponseTemplate::new(200).set_body_json(fixture_json("jobs.json")))
        .mount(&server)
        .await;

    let client = Client::new(&server.uri(), "test-key").unwrap();
    let jobs = client.jobs().await.unwrap();
    assert_eq!(jobs.len(), 1);
    assert_eq!(jobs[0].id, "42");
    assert_eq!(jobs[0].status, JobStatus::Running);
    assert_eq!(jobs[0].progress, Some(0.35));
    assert_eq!(jobs[0].description, "Scanning for new files");
}

#[tokio::test]
async fn jobs_handles_empty_list() {
    let server = MockServer::start().await;
    Mock::given(method("POST"))
        .and(path("/graphql"))
        .respond_with(
            ResponseTemplate::new(200).set_body_json(fixture_json("jobs_empty.json")),
        )
        .mount(&server)
        .await;

    let client = Client::new(&server.uri(), "test-key").unwrap();
    let jobs = client.jobs().await.unwrap();
    assert!(jobs.is_empty());
}
