//! `cargo run --example version -p stash-api`
//!
//! Reads STASH_URL + STASH_API_KEY (also from a `.env` at the workspace root)
//! and prints the server's version string. Smallest possible end-to-end test.

use std::env;

#[tokio::main(flavor = "current_thread")]
async fn main() -> Result<(), Box<dyn std::error::Error>> {
    let _ = dotenvy::from_path("../../.env");
    let _ = dotenvy::dotenv();

    let url = env::var("STASH_URL").map_err(|_| "STASH_URL not set")?;
    let key = env::var("STASH_API_KEY").unwrap_or_default();

    let client = stash_api::Client::new(&url, &key)?;
    let version = client.version().await?;
    println!("{url} → Stash {version}");
    Ok(())
}
