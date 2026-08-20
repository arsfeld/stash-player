//! Widget population for the scene page.
//!
//! Every `populate_*` helper here follows one convention: **clear, then
//! build**. Adding to a container without emptying it first is what made
//! the File section grow three rows per prev/next navigation.

use relm4::{adw, gtk};

use adw::prelude::*;

use stash_api::{PerformerRef, Scene, SceneFile};
use stash_player_proxy::MediaProxy;

use super::{ScenePageWidgets, State};

pub(super) fn populate_scene(widgets: &ScenePageWidgets, scene: &Scene) {
    widgets.window_title.set_title(&scene.display_title());
    widgets.window_title.set_subtitle(&subtitle_text(scene));

    populate_performers(&widgets.performers_box, &scene.performers);
    widgets
        .performers_section
        .set_visible(!scene.performers.is_empty());

    let details = scene.details.as_deref().unwrap_or("").trim();
    widgets.details_label.set_label(details);
    widgets.details_section.set_visible(!details.is_empty());

    populate_file_group(&widgets.file_section, scene.files.first());
}

/// Build the stream URL for the scene. GStreamer fetches this itself, so
/// it can carry neither our `ApiKey` header nor the upstream proxy
/// setting. Routing it through the loopback media proxy gives it both,
/// and keeps the API key out of GStreamer's logs.
pub(super) fn build_stream_url(proxy: &MediaProxy, scene: &Scene) -> Option<String> {
    let stream = scene.paths.stream.as_deref()?;
    match proxy.playback_url(stream) {
        Ok(url) => {
            tracing::info!("scene stream url: {url}");
            Some(url)
        }
        Err(e) => {
            tracing::warn!("could not build stream url: {e}");
            None
        }
    }
}

fn populate_performers(container: &gtk::Box, performers: &[PerformerRef]) {
    while let Some(child) = container.first_child() {
        container.remove(&child);
    }

    for performer in performers {
        let chip = gtk::Box::builder()
            .orientation(gtk::Orientation::Horizontal)
            .spacing(8)
            .css_classes(["performer-chip"])
            .build();

        let avatar = adw::Avatar::builder()
            .size(28)
            .text(&performer.name)
            .show_initials(true)
            .build();
        chip.append(&avatar);

        let label = gtk::Label::builder()
            .label(&performer.name)
            .ellipsize(gtk::pango::EllipsizeMode::End)
            .max_width_chars(24)
            .build();
        chip.append(&label);

        container.append(&chip);
    }
}

/// Rebuild the File section from scratch. Clearing first is the whole
/// point: this runs on every prev/next, and the previous implementation
/// appended to a persistent group, so the rows accumulated.
fn populate_file_group(container: &gtk::Box, file: Option<&SceneFile>) {
    while let Some(child) = container.first_child() {
        container.remove(&child);
    }

    let Some(file) = file else {
        container.set_visible(false);
        return;
    };

    let group = adw::PreferencesGroup::builder().title("File").build();
    let mut shown = false;

    if let (Some(w), Some(h)) = (file.width, file.height) {
        group.add(&info_row("Resolution", &format!("{w} × {h}")));
        shown = true;
    }
    if let Some(codec) = file.video_codec.as_deref()
        && !codec.is_empty()
    {
        group.add(&info_row("Codec", codec));
        shown = true;
    }
    if let Some(fps) = file.frame_rate {
        group.add(&info_row("Frame rate", &format!("{fps:.2} fps")));
        shown = true;
    }

    if shown {
        container.append(&group);
    }
    container.set_visible(shown);
}

fn info_row(title: &str, value: &str) -> adw::ActionRow {
    let row = adw::ActionRow::builder().title(title).build();
    let label = gtk::Label::builder()
        .label(value)
        .css_classes(["dim-label"])
        .build();
    row.add_suffix(&label);
    row
}

pub(super) fn page_title(state: &State) -> String {
    match state {
        State::Loading => "Loading…".into(),
        State::Loaded(s) => s.display_title(),
        State::NotFound => "Not found".into(),
        State::Failed(_) => "Scene".into(),
    }
}

fn subtitle_text(scene: &Scene) -> String {
    let mut parts = Vec::new();
    if let Some(s) = scene.studio.as_ref() {
        parts.push(s.name.clone());
    }
    if let Some(d) = scene.date.clone() {
        parts.push(d);
    }
    if let Some(secs) = scene.duration_seconds() {
        parts.push(format_duration(secs));
    }
    if let Some(file) = scene.files.first()
        && let Some(h) = file.height
    {
        parts.push(format_resolution(h));
    }
    parts.join(" · ")
}

fn format_duration(secs: f64) -> String {
    let total = secs.round() as u64;
    let h = total / 3600;
    let m = (total % 3600) / 60;
    let s = total % 60;
    if h > 0 {
        format!("{h}:{m:02}:{s:02}")
    } else {
        format!("{m}:{s:02}")
    }
}

fn format_resolution(height: i32) -> String {
    match height {
        h if h >= 4000 => "8K".into(),
        h if h >= 2000 => "4K".into(),
        h if h >= 1300 => "1440p".into(),
        h if h >= 950 => "1080p".into(),
        h if h >= 650 => "720p".into(),
        h if h >= 450 => "480p".into(),
        h => format!("{h}p"),
    }
}

pub(super) fn stash_scene_url(client: &stash_api::Client, scene_id: &str) -> String {
    let mut url = client.base_url().clone();
    url.set_path(&format!("/scenes/{scene_id}"));
    url.to_string()
}
