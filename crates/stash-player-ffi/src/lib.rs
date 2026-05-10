//! UniFFI bridge so Swift (and other languages, eventually) can drive the
//! Rust client. The methods are sync from the foreign side: callers drop
//! into a background thread (`Task.detached` on Swift) and the bridge
//! `block_on`s an internal multi-thread tokio runtime.

use std::collections::hash_map::DefaultHasher;
use std::hash::{Hash, Hasher};
use std::path::PathBuf;
use std::sync::{Arc, OnceLock};

use parking_lot::Mutex;
use stash_api::{Client, FindScenesPage, PerformerRef, Scene, SceneFile, SceneFilter, ScenePaths, StudioRef};
use stash_player_core::{Config, cache, secrets};

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

#[derive(Debug, Clone, uniffi::Record)]
pub struct FfiCredentials {
    pub base_url: String,
    pub api_key: String,
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
}

#[uniffi::export]
impl StashPlayer {
    #[uniffi::constructor]
    pub fn new() -> Arc<Self> {
        Arc::new(Self {
            inner: Mutex::new(None),
        })
    }

    /// Build the GraphQL client and round-trip a `version` query so we know
    /// the URL/key actually work. On success the client is cached for
    /// subsequent calls and the server's reported version string is
    /// returned to the foreign caller.
    pub fn connect(&self, base_url: String, api_key: String) -> Result<String, FfiError> {
        let client = Client::new(&base_url, &api_key)?;
        let version = rt().block_on(client.version())?;
        *self.inner.lock() = Some(client);
        Ok(version)
    }

    pub fn disconnect(&self) {
        *self.inner.lock() = None;
    }

    pub fn is_connected(&self) -> bool {
        self.inner.lock().is_some()
    }

    pub fn list_scenes(
        &self,
        query: Option<String>,
        page: u32,
        per_page: u32,
    ) -> Result<FfiScenesPage, FfiError> {
        let client = self.client()?;
        let mut filter = SceneFilter::new();
        filter.query = query.filter(|q| !q.is_empty());
        let page = rt().block_on(client.find_scenes(&filter, page, per_page))?;
        Ok(page.into())
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

    /// Bake `?apikey=` into a stream URL so AVPlayer (which can't carry an
    /// `ApiKey` request header) can hit it.
    pub fn authenticated_url(&self, url: String) -> Result<String, FfiError> {
        let client = self.client()?;
        Ok(client.authenticated_url(&url)?)
    }

    pub fn load_saved_credentials(&self) -> Result<Option<FfiCredentials>, FfiError> {
        let cfg = Config::load()?;
        let key = rt().block_on(secrets::load_api_key())?;
        match key {
            Some(api_key) if !cfg.stash_url.is_empty() => Ok(Some(FfiCredentials {
                base_url: cfg.stash_url,
                api_key,
            })),
            _ => Ok(None),
        }
    }

    pub fn save_credentials(&self, base_url: String, api_key: String) -> Result<(), FfiError> {
        let mut cfg = Config::load().unwrap_or_default();
        cfg.stash_url = base_url;
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
}

impl StashPlayer {
    fn client(&self) -> Result<Client, FfiError> {
        self.inner.lock().clone().ok_or(FfiError::NotConnected)
    }
}

fn thumb_cache_path(url: &str) -> Result<PathBuf, FfiError> {
    let mut hasher = DefaultHasher::new();
    url.hash(&mut hasher);
    let name = format!("{:016x}.bin", hasher.finish());
    Ok(cache::thumb_dir()?.join(name))
}
