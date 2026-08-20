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
