//! API key persistence keyed off `service = "stash-player"` /
//! `account = "stash-api-key"`. Backend differs by platform:
//!
//! * Linux uses the Secret Service (GNOME Keyring, KWallet, etc.) over
//!   D-Bus. The transport is async, so the public API stays async.
//! * macOS uses the system Keychain via `security-framework`. The
//!   underlying calls are synchronous; we keep the same async signature
//!   by hopping through `tokio::task::spawn_blocking`.
//!
//! Either way, callers get the same `async fn load/store/delete_api_key`
//! contract.

use thiserror::Error;

const SERVICE: &str = "stash-player";
const ACCOUNT: &str = "stash-api-key";

#[derive(Debug, Error)]
pub enum Error {
    #[cfg(target_os = "linux")]
    #[error("secret service: {0}")]
    SecretService(#[from] secret_service::Error),
    #[cfg(target_os = "macos")]
    #[error("keychain: {0}")]
    Keychain(String),
    #[cfg(target_os = "macos")]
    #[error("background task panicked: {0}")]
    Join(#[from] tokio::task::JoinError),
    #[error("api key contained non-utf8 bytes")]
    NonUtf8,
}

pub type Result<T> = std::result::Result<T, Error>;

#[cfg(target_os = "linux")]
mod linux;
#[cfg(target_os = "linux")]
pub use linux::{delete_api_key, load_api_key, store_api_key};

#[cfg(target_os = "macos")]
mod macos;
#[cfg(target_os = "macos")]
pub use macos::{delete_api_key, load_api_key, store_api_key};
