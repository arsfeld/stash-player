use std::fs;
use std::io;
use std::path::PathBuf;

use directories::ProjectDirs;
use serde::{Deserialize, Serialize};
use thiserror::Error;

const DEFAULT_STASH_URL: &str = "https://stash.example.com";

#[derive(Debug, Error)]
pub enum Error {
    #[error("could not locate XDG config directory")]
    NoConfigDir,
    #[error("io: {0}")]
    Io(#[from] io::Error),
    #[error("toml decode: {0}")]
    TomlDecode(#[from] toml::de::Error),
    #[error("toml encode: {0}")]
    TomlEncode(#[from] toml::ser::Error),
}

pub type Result<T> = std::result::Result<T, Error>;

#[derive(Debug, Clone, Serialize, Deserialize)]
pub struct Config {
    pub stash_url: String,
    /// Whether the inline player should start playing as soon as a scene
    /// loads (or when the user navigates with prev/next).
    #[serde(default)]
    pub autoplay: bool,
    /// Last volume the user picked in the video player, in `0.0..=1.0`.
    /// Restored on every fresh stream so the level persists across scenes
    /// and app restarts.
    #[serde(default = "default_volume")]
    pub volume: f64,
    /// Mute state, persisted alongside `volume` so unmuting returns to the
    /// previously chosen level.
    #[serde(default)]
    pub muted: bool,
    /// Whether the library should exclude scenes Stash flagged as
    /// interactive (funscript-bearing). Persisted so the "Hide interactive"
    /// toolbar toggle survives app restarts.
    #[serde(default)]
    pub hide_interactive: bool,
    /// Upstream HTTP or SOCKS5 proxy for all Stash traffic. Set this when
    /// the server is only reachable through something like a userspace
    /// tailscaled. Absent or empty means "consult the environment", not
    /// "force a direct connection" — see `resolve_proxy`.
    #[serde(default)]
    pub proxy_url: Option<String>,
}

fn default_volume() -> f64 {
    1.0
}

impl Default for Config {
    fn default() -> Self {
        Self {
            stash_url: DEFAULT_STASH_URL.to_owned(),
            autoplay: false,
            volume: default_volume(),
            muted: false,
            hide_interactive: false,
            proxy_url: None,
        }
    }
}

impl Config {
    /// Load config from disk, returning the default config if no file exists yet.
    pub fn load() -> Result<Self> {
        let path = config_path()?;
        match fs::read_to_string(&path) {
            Ok(text) => Ok(toml::from_str(&text)?),
            Err(e) if e.kind() == io::ErrorKind::NotFound => Ok(Self::default()),
            Err(e) => Err(e.into()),
        }
    }

    pub fn save(&self) -> Result<()> {
        let path = config_path()?;
        if let Some(parent) = path.parent() {
            fs::create_dir_all(parent)?;
        }
        let text = toml::to_string_pretty(self)?;
        fs::write(&path, text)?;
        Ok(())
    }

    pub fn has_custom_stash_url(&self) -> bool {
        !self.stash_url.trim().is_empty() && self.stash_url != DEFAULT_STASH_URL
    }
}

fn project_dirs() -> Result<ProjectDirs> {
    ProjectDirs::from("one", "arsfeld", "stash-player").ok_or(Error::NoConfigDir)
}

fn config_path() -> Result<PathBuf> {
    Ok(project_dirs()?.config_dir().join("config.toml"))
}

/// Environment variables consulted when no proxy is configured, in
/// priority order. Both spellings of each name are conventional, so both
/// are checked.
pub(crate) const PROXY_ENV_VARS: [&str; 6] = [
    "ALL_PROXY",
    "all_proxy",
    "HTTPS_PROXY",
    "https_proxy",
    "HTTP_PROXY",
    "http_proxy",
];

/// Resolve the proxy that should actually be used: the configured value
/// wins, then the standard environment variables, then none.
///
/// `reqwest` does its own environment-proxy detection, which would race
/// with an explicitly configured value and make the effective proxy
/// unpredictable. Callers disable that detection and apply this result
/// instead, so there is exactly one answer to "what proxy am I using".
///
/// `NO_PROXY` is deliberately not honoured: all traffic goes to a single
/// Stash host, so per-host bypass rules have nothing to act on.
pub fn resolve_proxy(configured: Option<&str>) -> Option<String> {
    if let Some(explicit) = configured.map(str::trim).filter(|s| !s.is_empty()) {
        return Some(explicit.to_owned());
    }
    PROXY_ENV_VARS
        .iter()
        .find_map(|name| std::env::var(name).ok())
        .map(|v| v.trim().to_owned())
        .filter(|v| !v.is_empty())
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn default_uses_placeholder_url_and_autoplay_off() {
        let c = Config::default();
        assert_eq!(c.stash_url, DEFAULT_STASH_URL);
        assert!(!c.autoplay);
        assert_eq!(c.volume, 1.0);
        assert!(!c.muted);
        assert!(!c.hide_interactive);
        assert_eq!(c.proxy_url, None);
    }

    #[test]
    fn round_trips_through_toml() {
        let original = Config {
            stash_url: "https://stash.example.test".into(),
            autoplay: true,
            volume: 0.42,
            muted: true,
            hide_interactive: true,
            proxy_url: None,
        };
        let text = toml::to_string_pretty(&original).unwrap();
        let parsed: Config = toml::from_str(&text).unwrap();
        assert_eq!(parsed.stash_url, original.stash_url);
        assert_eq!(parsed.autoplay, original.autoplay);
        assert_eq!(parsed.volume, original.volume);
        assert_eq!(parsed.muted, original.muted);
        assert_eq!(parsed.hide_interactive, original.hide_interactive);
    }

    #[test]
    fn tolerates_missing_optional_fields() {
        // Older config files (written before autoplay/volume/muted/
        // hide_interactive existed) only carry stash_url. #[serde(default)]
        // should let them load without error and fall back to the documented
        // defaults.
        let parsed: Config = toml::from_str(r#"stash_url = "https://x.test""#).unwrap();
        assert_eq!(parsed.stash_url, "https://x.test");
        assert!(!parsed.autoplay);
        assert_eq!(parsed.volume, 1.0);
        assert!(!parsed.muted);
        assert!(!parsed.hide_interactive);
        assert_eq!(parsed.proxy_url, None);
    }

    #[test]
    fn rejects_config_missing_stash_url() {
        // stash_url has no default and is the one piece of info we can't
        // invent — surface a hard error instead of silently substituting.
        let err = toml::from_str::<Config>(r#"autoplay = true"#).unwrap_err();
        assert!(err.message().contains("stash_url"));
    }

    #[test]
    fn detects_custom_stash_url() {
        assert!(!Config::default().has_custom_stash_url());
        assert!(!Config {
            stash_url: "  ".into(),
            autoplay: false,
            volume: 1.0,
            muted: false,
            hide_interactive: false,
            proxy_url: None,
        }
        .has_custom_stash_url());
        assert!(Config {
            stash_url: "https://stash.example.test".into(),
            autoplay: false,
            volume: 1.0,
            muted: false,
            hide_interactive: false,
            proxy_url: None,
        }
        .has_custom_stash_url());
    }

    #[test]
    fn proxy_url_defaults_to_none_and_round_trips() {
        assert_eq!(Config::default().proxy_url, None);

        let original = Config {
            stash_url: "https://stash.example.test".into(),
            autoplay: true,
            volume: 0.42,
            muted: true,
            hide_interactive: true,
            proxy_url: Some("socks5://127.0.0.1:1055".into()),
        };
        let text = toml::to_string_pretty(&original).unwrap();
        let parsed: Config = toml::from_str(&text).unwrap();
        assert_eq!(parsed.proxy_url, original.proxy_url);
    }

    #[test]
    fn config_without_proxy_url_still_loads() {
        // Config files written before this field existed must keep working.
        let parsed: Config = toml::from_str(r#"stash_url = "https://x.test""#).unwrap();
        assert_eq!(parsed.proxy_url, None);
    }

    #[test]
    fn configured_proxy_wins_over_environment() {
        // Env vars are read process-wide, so this test asserts precedence
        // using an explicitly configured value, which short-circuits before
        // any env lookup happens.
        assert_eq!(
            resolve_proxy(Some("socks5://127.0.0.1:1055")),
            Some("socks5://127.0.0.1:1055".to_owned())
        );
    }

    #[test]
    fn blank_configured_proxy_falls_through_rather_than_disabling() {
        // Clearing the Settings field must mean "fall back to the
        // environment", not "force direct". An empty string is how both
        // frontends represent an empty text field.
        let from_env = resolve_proxy(None);
        assert_eq!(resolve_proxy(Some("")), from_env);
        assert_eq!(resolve_proxy(Some("   ")), from_env);
    }

    #[test]
    fn proxy_env_var_names_are_checked_in_priority_order() {
        assert_eq!(
            PROXY_ENV_VARS,
            [
                "ALL_PROXY",
                "all_proxy",
                "HTTPS_PROXY",
                "https_proxy",
                "HTTP_PROXY",
                "http_proxy",
            ]
        );
    }
}
