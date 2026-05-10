//! Materialize bundled SVG icons into the user's cache dir at startup so
//! they're discoverable via `gtk::IconTheme::add_search_path`. Lets us
//! ship custom icons without a GResource compile step.

use std::fs;

use relm4::gtk;

use gtk::gdk;

const O_COUNTER_SVG: &[u8] = include_bytes!("icons/o-counter-symbolic.svg");

pub(crate) fn install() {
    let Ok(root) = stash_player_core::cache::icon_root() else {
        tracing::warn!("no cache dir; bundled icons unavailable");
        return;
    };

    // Standard XDG icon-theme layout. GTK looks for icons under
    // `<search_path>/<theme>/<size>/<context>/<name>.svg`.
    let actions_dir = root.join("hicolor/scalable/actions");
    if let Err(e) = fs::create_dir_all(&actions_dir) {
        tracing::warn!("could not create icon dir {actions_dir:?}: {e}");
        return;
    }

    let target = actions_dir.join("o-counter-symbolic.svg");
    // Idempotent: only rewrite if the bytes differ, so we don't churn the
    // file's mtime on every launch.
    let needs_write = fs::read(&target)
        .map(|existing| existing != O_COUNTER_SVG)
        .unwrap_or(true);
    if needs_write
        && let Err(e) = fs::write(&target, O_COUNTER_SVG)
    {
        tracing::warn!("could not write {target:?}: {e}");
        return;
    }

    if let Some(display) = gdk::Display::default() {
        gtk::IconTheme::for_display(&display).add_search_path(&root);
    } else {
        tracing::warn!("no default GDK display; bundled icons not registered");
    }
}
