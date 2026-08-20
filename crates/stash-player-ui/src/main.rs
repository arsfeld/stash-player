use std::env;

use relm4::gtk::gdk;
use relm4::RelmApp;

use stash_player_core::Config;

mod app;
mod icons;
mod pages;
mod widgets;

use app::{AppInit, AppModel};

const APP_CSS: &str = include_str!("styles.css");

fn main() {
    // `.env` is dev-only convenience. The keyring is the real source of truth
    // for the API key; this just lets us iterate without re-typing on every run.
    let _ = dotenvy::dotenv();

    tracing_subscriber::fmt()
        .with_env_filter(
            tracing_subscriber::EnvFilter::try_from_default_env()
                .unwrap_or_else(|_| "info,stash_player_ui=debug".parse().unwrap()),
        )
        .init();

    let mut config = Config::load().unwrap_or_else(|e| {
        tracing::warn!("could not load config: {e}; using defaults");
        Config::default()
    });

    if let Ok(url) = env::var("STASH_URL") {
        tracing::info!("using STASH_URL from environment");
        config.stash_url = url;
    }
    let api_key_override = env::var("STASH_API_KEY").ok().filter(|s| !s.is_empty());
    if api_key_override.is_some() {
        tracing::info!("using STASH_API_KEY from environment");
    }

    // Surface where the proxy came from. "Why is my traffic being
    // proxied" should be answerable from the log alone.
    if config.proxy_url.as_deref().is_some_and(|p| !p.trim().is_empty()) {
        tracing::info!("using proxy from config");
    } else if let Some(proxy) = stash_player_core::resolve_proxy(None) {
        tracing::info!("using proxy {proxy} from environment");
    }

    gst::init().expect("failed to initialize GStreamer");

    let app = RelmApp::new("dev.arsfeld.stash-player");
    relm4::gtk::Window::set_default_icon_name("dev.arsfeld.stash-player");
    install_css();
    icons::install();
    app.run::<AppModel>(AppInit {
        config,
        api_key_override,
    });
}

fn install_css() {
    // The CSS provider has to be installed against a display; do it on the
    // default one (created lazily by GTK once we touch it).
    let provider = relm4::gtk::CssProvider::new();
    provider.load_from_string(APP_CSS);
    if let Some(display) = gdk::Display::default() {
        relm4::gtk::style_context_add_provider_for_display(
            &display,
            &provider,
            relm4::gtk::STYLE_PROVIDER_PRIORITY_APPLICATION,
        );
    } else {
        tracing::warn!("no default GDK display; app CSS not installed");
    }
}
