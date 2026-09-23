//! UniFFI bridge so Swift (and other languages, eventually) can drive the
//! Rust client. The methods are sync from the foreign side: callers drop
//! into a background thread (`Task.detached` on Swift) and the bridge
//! `block_on`s an internal multi-thread tokio runtime.

use std::collections::hash_map::DefaultHasher;
use std::hash::{Hash, Hasher};
use std::path::PathBuf;
use std::sync::{Arc, OnceLock};

use parking_lot::Mutex;
use stash_api::{
    Client, FindScenesPage, Job, JobStatus, PerformerRef, Scene, SceneFile, SceneFilter,
    ScenePaths, SortDirection, SortKey, StudioRef,
};
use stash_player_core::{Config, cache, secrets};
use stash_player_proxy::MediaProxy;

uniffi::setup_scaffolding!();

fn rt() -> &'static tokio::runtime::Runtime {
    static RT: OnceLock<tokio::runtime::Runtime> = OnceLock::new();
    RT.get_or_init(|| {
        tokio::runtime::Builder::new_multi_thread()
            .enable_all()
            .build()
            .expect("failed to start tokio runtime")
    })
}

#[derive(Debug, thiserror::Error, uniffi::Error)]
#[uniffi(flat_error)]
pub enum FfiError {
    #[error("network: {0}")]
    Network(String),
    #[error("graphql: {0}")]
    GraphQl(String),
    #[error("not connected")]
    NotConnected,
    #[error("invalid url: {0}")]
    InvalidUrl(String),
    #[error("config: {0}")]
    Config(String),
    #[error("keychain: {0}")]
    Keychain(String),
    #[error("io: {0}")]
    Io(String),
}

impl From<stash_api::Error> for FfiError {
    fn from(e: stash_api::Error) -> Self {
        match e {
            stash_api::Error::InvalidUrl(e) => FfiError::InvalidUrl(e.to_string()),
            stash_api::Error::Http(e) => FfiError::Network(e.to_string()),
            stash_api::Error::InvalidHeader(e) => FfiError::InvalidUrl(e.to_string()),
            stash_api::Error::InvalidProxy(e) => FfiError::InvalidUrl(e.to_string()),
            stash_api::Error::Status { status, body } => {
                FfiError::Network(format!("HTTP {status}: {body}"))
            }
            stash_api::Error::GraphQl(s) => FfiError::GraphQl(s),
            stash_api::Error::MissingField(f) => FfiError::GraphQl(format!("missing field: {f}")),
        }
    }
}

impl From<stash_player_core::config::Error> for FfiError {
    fn from(e: stash_player_core::config::Error) -> Self {
        FfiError::Config(e.to_string())
    }
}

impl From<secrets::Error> for FfiError {
    fn from(e: secrets::Error) -> Self {
        FfiError::Keychain(e.to_string())
    }
}

impl From<std::io::Error> for FfiError {
    fn from(e: std::io::Error) -> Self {
        FfiError::Io(e.to_string())
    }
}

#[derive(Clone, uniffi::Record)]
pub struct FfiCredentials {
    pub base_url: String,
    pub api_key: String,
    /// Empty means "no proxy configured"; the resolver then consults the
    /// standard environment variables.
    pub proxy_url: String,
}

impl std::fmt::Debug for FfiCredentials {
    /// Hand-written: `api_key` is a secret, and `proxy_url` may itself
    /// carry `user:pass@` credentials, so neither belongs in `{:?}`.
    fn fmt(&self, f: &mut std::fmt::Formatter<'_>) -> std::fmt::Result {
        f.debug_struct("FfiCredentials")
            .field("base_url", &self.base_url)
            .field("api_key_set", &!self.api_key.is_empty())
            .field("proxy_url_set", &!self.proxy_url.is_empty())
            .finish()
    }
}

#[derive(Debug, Clone, uniffi::Record)]
pub struct FfiPerformer {
    pub id: String,
    pub name: String,
}

impl From<PerformerRef> for FfiPerformer {
    fn from(p: PerformerRef) -> Self {
        Self {
            id: p.id,
            name: p.name,
        }
    }
}

#[derive(Debug, Clone, uniffi::Record)]
pub struct FfiStudio {
    pub id: String,
    pub name: String,
}

impl From<StudioRef> for FfiStudio {
    fn from(s: StudioRef) -> Self {
        Self {
            id: s.id,
            name: s.name,
        }
    }
}

#[derive(Debug, Clone, uniffi::Record)]
pub struct FfiScenePaths {
    pub screenshot: Option<String>,
    pub preview: Option<String>,
    pub sprite: Option<String>,
    pub stream: Option<String>,
    pub webp: Option<String>,
}

impl From<ScenePaths> for FfiScenePaths {
    fn from(p: ScenePaths) -> Self {
        Self {
            screenshot: p.screenshot,
            preview: p.preview,
            sprite: p.sprite,
            stream: p.stream,
            webp: p.webp,
        }
    }
}

#[derive(Debug, Clone, uniffi::Record)]
pub struct FfiSceneFile {
    pub duration: Option<f64>,
    pub width: Option<i32>,
    pub height: Option<i32>,
    pub video_codec: Option<String>,
    pub frame_rate: Option<f64>,
}

impl From<SceneFile> for FfiSceneFile {
    fn from(f: SceneFile) -> Self {
        Self {
            duration: f.duration,
            width: f.width,
            height: f.height,
            video_codec: f.video_codec,
            frame_rate: f.frame_rate,
        }
    }
}

#[derive(Debug, Clone, uniffi::Record)]
pub struct FfiScene {
    pub id: String,
    pub display_title: String,
    pub title: Option<String>,
    pub details: Option<String>,
    pub date: Option<String>,
    pub rating100: Option<i32>,
    pub paths: FfiScenePaths,
    pub files: Vec<FfiSceneFile>,
    pub studio: Option<FfiStudio>,
    pub performers: Vec<FfiPerformer>,
    pub resume_time: Option<f64>,
    pub play_count: Option<i32>,
    pub play_duration: Option<f64>,
    pub o_counter: Option<i32>,
}

impl From<Scene> for FfiScene {
    fn from(s: Scene) -> Self {
        let display_title = s.display_title();
        Self {
            id: s.id,
            display_title,
            title: s.title,
            details: s.details,
            date: s.date,
            rating100: s.rating100,
            paths: s.paths.into(),
            files: s.files.into_iter().map(Into::into).collect(),
            studio: s.studio.map(Into::into),
            performers: s.performers.into_iter().map(Into::into).collect(),
            resume_time: s.resume_time,
            play_count: s.play_count,
            play_duration: s.play_duration,
            o_counter: s.o_counter,
        }
    }
}

/// Mirrors `stash_api::SortKey` so Swift can pick the order the library
/// uses. `Random` pairs with `FfiSceneFilter::random_seed` to keep paging
/// + neighbor lookups stable across calls.
#[derive(Debug, Clone, Copy, uniffi::Enum)]
pub enum FfiSortKey {
    Date,
    Title,
    Rating,
    PlayCount,
    Duration,
    CreatedAt,
    UpdatedAt,
    Random,
}

impl From<FfiSortKey> for SortKey {
    fn from(k: FfiSortKey) -> Self {
        match k {
            FfiSortKey::Date => SortKey::Date,
            FfiSortKey::Title => SortKey::Title,
            FfiSortKey::Rating => SortKey::Rating,
            FfiSortKey::PlayCount => SortKey::PlayCount,
            FfiSortKey::Duration => SortKey::Duration,
            FfiSortKey::CreatedAt => SortKey::CreatedAt,
            FfiSortKey::UpdatedAt => SortKey::UpdatedAt,
            FfiSortKey::Random => SortKey::Random,
        }
    }
}

#[derive(Debug, Clone, Copy, uniffi::Enum)]
pub enum FfiSortDirection {
    Asc,
    Desc,
}

impl From<FfiSortDirection> for SortDirection {
    fn from(d: FfiSortDirection) -> Self {
        match d {
            FfiSortDirection::Asc => SortDirection::Asc,
            FfiSortDirection::Desc => SortDirection::Desc,
        }
    }
}

/// Full Stash filter as carried across the bridge. Mirrors
/// `stash_api::SceneFilter` field-for-field. Swift constructs one of these
/// per request; the macOS app holds the canonical state in `LibraryView`.
#[derive(Debug, Clone, uniffi::Record)]
pub struct FfiSceneFilter {
    pub query: Option<String>,
    pub sort: FfiSortKey,
    pub direction: FfiSortDirection,
    pub min_rating: Option<i32>,
    pub organized: Option<bool>,
    pub hide_tracked: bool,
    /// `Some(false)` hides scenes Stash flagged as interactive; `Some(true)`
    /// keeps only those; `None` doesn't filter. Mirrors
    /// `stash_api::SceneFilter::interactive`.
    pub interactive: Option<bool>,
    pub random_seed: Option<u32>,
}

impl From<FfiSceneFilter> for SceneFilter {
    fn from(f: FfiSceneFilter) -> Self {
        SceneFilter {
            query: f.query.filter(|q| !q.is_empty()),
            sort: f.sort.into(),
            direction: f.direction.into(),
            min_rating: f.min_rating,
            organized: f.organized,
            interactive: f.interactive,
            hide_tracked: f.hide_tracked,
            random_seed: f.random_seed,
        }
    }
}

#[derive(Debug, Clone, uniffi::Record)]
pub struct FfiScenesPage {
    pub count: i64,
    pub scenes: Vec<FfiScene>,
}

impl From<FindScenesPage> for FfiScenesPage {
    fn from(p: FindScenesPage) -> Self {
        Self {
            count: p.count,
            scenes: p.scenes.into_iter().map(Into::into).collect(),
        }
    }
}

#[derive(Debug, Clone, Copy, uniffi::Enum)]
pub enum FfiJobStatus {
    Ready,
    Running,
    Finished,
    Cancelled,
    Failed,
}

impl From<JobStatus> for FfiJobStatus {
    fn from(s: JobStatus) -> Self {
        match s {
            JobStatus::Ready => FfiJobStatus::Ready,
            JobStatus::Running => FfiJobStatus::Running,
            JobStatus::Finished => FfiJobStatus::Finished,
            JobStatus::Cancelled => FfiJobStatus::Cancelled,
            JobStatus::Failed => FfiJobStatus::Failed,
        }
    }
}

#[derive(Debug, Clone, uniffi::Record)]
pub struct FfiJob {
    pub id: String,
    pub status: FfiJobStatus,
    pub progress: Option<f64>,
    pub description: String,
}

impl From<Job> for FfiJob {
    fn from(j: Job) -> Self {
        Self {
            id: j.id,
            status: j.status.into(),
            progress: j.progress,
            description: j.description,
        }
    }
}

/// Explain a connection failure caused by a `socks5://` proxy unable to
/// resolve the server's hostname, if `proxy_url` looks like one. Empty
/// string means "no proxy configured", matching the convention used
/// elsewhere on this bridge (`connect`, `save_credentials`). `None` from
/// the underlying `stash_api` helper (no hint applies) becomes `None` here.
#[uniffi::export]
pub fn proxy_failure_hint(proxy_url: String) -> Option<String> {
    let trimmed = proxy_url.trim();
    if trimmed.is_empty() {
        return None;
    }
    stash_api::proxy_failure_hint(Some(trimmed)).map(str::to_owned)
}

/// Idempotent tracing-subscriber setup. Safe to call from `App.init()` on
/// the Swift side at every launch.
#[uniffi::export]
pub fn init_logging() {
    static INIT: OnceLock<()> = OnceLock::new();
    INIT.get_or_init(|| {
        let env_filter = tracing_subscriber::EnvFilter::try_from_default_env()
            .unwrap_or_else(|_| tracing_subscriber::EnvFilter::new("info,stash_player_ffi=debug"));
        let _ = tracing_subscriber::fmt()
            .with_env_filter(env_filter)
            .with_target(false)
            .try_init();
    });
}

#[derive(uniffi::Object)]
pub struct StashPlayer {
    inner: Mutex<Option<Client>>,
    /// Bound lazily: unlike the GTK app there is no single startup point
    /// here to bind from.
    proxy: Mutex<Option<Arc<MediaProxy>>>,
    /// Serialises `connect` so a slow connection cannot interleave with a
    /// later one and leave the media proxy pointed at a superseded server.
    connect_lock: Mutex<()>,
}

#[uniffi::export]
impl StashPlayer {
    #[uniffi::constructor]
    pub fn new() -> Arc<Self> {
        Arc::new(Self {
            inner: Mutex::new(None),
            proxy: Mutex::new(None),
            connect_lock: Mutex::new(()),
        })
    }

    /// Build the GraphQL client and round-trip a `version` query so we know
    /// the URL/key actually work. On success the client is cached for
    /// subsequent calls and the server's reported version string is
    /// returned to the foreign caller.
    ///
    /// `proxy_url` may be empty, in which case the standard proxy
    /// environment variables are consulted.
    pub fn connect(
        &self,
        base_url: String,
        api_key: String,
        proxy_url: String,
    ) -> Result<String, FfiError> {
        let _serialise = self.connect_lock.lock();
        let proxy = stash_player_core::resolve_proxy(Some(&proxy_url));
        let client = Client::with_proxy(&base_url, &api_key, proxy.as_deref())?;
        let version = rt().block_on(client.version())?;
        *self.inner.lock() = Some(client.clone());
        // Keep the media proxy pointed at the same server the API uses.
        self.proxy()?.set_client(Some(client));
        Ok(version)
    }

    pub fn disconnect(&self) {
        let _serialise = self.connect_lock.lock();
        *self.inner.lock() = None;
        let proxy = self.proxy.lock().clone();
        if let Some(proxy) = proxy {
            proxy.set_client(None);
        }
    }

    pub fn is_connected(&self) -> bool {
        self.inner.lock().is_some()
    }

    pub fn list_scenes(
        &self,
        filter: FfiSceneFilter,
        page: u32,
        per_page: u32,
    ) -> Result<FfiScenesPage, FfiError> {
        let client = self.client()?;
        let filter: SceneFilter = filter.into();
        let page = rt().block_on(client.find_scenes(&filter, page, per_page))?;
        Ok(page.into())
    }

    /// Bump the scene's O-counter by one. Returns the new value the server
    /// settled on so the UI doesn't have to assume +1.
    pub fn increment_o(&self, id: String) -> Result<i32, FfiError> {
        let client = self.client()?;
        Ok(rt().block_on(client.increment_o(&id))?)
    }

    /// Zero the scene's O-counter. Returns the new value (always 0 on
    /// success, but we mirror the Rust API).
    pub fn reset_o(&self, id: String) -> Result<i32, FfiError> {
        let client = self.client()?;
        Ok(rt().block_on(client.reset_o(&id))?)
    }

    pub fn get_scene(&self, id: String) -> Result<Option<FfiScene>, FfiError> {
        let client = self.client()?;
        let scene = rt().block_on(client.find_scene(&id))?;
        Ok(scene.map(Into::into))
    }

    pub fn save_activity(
        &self,
        id: String,
        resume_time: Option<f64>,
        play_duration: Option<f64>,
    ) -> Result<bool, FfiError> {
        let client = self.client()?;
        let ok = rt().block_on(client.save_scene_activity(&id, resume_time, play_duration))?;
        Ok(ok)
    }

    /// Rewrite a stream URL to point at the loopback media proxy. AVPlayer
    /// fetches the URL itself, so it can carry neither our `ApiKey` header
    /// nor the upstream proxy setting; the loopback hop gives it both and
    /// keeps the API key out of AVFoundation's error strings.
    pub fn playback_url(&self, url: String) -> Result<String, FfiError> {
        let proxy = self.proxy()?;
        proxy.playback_url(&url).map_err(|e| match e {
            stash_player_proxy::Error::NotConfigured => FfiError::NotConnected,
            other => FfiError::Network(other.to_string()),
        })
    }

    pub fn load_saved_credentials(&self) -> Result<Option<FfiCredentials>, FfiError> {
        let cfg = Config::load()?;
        let key = match rt().block_on(secrets::load_api_key()) {
            Ok(k) => k,
            Err(e) => {
                tracing::warn!("failed to load API key from keychain: {e}");
                None
            }
        };
        if !cfg.has_custom_stash_url() {
            return Ok(None);
        }
        Ok(Some(FfiCredentials {
            proxy_url: cfg.proxy_url.clone().unwrap_or_default(),
            base_url: cfg.stash_url,
            api_key: key.unwrap_or_default(),
        }))
    }

    pub fn save_credentials(
        &self,
        base_url: String,
        api_key: String,
        proxy_url: String,
    ) -> Result<(), FfiError> {
        let mut cfg = Config::load().unwrap_or_default();
        cfg.stash_url = base_url;
        // Store None rather than Some("") so the config file stays clean
        // and the resolver sees a genuine absence.
        let trimmed = proxy_url.trim();
        cfg.proxy_url = (!trimmed.is_empty()).then(|| trimmed.to_owned());
        cfg.save()?;
        rt().block_on(secrets::store_api_key(&api_key))?;
        Ok(())
    }

    /// Disk-cached thumbnail bytes. Cache key is the URL. Body is whatever
    /// Stash returned (jpeg/webp); the foreign side decodes.
    pub fn fetch_thumbnail(&self, url: String) -> Result<Vec<u8>, FfiError> {
        let path = thumb_cache_path(&url)?;
        if let Ok(bytes) = std::fs::read(&path) {
            return Ok(bytes);
        }
        let client = self.client()?;
        let bytes = rt().block_on(client.fetch_bytes(&url))?;
        if let Some(parent) = path.parent() {
            let _ = std::fs::create_dir_all(parent);
        }
        let _ = std::fs::write(&path, &bytes);
        Ok(bytes)
    }

    /// Trigger a metadata scan on the server. Returns the job ID so the
    /// caller can poll progress via `jobs()`.
    pub fn metadata_scan(&self) -> Result<String, FfiError> {
        let client = self.client()?;
        Ok(rt().block_on(client.metadata_scan())?)
    }

    /// List all currently tracked jobs (running + recently completed).
    pub fn jobs(&self) -> Result<Vec<FfiJob>, FfiError> {
        let client = self.client()?;
        let jobs = rt().block_on(client.jobs())?;
        Ok(jobs.into_iter().map(Into::into).collect())
    }
}

impl StashPlayer {
    fn client(&self) -> Result<Client, FfiError> {
        self.inner.lock().clone().ok_or(FfiError::NotConnected)
    }

    /// Get the media proxy, binding it on first use.
    ///
    /// The client is cloned out of `inner` before the proxy lock is
    /// taken. Never hold both locks: `connect` takes them in the opposite
    /// order and holding both would deadlock under concurrent calls from
    /// Swift.
    fn proxy(&self) -> Result<Arc<MediaProxy>, FfiError> {
        let current = self.inner.lock().clone();

        // Held across the `block_on` below on purpose: this is what makes
        // the bind-and-store sequence atomic. Two threads racing to bind
        // would otherwise each start a listener and only one `Arc` would
        // survive into `guard`, leaking the other's bound port.
        let mut guard = self.proxy.lock();
        if let Some(existing) = guard.as_ref() {
            return Ok(Arc::clone(existing));
        }

        let proxy = rt()
            .block_on(MediaProxy::bind())
            .map(Arc::new)
            .map_err(|e| FfiError::Io(e.to_string()))?;
        proxy.set_client(current);
        *guard = Some(Arc::clone(&proxy));
        Ok(proxy)
    }
}

fn thumb_cache_path(url: &str) -> Result<PathBuf, FfiError> {
    let mut hasher = DefaultHasher::new();
    url.hash(&mut hasher);
    let name = format!("{:016x}.bin", hasher.finish());
    Ok(cache::thumb_dir()?.join(name))
}
