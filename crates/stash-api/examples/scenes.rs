//! `cargo run --example scenes -p stash-api`
//!
//! Pages a few scenes off the configured Stash server. Used to smoke-test
//! the `find_scenes` query against a real instance. Also honours the
//! standard proxy environment variables (`ALL_PROXY`, `HTTPS_PROXY`,
//! `HTTP_PROXY`, both cases), so this works unchanged against a Stash
//! server that's only reachable through a proxy.

use std::env;

use stash_api::SceneFilter;

#[tokio::main(flavor = "current_thread")]
async fn main() -> Result<(), Box<dyn std::error::Error>> {
    let _ = dotenvy::from_path("../../.env");
    let _ = dotenvy::dotenv();

    let url = env::var("STASH_URL").map_err(|_| "STASH_URL not set")?;
    let key = env::var("STASH_API_KEY").unwrap_or_default();

    let client = stash_api::Client::with_proxy(
        &url,
        &key,
        stash_player_core::resolve_proxy(None).as_deref(),
    )?;
    let page = client.find_scenes(&SceneFilter::new(), 1, 5).await?;
    println!("total scenes: {}", page.count);
    for s in &page.scenes {
        let dur = s
            .duration_seconds()
            .map(|d| format!(" ({:.0}s)", d))
            .unwrap_or_default();
        println!("  - [{}] {}{}", s.id, s.display_title(), dur);
    }
    Ok(())
}
