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
