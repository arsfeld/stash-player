//! Tests for `Client::authenticated_url` — the helper that hands video and
//! image URLs to consumers (GStreamer, GTK image widgets) that won't carry
//! the `ApiKey` request header. The contract: append `apikey=` for relative
//! and bare-absolute URLs, leave already-authenticated URLs untouched, and
//! never inject the key when the client was built without one.

use stash_api::Client;
use url::Url;

fn client_with_key(key: &str) -> Client {
    Client::new("https://stash.example.test", key).unwrap()
}

#[test]
fn relative_path_resolves_against_base_and_is_authenticated() {
    let c = client_with_key("KEY");
    let out = c.authenticated_url("/scene/1/screenshot").unwrap();
    let parsed = Url::parse(&out).unwrap();
    assert_eq!(parsed.host_str(), Some("stash.example.test"));
    assert_eq!(parsed.path(), "/scene/1/screenshot");
    let apikey = parsed
        .query_pairs()
        .find(|(k, _)| k == "apikey")
        .map(|(_, v)| v.to_string());
    assert_eq!(apikey, Some("KEY".to_owned()));
}

#[test]
fn absolute_url_gets_apikey_appended() {
    let c = client_with_key("KEY");
    let out = c
        .authenticated_url("https://other.example.test/x.jpg")
        .unwrap();
    let parsed = Url::parse(&out).unwrap();
    assert_eq!(parsed.host_str(), Some("other.example.test"));
    assert!(parsed.query_pairs().any(|(k, v)| k == "apikey" && v == "KEY"));
}

#[test]
fn already_authenticated_url_is_left_untouched() {
    // Stash's `paths.stream` already has an apikey embedded — appending
    // ours would produce a doubled query param that some servers reject.
    let c = client_with_key("KEY");
    let input = "https://stash.example.test/scene/1/stream?apikey=PRE_BAKED";
    let out = c.authenticated_url(input).unwrap();
    let parsed = Url::parse(&out).unwrap();
    let keys: Vec<_> = parsed
        .query_pairs()
        .filter(|(k, _)| k == "apikey")
        .collect();
    assert_eq!(keys.len(), 1, "should not duplicate apikey");
    assert_eq!(keys[0].1, "PRE_BAKED");
}

#[test]
fn already_authenticated_case_insensitive() {
    // Some Stash builds spell the param ApiKey with mixed case in URLs.
    let c = client_with_key("KEY");
    let input = "https://stash.example.test/x?ApiKey=PRE_BAKED";
    let out = c.authenticated_url(input).unwrap();
    assert_eq!(out, input, "uppercase ApiKey should be detected");
}

#[test]
fn empty_api_key_does_not_inject_anything() {
    let c = client_with_key("");
    let out = c.authenticated_url("/scene/1/screenshot").unwrap();
    let parsed = Url::parse(&out).unwrap();
    assert!(parsed.query_pairs().all(|(k, _)| k != "apikey"));
}

#[test]
fn base_url_with_trailing_slash_resolves_graphql_endpoint() {
    // The Client::new constructor uses Url::join("graphql"), which behaves
    // differently with vs without a trailing slash. We don't expose the
    // endpoint, but we can prove via authenticated_url that the base is
    // tracked correctly.
    let c = Client::new("https://stash.example.test/", "K").unwrap();
    let out = c.authenticated_url("/x").unwrap();
    assert!(out.starts_with("https://stash.example.test/x"));
}

#[test]
fn absolute_url_resolves_relative_paths_without_adding_credentials() {
    let c = client_with_key("KEY");
    let out = c.absolute_url("/scene/1/stream").unwrap();
    assert_eq!(out.host_str(), Some("stash.example.test"));
    assert_eq!(out.path(), "/scene/1/stream");
    assert_eq!(out.query(), None, "absolute_url must not attach the api key");
}

#[test]
fn absolute_url_passes_through_absolute_inputs() {
    let c = client_with_key("KEY");
    let out = c.absolute_url("https://other.example.test/x.jpg?a=1").unwrap();
    assert_eq!(out.host_str(), Some("other.example.test"));
    assert_eq!(out.query(), Some("a=1"));
}

#[test]
fn with_proxy_accepts_the_documented_schemes() {
    for proxy in [
        "http://127.0.0.1:1055",
        "https://127.0.0.1:1055",
        "socks5://127.0.0.1:1055",
        "socks5h://127.0.0.1:1055",
    ] {
        Client::with_proxy("https://stash.example.test", "KEY", Some(proxy))
            .unwrap_or_else(|e| panic!("{proxy} should be accepted, got {e}"));
    }
}

#[test]
fn with_proxy_rejects_unsupported_schemes_with_a_useful_message() {
    let err = Client::with_proxy("https://stash.example.test", "KEY", Some("ftp://x.test"))
        .unwrap_err();
    let msg = err.to_string();
    assert!(msg.contains("ftp"), "message should name the bad scheme: {msg}");
    assert!(msg.contains("socks5"), "message should name what works: {msg}");
}

#[test]
fn with_proxy_rejects_unparseable_urls() {
    let err = Client::with_proxy("https://stash.example.test", "KEY", Some("not a url"))
        .unwrap_err();
    assert!(matches!(err, stash_api::Error::InvalidProxy(_)));
}

#[test]
fn with_proxy_none_matches_new() {
    // An absent proxy must behave exactly like the original constructor,
    // so the loopback server and both frontends can use one code path.
    let a = Client::new("https://stash.example.test", "KEY").unwrap();
    let b = Client::with_proxy("https://stash.example.test", "KEY", None).unwrap();
    assert_eq!(
        a.authenticated_url("/x").unwrap(),
        b.authenticated_url("/x").unwrap()
    );
}

#[test]
fn empty_proxy_string_is_treated_as_no_proxy() {
    Client::with_proxy("https://stash.example.test", "KEY", Some("")).unwrap();
}
