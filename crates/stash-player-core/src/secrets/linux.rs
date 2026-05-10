use std::collections::HashMap;

use secret_service::{EncryptionType, SecretService};

use super::{ACCOUNT, Result, SERVICE};

fn attrs() -> HashMap<&'static str, &'static str> {
    let mut a = HashMap::new();
    a.insert("application", SERVICE);
    a.insert("key", ACCOUNT);
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
    let s = String::from_utf8(bytes).map_err(|_| super::Error::NonUtf8)?;
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
