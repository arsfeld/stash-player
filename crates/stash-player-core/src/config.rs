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
}

impl Default for Config {
    fn default() -> Self {
        Self {
            stash_url: DEFAULT_STASH_URL.to_owned(),
            autoplay: false,
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

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn default_uses_placeholder_url_and_autoplay_off() {
        let c = Config::default();
        assert_eq!(c.stash_url, DEFAULT_STASH_URL);
        assert!(!c.autoplay);
    }

    #[test]
    fn round_trips_through_toml() {
        let original = Config {
            stash_url: "https://stash.example.test".into(),
            autoplay: true,
        };
        let text = toml::to_string_pretty(&original).unwrap();
        let parsed: Config = toml::from_str(&text).unwrap();
        assert_eq!(parsed.stash_url, original.stash_url);
        assert_eq!(parsed.autoplay, original.autoplay);
    }

    #[test]
    fn tolerates_missing_autoplay_field() {
        // Older config files (written before autoplay existed) only carry
        // stash_url. #[serde(default)] should let them load without error.
        let parsed: Config = toml::from_str(r#"stash_url = "https://x.test""#).unwrap();
        assert_eq!(parsed.stash_url, "https://x.test");
        assert!(!parsed.autoplay);
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
        }
        .has_custom_stash_url());
        assert!(Config {
            stash_url: "https://stash.example.test".into(),
            autoplay: false,
        }
        .has_custom_stash_url());
    }
}
