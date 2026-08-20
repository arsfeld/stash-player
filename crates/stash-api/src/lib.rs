//! Thin HTTP client for the Stash GraphQL API.
//!
//! v1 hand-rolls the few queries we need rather than running schema codegen.
//! Once the surface grows past a handful of queries we can switch to
//! `graphql_client` against a committed SDL.

use serde::{Deserialize, Serialize};
use thiserror::Error;
use url::Url;

pub mod scenes;
pub use scenes::{
    FindScenesPage, PerformerRef, Scene, SceneFile, SceneFilter, ScenePaths,
    SortDirection, SortKey, StudioRef,
};

#[derive(Debug, Error)]
pub enum Error {
    #[error("invalid base URL: {0}")]
    InvalidUrl(#[from] url::ParseError),
    #[error("HTTP transport: {0}")]
    Http(#[from] reqwest::Error),
    #[error("invalid header value: {0}")]
    InvalidHeader(#[from] reqwest::header::InvalidHeaderValue),
    #[error("invalid proxy URL: {0}")]
    InvalidProxy(String),
    #[error("server returned HTTP {status}: {body}")]
    Status { status: u16, body: String },
    #[error("server returned GraphQL errors: {0}")]
    GraphQl(String),
    #[error("unexpected response shape: missing `{0}`")]
    MissingField(&'static str),
}

pub type Result<T> = std::result::Result<T, Error>;

#[derive(Clone, Debug)]
pub struct Client {
    http: reqwest::Client,
    endpoint: Url,
    base: Url,
    api_key: String,
}

/// Proxy schemes `reqwest` can actually dial with the features we enable.
/// A userspace `tailscaled` exposes both a SOCKS5 server and an HTTP
/// CONNECT proxy, so either spelling works.
const SUPPORTED_PROXY_SCHEMES: [&str; 4] = ["http", "https", "socks5", "socks5h"];

/// Check the proxy URL before handing it to `reqwest`, so a typo in the
/// Settings field produces a message naming what would have worked
/// instead of a generic transport error at first request.
fn validate_proxy(raw: &str) -> Result<()> {
    let parsed = Url::parse(raw).map_err(|e| Error::InvalidProxy(format!("{raw}: {e}")))?;
    if !SUPPORTED_PROXY_SCHEMES.contains(&parsed.scheme()) {
        return Err(Error::InvalidProxy(format!(
            "{raw}: scheme `{}` is not supported (use http, https, socks5, or socks5h)",
            parsed.scheme()
        )));
    }
    Ok(())
}

impl Client {
    /// Build a client that talks to Stash directly.
    pub fn new(base_url: &str, api_key: &str) -> Result<Self> {
        Self::with_proxy(base_url, api_key, None)
    }

    /// Build a client that reaches Stash through `proxy_url`, which may be
    /// `http://`, `https://`, `socks5://`, or `socks5h://`. `None` or an
    /// empty string means direct.
    ///
    /// `reqwest` would otherwise auto-detect proxies from the environment
    /// and race with whatever the caller passed here. `.no_proxy()` turns
    /// that off so the caller's resolution is the only thing in effect.
    pub fn with_proxy(base_url: &str, api_key: &str, proxy_url: Option<&str>) -> Result<Self> {
        let mut headers = reqwest::header::HeaderMap::new();
        if !api_key.is_empty() {
            headers.insert("ApiKey", api_key.parse()?);
        }

        let mut builder = reqwest::Client::builder()
            .user_agent(concat!("stash-player/", env!("CARGO_PKG_VERSION")))
            .default_headers(headers)
            .no_proxy();

        if let Some(proxy) = proxy_url.map(str::trim).filter(|p| !p.is_empty()) {
            validate_proxy(proxy)?;
            let configured = reqwest::Proxy::all(proxy)
                .map_err(|e| Error::InvalidProxy(format!("{proxy}: {e}")))?;
            builder = builder.proxy(configured);
            tracing::debug!("stash client will use proxy {proxy}");
        }

        let http = builder.build()?;
        let base = Url::parse(base_url)?;
        // Tolerate a trailing slash on the base URL by joining instead of
        // string-concat. Stash exposes GraphQL at /graphql.
        let endpoint = base.join("graphql")?;

        Ok(Self {
            http,
            endpoint,
            base,
            api_key: api_key.to_owned(),
        })
    }

    /// Base URL of the Stash server (everything before `/graphql`). Used to
    /// build absolute URLs for paths returned by the API as relative refs,
    /// and to fetch image bytes via the same authenticated client.
    pub fn base_url(&self) -> &Url {
        &self.base
    }

    /// Underlying HTTP client. Reusing it for thumbnail fetches inherits the
    /// `ApiKey` header so authenticated screenshot URLs work.
    pub fn http(&self) -> &reqwest::Client {
        &self.http
    }

    /// Resolve a relative or absolute URL from the Stash API against the
    /// base URL, attaching no credentials. The media proxy uses this: it
    /// authenticates upstream with the `ApiKey` header instead, which
    /// keeps the key out of GStreamer logs and AVPlayer error strings.
    pub fn absolute_url(&self, url: &str) -> Result<Url> {
        match Url::parse(url) {
            Ok(u) => Ok(u),
            Err(url::ParseError::RelativeUrlWithoutBase) => Ok(self.base.join(url)?),
            Err(e) => Err(e.into()),
        }
    }

    /// Take an absolute or relative URL from the Stash API and produce one
    /// that's authenticated via the `apikey=` query param. Use this for
    /// consumers that can't carry our `ApiKey` request header and don't go
    /// through the media proxy, such as image widgets and "open in Stash"
    /// links.
    pub fn authenticated_url(&self, url: &str) -> Result<String> {
        let mut parsed = self.absolute_url(url)?;
        // Stash bakes `apikey=` into URLs it hands back (e.g. `paths.stream`),
        // so re-appending ours produces a doubled query param that some
        // server-side parsers reject.
        let already_authenticated = parsed
            .query_pairs()
            .any(|(k, _)| k.eq_ignore_ascii_case("apikey"));
        if !already_authenticated && !self.api_key.is_empty() {
            parsed
                .query_pairs_mut()
                .append_pair("apikey", &self.api_key);
        }
        Ok(parsed.into())
    }

    /// `query { version { version } }` — round-trips the server and returns
    /// the version string. The cheapest possible auth + reachability check.
    pub async fn version(&self) -> Result<String> {
        let resp: VersionResponse = self
            .graphql("query Version { version { version } }", &serde_json::json!({}))
            .await?;
        resp.version
            .version
            .ok_or(Error::MissingField("version.version"))
    }

    /// Fetch raw bytes from a URL using the same authenticated HTTP client
    /// (so screenshot URLs that require the `ApiKey` header work).
    pub async fn fetch_bytes(&self, url: &str) -> Result<Vec<u8>> {
        let resp = self.http.get(url).send().await?;
        let status = resp.status();
        if !status.is_success() {
            let body = resp.text().await.unwrap_or_default();
            return Err(Error::Status { status: status.as_u16(), body });
        }
        Ok(resp.bytes().await?.to_vec())
    }

    /// Page through scenes. `filter` carries the optional title query and
    /// sort, while `page` (1-indexed) and `per_page` control pagination.
    pub async fn find_scenes(
        &self,
        filter: &SceneFilter,
        page: u32,
        per_page: u32,
    ) -> Result<FindScenesPage> {
        let variables = scenes::find_scenes_variables(filter, page, per_page);
        let resp: scenes::FindScenesResponse = self
            .graphql(scenes::FIND_SCENES_QUERY, &variables)
            .await?;
        Ok(resp.find_scenes)
    }

    /// Look up a single scene by id. `Ok(None)` means the server has no
    /// scene with that id (rather than an error).
    pub async fn find_scene(&self, id: &str) -> Result<Option<Scene>> {
        let variables = serde_json::json!({ "id": id });
        let resp: scenes::FindSceneResponse =
            self.graphql(scenes::FIND_SCENE_QUERY, &variables).await?;
        Ok(resp.find_scene)
    }

    /// Write back a resume-time + watched-duration delta for a scene.
    /// Stash bumps the scene's `play_count` whenever `play_duration` is
    /// set (any positive value, even fractional). `resume_time` and
    /// `play_duration` are both optional — pass `None` to leave that
    /// field untouched on the server. Returns `true` on success per the
    /// schema's Boolean return.
    pub async fn save_scene_activity(
        &self,
        id: &str,
        resume_time: Option<f64>,
        play_duration: Option<f64>,
    ) -> Result<bool> {
        let variables = serde_json::json!({
            "id": id,
            "resume_time": resume_time,
            "playDuration": play_duration,
        });
        let resp: SceneSaveActivityResponse = self
            .graphql(SCENE_SAVE_ACTIVITY_MUTATION, &variables)
            .await?;
        Ok(resp.scene_save_activity)
    }

    /// Bump the O-counter for `id` by one. Returns the new counter value
    /// the server settled on (so the UI doesn't have to assume +1 in the
    /// face of races with another client).
    pub async fn increment_o(&self, id: &str) -> Result<i32> {
        let variables = serde_json::json!({ "id": id });
        let resp: SceneIncrementOResponse = self
            .graphql(SCENE_INCREMENT_O_MUTATION, &variables)
            .await?;
        Ok(resp.scene_increment_o)
    }

    /// Zero the O-counter for `id`. Returns the new counter value (0 on
    /// success).
    pub async fn reset_o(&self, id: &str) -> Result<i32> {
        let variables = serde_json::json!({ "id": id });
        let resp: SceneResetOResponse =
            self.graphql(SCENE_RESET_O_MUTATION, &variables).await?;
        Ok(resp.scene_reset_o)
    }

    async fn graphql<T: for<'de> Deserialize<'de>>(
        &self,
        query: &str,
        variables: &serde_json::Value,
    ) -> Result<T> {
        let body = GraphQlRequest { query, variables };
        let resp = self.http.post(self.endpoint.clone()).json(&body).send().await?;
        let status = resp.status();
        if !status.is_success() {
            let body = resp.text().await.unwrap_or_default();
            return Err(Error::Status { status: status.as_u16(), body });
        }

        let envelope: GraphQlEnvelope<T> = resp.json().await?;
        if let Some(errors) = envelope.errors
            && !errors.is_empty()
        {
            let joined = errors
                .iter()
                .map(|e| e.message.as_str())
                .collect::<Vec<_>>()
                .join("; ");
            return Err(Error::GraphQl(joined));
        }
        envelope.data.ok_or(Error::MissingField("data"))
    }
}

#[derive(Serialize)]
struct GraphQlRequest<'a> {
    query: &'a str,
    variables: &'a serde_json::Value,
}

#[derive(Deserialize)]
struct GraphQlEnvelope<T> {
    data: Option<T>,
    #[serde(default)]
    errors: Option<Vec<GraphQlError>>,
}

#[derive(Deserialize)]
struct GraphQlError {
    message: String,
}

#[derive(Deserialize)]
struct VersionResponse {
    version: Version,
}

#[derive(Deserialize)]
pub struct Version {
    pub version: Option<String>,
}

const SCENE_SAVE_ACTIVITY_MUTATION: &str = r#"
mutation SceneSaveActivity($id: ID!, $resume_time: Float, $playDuration: Float) {
  sceneSaveActivity(id: $id, resume_time: $resume_time, playDuration: $playDuration)
}
"#;

#[derive(Deserialize)]
struct SceneSaveActivityResponse {
    #[serde(rename = "sceneSaveActivity")]
    scene_save_activity: bool,
}

const SCENE_INCREMENT_O_MUTATION: &str = r#"
mutation SceneIncrementO($id: ID!) {
  sceneIncrementO(id: $id)
}
"#;

#[derive(Deserialize)]
struct SceneIncrementOResponse {
    #[serde(rename = "sceneIncrementO")]
    scene_increment_o: i32,
}

const SCENE_RESET_O_MUTATION: &str = r#"
mutation SceneResetO($id: ID!) {
  sceneResetO(id: $id)
}
"#;

#[derive(Deserialize)]
struct SceneResetOResponse {
    #[serde(rename = "sceneResetO")]
    scene_reset_o: i32,
}

/// Job status as returned by Stash's GraphQL API.
#[derive(Debug, Clone, Copy, PartialEq, Eq, Serialize, Deserialize)]
#[serde(rename_all = "SCREAMING_SNAKE_CASE")]
pub enum JobStatus {
    Ready,
    Running,
    Finished,
    Cancelled,
    Failed,
}

/// A server-side job (scan, generate, etc.) as returned by Stash.
#[derive(Debug, Clone, Deserialize)]
pub struct Job {
    pub id: String,
    pub status: JobStatus,
    #[serde(default)]
    pub progress: Option<f64>,
    #[serde(default)]
    pub description: String,
}

const METADATA_SCAN_MUTATION: &str = r#"
mutation MetadataScan {
  metadataScan(input: {})
}
"#;

#[derive(Deserialize)]
struct MetadataScanResponse {
    #[serde(rename = "metadataScan")]
    metadata_scan: String,
}

const JOBS_QUERY: &str = r#"
query Jobs {
  jobQueue {
    id
    status
    progress
    description
  }
}
"#;

#[derive(Deserialize)]
struct JobsResponse {
    #[serde(rename = "jobQueue")]
    jobs: Option<Vec<Job>>,
}

impl Client {
    /// Trigger a metadata scan on the server. Returns the job ID so the
    /// caller can poll progress via `jobs()`.
    pub async fn metadata_scan(&self) -> Result<String> {
        let resp: MetadataScanResponse = self
            .graphql(METADATA_SCAN_MUTATION, &serde_json::json!({}))
            .await?;
        Ok(resp.metadata_scan)
    }

    /// List all currently tracked jobs on the server (running + recently
    /// completed). Once a job finishes, Stash may drop it from the
    /// response after a short window.
    pub async fn jobs(&self) -> Result<Vec<Job>> {
        let resp: JobsResponse = self
            .graphql(JOBS_QUERY, &serde_json::json!({}))
            .await?;
        Ok(resp.jobs.unwrap_or_default())
    }
}
