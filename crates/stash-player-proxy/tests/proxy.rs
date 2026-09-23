//! Tests for the loopback media proxy. The URL-construction tests here
//! need no HTTP round-trip; the request-handling tests live alongside
//! them once the server exists.

use stash_api::Client;
use stash_player_proxy::MediaProxy;

fn client(base: &str, key: &str) -> Client {
    Client::new(base, key).unwrap()
}

#[tokio::test]
async fn playback_url_points_at_loopback_and_carries_the_upstream() {
    let proxy = MediaProxy::bind().await.unwrap();
    proxy.set_client(Some(client("https://stash.example.test", "KEY")));

    let out = proxy.playback_url("/scene/1/stream").unwrap();
    let parsed = url::Url::parse(&out).unwrap();

    assert_eq!(parsed.scheme(), "http");
    assert_eq!(parsed.host_str(), Some("127.0.0.1"));
    assert_eq!(parsed.port(), Some(proxy.addr().port()));
    assert!(
        parsed.path().ends_with("/media"),
        "unexpected path: {}",
        parsed.path()
    );

    let upstream = parsed
        .query_pairs()
        .find(|(k, _)| k == "u")
        .map(|(_, v)| v.into_owned())
        .expect("u parameter");
    assert_eq!(upstream, "https://stash.example.test/scene/1/stream");
}

#[tokio::test]
async fn playback_url_strips_the_api_key_stash_baked_in() {
    let proxy = MediaProxy::bind().await.unwrap();
    proxy.set_client(Some(client("https://stash.example.test", "SECRET")));

    // Stash hands back `paths.stream` with apikey already attached.
    let out = proxy
        .playback_url("/scene/1/stream?apikey=SECRET&resolution=ORIGINAL")
        .unwrap();

    assert!(!out.contains("SECRET"), "api key leaked into {out}");
    assert!(
        out.contains("resolution"),
        "other query params must survive: {out}"
    );
}

#[tokio::test]
async fn playback_url_percent_encodes_the_upstream() {
    let proxy = MediaProxy::bind().await.unwrap();
    proxy.set_client(Some(client("https://stash.example.test", "")));

    let out = proxy.playback_url("/scene/1/stream?q=a b&r=x%2By").unwrap();

    // The upstream URL is a query *value*, so its own separators must be
    // escaped or the handler would parse them as our parameters.
    assert!(!out.contains("?q="), "upstream query leaked unescaped: {out}");
    let parsed = url::Url::parse(&out).unwrap();
    let count = parsed.query_pairs().count();
    assert_eq!(count, 1, "expected exactly the u parameter, got {count}");
}

#[tokio::test]
async fn playback_url_without_a_client_is_an_error() {
    let proxy = MediaProxy::bind().await.unwrap();
    let err = proxy.playback_url("/scene/1/stream").unwrap_err();
    assert!(matches!(err, stash_player_proxy::Error::NotConfigured));
}

#[tokio::test]
async fn each_proxy_gets_a_distinct_token() {
    let a = MediaProxy::bind().await.unwrap();
    let b = MediaProxy::bind().await.unwrap();
    a.set_client(Some(client("https://stash.example.test", "")));
    b.set_client(Some(client("https://stash.example.test", "")));

    let path_of = |p: &MediaProxy| {
        url::Url::parse(&p.playback_url("/x").unwrap())
            .unwrap()
            .path()
            .to_owned()
    };
    assert_ne!(path_of(&a), path_of(&b));
}

#[tokio::test]
async fn binds_only_to_loopback() {
    let proxy = MediaProxy::bind().await.unwrap();
    assert!(
        proxy.addr().ip().is_loopback(),
        "media proxy must never be reachable off-host: {}",
        proxy.addr()
    );
}

use wiremock::matchers::{header, method, path};
use wiremock::{Mock, MockServer, ResponseTemplate};

async fn proxy_for(server: &MockServer, key: &str) -> MediaProxy {
    let proxy = MediaProxy::bind().await.unwrap();
    proxy.set_client(Some(client(&server.uri(), key)));
    proxy
}

#[tokio::test]
async fn plain_get_returns_the_upstream_body_unchanged() {
    let server = MockServer::start().await;
    Mock::given(method("GET"))
        .and(path("/scene/1/stream"))
        .respond_with(
            ResponseTemplate::new(200)
                .insert_header("Content-Type", "video/mp4")
                .set_body_bytes(vec![9u8; 4096]),
        )
        .mount(&server)
        .await;

    let proxy = proxy_for(&server, "KEY").await;
    let url = proxy.playback_url("/scene/1/stream").unwrap();

    let resp = reqwest::get(&url).await.unwrap();
    assert_eq!(resp.status().as_u16(), 200);
    assert_eq!(resp.headers()["content-type"], "video/mp4");
    assert_eq!(resp.bytes().await.unwrap().len(), 4096);
}

#[tokio::test]
async fn range_request_passes_through_as_206() {
    let server = MockServer::start().await;
    Mock::given(method("GET"))
        .and(path("/scene/1/stream"))
        .and(header("Range", "bytes=100-199"))
        .respond_with(
            ResponseTemplate::new(206)
                .insert_header("Content-Range", "bytes 100-199/5000")
                .insert_header("Accept-Ranges", "bytes")
                .set_body_bytes(vec![7u8; 100]),
        )
        .mount(&server)
        .await;

    let proxy = proxy_for(&server, "KEY").await;
    let url = proxy.playback_url("/scene/1/stream").unwrap();

    let resp = reqwest::Client::new()
        .get(&url)
        .header("Range", "bytes=100-199")
        .send()
        .await
        .unwrap();

    // This is the seeking guarantee. If the status or Content-Range is
    // lost here, scrubbing breaks in both frontends.
    assert_eq!(resp.status().as_u16(), 206);
    assert_eq!(resp.headers()["content-range"], "bytes 100-199/5000");
    assert_eq!(resp.headers()["accept-ranges"], "bytes");
    assert_eq!(resp.bytes().await.unwrap().len(), 100);
}

#[tokio::test]
async fn upstream_receives_the_api_key_header() {
    let server = MockServer::start().await;
    Mock::given(method("GET"))
        .and(path("/scene/1/stream"))
        .and(header("ApiKey", "KEY"))
        .respond_with(ResponseTemplate::new(200).set_body_bytes(b"video".to_vec()))
        .mount(&server)
        .await;

    let proxy = proxy_for(&server, "KEY").await;
    let url = proxy.playback_url("/scene/1/stream?apikey=KEY").unwrap();

    let resp = reqwest::get(&url).await.unwrap();
    assert_eq!(
        resp.status().as_u16(),
        200,
        "the mock only matches when the ApiKey header arrives"
    );
    assert_eq!(resp.bytes().await.unwrap().as_ref(), b"video");
}

#[tokio::test]
async fn wrong_token_is_not_found() {
    let server = MockServer::start().await;
    let proxy = proxy_for(&server, "KEY").await;
    let bad = format!(
        "http://{}/00000000000000000000000000000000/media?u=http%3A%2F%2Fx.test%2Fy",
        proxy.addr()
    );

    let resp = reqwest::get(&bad).await.unwrap();
    assert_eq!(resp.status().as_u16(), 404);
}

#[tokio::test]
async fn foreign_upstream_host_is_rejected() {
    let server = MockServer::start().await;
    let proxy = proxy_for(&server, "KEY").await;
    let good = proxy.playback_url("/scene/1/stream").unwrap();

    // Keep the valid token, swap the upstream for a host the client was
    // never configured with. Without this guard a leaked token would make
    // the loopback server an open relay through the user's proxy.
    let base = good.split("?u=").next().unwrap().to_owned();
    let evil = format!("{base}?u=http%3A%2F%2Fevil.example.test%2Fx");

    let resp = reqwest::get(&evil).await.unwrap();
    assert_eq!(resp.status().as_u16(), 403);
}

#[tokio::test]
async fn upstream_error_status_passes_through_unchanged() {
    let server = MockServer::start().await;
    Mock::given(method("GET"))
        .and(path("/scene/1/stream"))
        .respond_with(ResponseTemplate::new(500).set_body_string("boom"))
        .mount(&server)
        .await;

    let proxy = proxy_for(&server, "KEY").await;
    let url = proxy.playback_url("/scene/1/stream").unwrap();

    // A 500 is a successful request that returned an error status. The
    // media stack should see what Stash actually said, not our guess.
    let resp = reqwest::get(&url).await.unwrap();
    assert_eq!(resp.status().as_u16(), 500);
}

#[tokio::test]
async fn unreachable_upstream_is_a_bad_gateway() {
    // Bind then immediately drop, to get a port nothing answers on.
    let dead = tokio::net::TcpListener::bind("127.0.0.1:0").await.unwrap();
    let addr = dead.local_addr().unwrap();
    drop(dead);

    let proxy = MediaProxy::bind().await.unwrap();
    proxy.set_client(Some(client(&format!("http://{addr}"), "KEY")));
    let url = proxy.playback_url("/scene/1/stream").unwrap();

    let resp = reqwest::get(&url).await.unwrap();
    assert_eq!(resp.status().as_u16(), 502);
}

#[tokio::test]
async fn post_is_not_allowed() {
    let server = MockServer::start().await;
    let proxy = proxy_for(&server, "KEY").await;
    let url = proxy.playback_url("/scene/1/stream").unwrap();

    let resp = reqwest::Client::new().post(&url).send().await.unwrap();
    assert_eq!(resp.status().as_u16(), 405);
}

#[tokio::test]
async fn requests_after_disconnect_are_unavailable() {
    let server = MockServer::start().await;
    let proxy = proxy_for(&server, "KEY").await;
    let url = proxy.playback_url("/scene/1/stream").unwrap();

    proxy.set_client(None);

    let resp = reqwest::get(&url).await.unwrap();
    assert_eq!(resp.status().as_u16(), 503);
}

#[tokio::test]
async fn host_case_difference_is_still_same_origin() {
    let server = MockServer::start().await;
    Mock::given(method("GET"))
        .and(path("/scene/1/stream"))
        .respond_with(ResponseTemplate::new(200).set_body_bytes(b"ok".to_vec()))
        .mount(&server)
        .await;

    // Base the client off "localhost" rather than the mock server's bare
    // IP, so an upstream that differs only by host case can still resolve
    // to the same loopback address the mock is listening on.
    let port = server.address().port();
    let proxy = MediaProxy::bind().await.unwrap();
    proxy.set_client(Some(client(&format!("http://localhost:{port}"), "KEY")));

    let good = proxy.playback_url("/scene/1/stream").unwrap();
    let base = good.split("?u=").next().unwrap().to_owned();

    // The url crate lowercases domain hosts for http/https at parse time,
    // so this must compare equal to the client's base, not be rejected.
    let upper = format!("{base}?u=http%3A%2F%2FLOCALHOST%3A{port}%2Fscene%2F1%2Fstream");

    let resp = reqwest::get(&upper).await.unwrap();
    assert_eq!(
        resp.status().as_u16(),
        200,
        "host case must not affect the origin check"
    );
}

#[tokio::test]
async fn default_and_explicit_port_are_same_origin() {
    let proxy = MediaProxy::bind().await.unwrap();
    // No explicit port on the base, so it takes the scheme's default (443
    // for https).
    proxy.set_client(Some(client("https://localhost", "KEY")));

    let good = proxy.playback_url("/scene/1/stream").unwrap();
    let base = good.split("?u=").next().unwrap().to_owned();

    // Same host, port spelled out explicitly instead of implied.
    let explicit = format!("{base}?u=https%3A%2F%2Flocalhost%3A443%2Fscene%2F1%2Fstream");

    // Nothing is expected to be listening on localhost:443 here, so the
    // exact non-403 outcome depends on the environment (most likely 502,
    // a transport failure). What this test locks in is that the guard's
    // same-origin verdict does not depend on which side spelled the port
    // out: a 403 would mean the guard incorrectly treated 443 and the
    // implied default as different origins.
    let resp = reqwest::get(&explicit).await.unwrap();
    assert_ne!(
        resp.status().as_u16(),
        403,
        "default port 443 (implied by https) must compare equal to an explicit :443"
    );
}

#[tokio::test]
async fn userinfo_in_upstream_is_still_same_origin() {
    let server = MockServer::start().await;
    Mock::given(method("GET"))
        .and(path("/scene/1/stream"))
        .respond_with(ResponseTemplate::new(200).set_body_bytes(b"ok".to_vec()))
        .mount(&server)
        .await;

    let proxy = proxy_for(&server, "KEY").await;
    let good = proxy.playback_url("/scene/1/stream").unwrap();
    let base = good.split("?u=").next().unwrap().to_owned();

    // host_str()/port() never include userinfo, so a `u` carrying
    // credentials against the same host must still be treated as
    // same-origin. reqwest may go on to send that userinfo upstream as a
    // spurious Basic-auth header, but the mock above doesn't check for one.
    let addr = server.address();
    let with_userinfo = format!(
        "{base}?u=http%3A%2F%2Fuser%3Apass%40{}%3A{}%2Fscene%2F1%2Fstream",
        addr.ip(),
        addr.port()
    );

    let resp = reqwest::get(&with_userinfo).await.unwrap();
    assert_eq!(
        resp.status().as_u16(),
        200,
        "userinfo must not affect the origin check"
    );
}

#[tokio::test]
async fn head_request_is_allowed() {
    let server = MockServer::start().await;
    Mock::given(method("HEAD"))
        .and(path("/scene/1/stream"))
        .respond_with(ResponseTemplate::new(200).insert_header("Content-Length", "4096"))
        .mount(&server)
        .await;

    let proxy = proxy_for(&server, "KEY").await;
    let url = proxy.playback_url("/scene/1/stream").unwrap();

    let resp = reqwest::Client::new().head(&url).send().await.unwrap();
    assert_eq!(resp.status().as_u16(), 200);
}

#[tokio::test]
async fn missing_upstream_url_is_bad_request() {
    let server = MockServer::start().await;
    let proxy = proxy_for(&server, "KEY").await;
    let good = proxy.playback_url("/scene/1/stream").unwrap();
    let base = good.split("?u=").next().unwrap().to_owned();

    let resp = reqwest::get(&base).await.unwrap();
    assert_eq!(resp.status().as_u16(), 400);
}

#[tokio::test]
async fn unparseable_upstream_url_is_bad_request() {
    let server = MockServer::start().await;
    let proxy = proxy_for(&server, "KEY").await;
    let good = proxy.playback_url("/scene/1/stream").unwrap();
    let base = good.split("?u=").next().unwrap().to_owned();
    let bad = format!("{base}?u=not-a-url");

    let resp = reqwest::get(&bad).await.unwrap();
    assert_eq!(resp.status().as_u16(), 400);
}
