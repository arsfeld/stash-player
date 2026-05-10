//! API key persistence via the Linux Secret Service (GNOME Keyring,
//! KWallet, etc.). All functions are async because the underlying D-Bus
//! transport is — call them inside a tokio runtime.

use std::collections::HashMap;

use secret_service::{EncryptionType, SecretService};
use thiserror::Error;

const ATTR_APP: &str = "stash-player";
const ATTR_KEY: &str = "stash-api-key";

#[derive(Debug, Error)]
pub enum Error {
    #[error("secret service: {0}")]
    SecretService(#[from] secret_service::Error),
    #[error("api key contained non-utf8 bytes")]
    NonUtf8,
}

pub type Result<T> = std::result::Result<T, Error>;

fn attrs() -> HashMap<&'static str, &'static str> {
    let mut a = HashMap::new();
    a.insert("application", ATTR_APP);
    a.insert("key", ATTR_KEY);
    a
}

pub async fn load_api_key() -> Result<Option<String>> {
    let ss = SecretService::connect(EncryptionType::Dh).await?;
    let collection = ss.get_default_collection().await?;
    if collection.is_locked().await? {
        collection.unlock().await?;
    }
    let items = collection.search_items(attrs()).await?;
    let Some(item) = items.into_iter().next() else {
        return Ok(None);
    };
    let bytes = item.get_secret().await?;
    let s = String::from_utf8(bytes).map_err(|_| Error::NonUtf8)?;
    Ok(Some(s))
}

pub async fn store_api_key(key: &str) -> Result<()> {
    let ss = SecretService::connect(EncryptionType::Dh).await?;
    let collection = ss.get_default_collection().await?;
    if collection.is_locked().await? {
        collection.unlock().await?;
    }
    collection
        .create_item(
            "stash-player API key",
            attrs(),
            key.as_bytes(),
            true, // replace existing
            "text/plain",
        )
        .await?;
    Ok(())
}

pub async fn delete_api_key() -> Result<()> {
    let ss = SecretService::connect(EncryptionType::Dh).await?;
    let collection = ss.get_default_collection().await?;
    if collection.is_locked().await? {
        collection.unlock().await?;
    }
    for item in collection.search_items(attrs()).await? {
        item.delete().await?;
    }
    Ok(())
}
