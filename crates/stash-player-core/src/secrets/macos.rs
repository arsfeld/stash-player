use security_framework::passwords::{
    delete_generic_password, get_generic_password, set_generic_password,
};

use super::{ACCOUNT, Error, Result, SERVICE};

const ERR_SEC_ITEM_NOT_FOUND: i32 = -25300;

fn map_err(e: security_framework::base::Error) -> Error {
    Error::Keychain(e.to_string())
}

pub async fn load_api_key() -> Result<Option<String>> {
    let bytes = tokio::task::spawn_blocking(|| get_generic_password(SERVICE, ACCOUNT)).await?;
    match bytes {
        Ok(bytes) => {
            let s = String::from_utf8(bytes).map_err(|_| Error::NonUtf8)?;
            Ok(Some(s))
        }
        Err(e) if e.code() == ERR_SEC_ITEM_NOT_FOUND => Ok(None),
        Err(e) => Err(map_err(e)),
    }
}

pub async fn store_api_key(key: &str) -> Result<()> {
    let bytes = key.as_bytes().to_vec();
    tokio::task::spawn_blocking(move || set_generic_password(SERVICE, ACCOUNT, &bytes))
        .await?
        .map_err(map_err)
}

pub async fn delete_api_key() -> Result<()> {
    let res = tokio::task::spawn_blocking(|| delete_generic_password(SERVICE, ACCOUNT)).await?;
    match res {
        Ok(()) => Ok(()),
        Err(e) if e.code() == ERR_SEC_ITEM_NOT_FOUND => Ok(()),
        Err(e) => Err(map_err(e)),
    }
}
