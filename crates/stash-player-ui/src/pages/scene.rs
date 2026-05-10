//! Scene detail page. Inline player at the top (matches Stash's web UI),
//! followed by metadata, performers, and a file-info group.

use relm4::prelude::*;
use relm4::{adw, gtk};

use adw::prelude::*;

use stash_api::{PerformerRef, Scene, SceneFile, SceneFilter};

use crate::widgets::video_player::{
    VideoPlayer, VideoPlayerInit, VideoPlayerMsg, VideoPlayerOutput,
};

/// Position within a filtered result set so the scene page can fetch
/// neighbors in the same order the user is browsing.
#[derive(Debug, Clone)]
pub struct SceneNavContext {
    pub filter: SceneFilter,
    /// 0-based index of the currently displayed scene.
    pub index: u32,
    /// Total scenes for `filter`. Negative means unknown.
    pub total: i64,
}

#[derive(Debug)]
pub struct SceneInit {
    pub client: stash_api::Client,
    pub scene_id: String,
    pub context: Option<SceneNavContext>,
    pub autoplay: bool,
}

pub struct ScenePage {
    client: stash_api::Client,
    scene_id: String,
    state: State,
    context: Option<SceneNavContext>,
    autoplay: bool,
    player: Controller<VideoPlayer>,
}

enum State {
    Loading,
    Loaded(Box<Scene>),
    NotFound,
    Failed(String),
}

#[derive(Debug)]
pub enum SceneMsg {
    OpenInBrowser,
    Prev,
    Next,
    AutoplayToggled(bool),
    /// Player wants us to write back resume + play-duration delta to
    /// Stash. The scene id this maps to is whichever scene is currently
    /// loaded — captured at dispatch time so a checkpoint that arrives
    /// after a Prev/Next swap still records against the correct scene.
    SaveActivity {
        resume_secs: f64,
        play_duration_secs: f64,
    },
    /// Fade the floating header bar in/out alongside the player's OSD.
    SetHeaderRevealed(bool),
}

#[derive(Debug)]
pub enum SceneOutput {
    /// User flipped the autoplay toggle — persist this in app config.
    SetAutoplay(bool),
}

#[derive(Debug, Clone, Copy)]
pub enum NavDirection {
    Prev,
    Next,
}

#[derive(Debug)]
pub enum SceneCmd {
    Loaded(Box<Result<Option<Scene>, String>>),
    Neighbor {
        direction: NavDirection,
        target_index: u32,
        result: Box<Result<Option<Scene>, String>>,
    },
    /// Result of a `sceneSaveActivity` mutation. We only log on this —
    /// activity sync is fire-and-forget, the user shouldn't see a
    /// transient network failure as an error.
    ActivitySaved {
        scene_id: String,
        result: Result<bool, String>,
    },
}

#[relm4::component(pub)]
impl Component for ScenePage {
    type Init = SceneInit;
    type Input = SceneMsg;
    type Output = SceneOutput;
    type CommandOutput = SceneCmd;

    view! {
        adw::NavigationPage {
            #[watch]
            set_title: &page_title(&model.state),

            #[name = "toolbar_view"]
            #[wrap(Some)]
            set_child = &adw::ToolbarView {
                // Float the header bar over the video so the player is
                // flush against the top of the page — no chrome strip
                // above it, no border around it.
                set_extend_content_to_top_edge: true,
                set_top_bar_style: adw::ToolbarStyle::Flat,

                add_top_bar = &adw::HeaderBar {
                    add_css_class: "scene-headerbar",
                },

                #[wrap(Some)]
                set_content = &gtk::Stack {
                    set_transition_type: gtk::StackTransitionType::Crossfade,

                    add_named[Some("loading")] = &adw::StatusPage {
                        set_title: "Loading…",
                        #[wrap(Some)]
                        set_child = &gtk::Spinner {
                            set_spinning: true,
                            set_width_request: 32,
                            set_height_request: 32,
                        },
                    },

                    add_named[Some("missing")] = &adw::StatusPage {
                        set_icon_name: Some("action-unavailable-symbolic"),
                        set_title: "Scene not found",
                        set_description: Some("The server returned no scene with that id."),
                    },

                    add_named[Some("error")] = &adw::StatusPage {
                        set_icon_name: Some("dialog-error-symbolic"),
                        set_title: "Couldn't load scene",
                        #[watch]
                        set_description: model.failure_message(),
                    },

                    add_named[Some("loaded")] = &gtk::ScrolledWindow {
                        set_hscrollbar_policy: gtk::PolicyType::Never,

                        gtk::Box {
                            set_orientation: gtk::Orientation::Vertical,
                            set_spacing: 0,

                            // Full-width player. Sits outside the metadata
                            // clamp on purpose so it spans the window like
                            // Stash's web UI. The actual player widget is a
                            // `VideoPlayer` controller installed as the
                            // overlay's main child after `view_output!()`,
                            // because the relm4 view macro can't easily
                            // splice in a controller's root widget where
                            // `gtk::Overlay::set_child` expects an `Option`.
                            #[name = "video_overlay"]
                            gtk::Overlay {
                                set_hexpand: true,

                                add_overlay = &gtk::Box {
                                    set_halign: gtk::Align::End,
                                    set_valign: gtk::Align::Start,
                                    set_margin_top: 12,
                                    set_margin_end: 12,

                                    #[name = "rating_badge"]
                                    gtk::Label {
                                        add_css_class: "rating-badge",
                                        set_visible: false,
                                    },
                                },
                            },

                            adw::Clamp {
                                set_maximum_size: 960,
                                set_tightening_threshold: 720,
                                set_margin_top: 24,
                                set_margin_bottom: 32,
                                set_margin_start: 18,
                                set_margin_end: 18,

                                gtk::Box {
                                    set_orientation: gtk::Orientation::Vertical,
                                    set_spacing: 24,

                                    gtk::Box {
                                        set_orientation: gtk::Orientation::Horizontal,
                                        set_spacing: 12,

                                        gtk::Box {
                                            set_orientation: gtk::Orientation::Vertical,
                                            set_spacing: 4,
                                            set_hexpand: true,

                                            #[name = "title_label"]
                                            gtk::Label {
                                                add_css_class: "title-1",
                                                set_xalign: 0.0,
                                                set_wrap: true,
                                                set_wrap_mode: gtk::pango::WrapMode::WordChar,
                                            },

                                            #[name = "subtitle_label"]
                                            gtk::Label {
                                                add_css_class: "dim-label",
                                                set_xalign: 0.0,
                                                set_wrap: true,
                                                set_wrap_mode: gtk::pango::WrapMode::WordChar,
                                            },
                                        },

                                        // Right-side action cluster. Wrapped
                                        // in a single horizontal box with
                                        // `valign: Center` so the autoplay
                                        // switch + skip buttons share a
                                        // common centerline regardless of
                                        // how many lines the title wraps to.
                                        gtk::Box {
                                            set_spacing: 12,
                                            set_valign: gtk::Align::Center,

                                            gtk::Label {
                                                set_label: "Autoplay",
                                                add_css_class: "dim-label",
                                            },

                                            gtk::Switch {
                                                set_valign: gtk::Align::Center,
                                                set_tooltip_text: Some(
                                                    "Start playing scenes automatically",
                                                ),
                                                #[watch]
                                                set_active: model.autoplay,
                                                connect_active_notify[sender] => move |s| {
                                                    sender.input(SceneMsg::AutoplayToggled(s.is_active()));
                                                },
                                            },

                                            gtk::Box {
                                                add_css_class: "linked",
                                                set_valign: gtk::Align::Center,
                                                set_margin_start: 4,
                                                #[watch]
                                                set_visible: model.context.is_some(),

                                                gtk::Button {
                                                    set_icon_name: "media-skip-backward-symbolic",
                                                    set_tooltip_text: Some("Previous scene"),
                                                    #[watch]
                                                    set_sensitive: model.can_go_prev(),
                                                    connect_clicked => SceneMsg::Prev,
                                                },

                                                gtk::Button {
                                                    set_icon_name: "media-skip-forward-symbolic",
                                                    set_tooltip_text: Some("Next scene"),
                                                    #[watch]
                                                    set_sensitive: model.can_go_next(),
                                                    connect_clicked => SceneMsg::Next,
                                                },
                                            },
                                        },
                                    },

                                    gtk::Box {
                                        set_halign: gtk::Align::End,

                                        gtk::Button {
                                            set_icon_name: "external-link-symbolic",
                                            add_css_class: "flat",
                                            add_css_class: "circular",
                                            set_tooltip_text: Some("Open in Stash"),
                                            set_valign: gtk::Align::Center,
                                            #[watch]
                                            set_sensitive: matches!(model.state, State::Loaded(_)),
                                            connect_clicked => SceneMsg::OpenInBrowser,
                                        },
                                    },

                                    #[name = "performers_section"]
                                    gtk::Box {
                                        set_orientation: gtk::Orientation::Vertical,
                                        set_spacing: 10,
                                        set_visible: false,

                                        gtk::Label {
                                            set_label: "Performers",
                                            set_xalign: 0.0,
                                            add_css_class: "heading",
                                        },

                                        gtk::ScrolledWindow {
                                            set_vscrollbar_policy: gtk::PolicyType::Never,
                                            set_propagate_natural_height: true,

                                            #[name = "performers_box"]
                                            gtk::Box {
                                                set_orientation: gtk::Orientation::Horizontal,
                                                set_spacing: 8,
                                            },
                                        },
                                    },

                                    #[name = "details_section"]
                                    gtk::Box {
                                        set_orientation: gtk::Orientation::Vertical,
                                        set_spacing: 8,
                                        set_visible: false,

                                        gtk::Label {
                                            set_label: "About",
                                            set_xalign: 0.0,
                                            add_css_class: "heading",
                                        },

                                        #[name = "details_label"]
                                        gtk::Label {
                                            set_xalign: 0.0,
                                            set_wrap: true,
                                            set_wrap_mode: gtk::pango::WrapMode::WordChar,
                                            set_selectable: true,
                                        },
                                    },

                                    #[name = "file_group"]
                                    adw::PreferencesGroup {
                                        set_title: "File",
                                        set_visible: false,
                                    },
                                },
                            },
                        },
                    },

                    #[watch]
                    set_visible_child_name: model.stack_name(),
                },
            },
        }
    }

    fn init(
        init: Self::Init,
        root: Self::Root,
        sender: ComponentSender<Self>,
    ) -> ComponentParts<Self> {
        let player = VideoPlayer::builder()
            .launch(VideoPlayerInit {
                url: None,
                autoplay: init.autoplay,
                resume_secs: None,
            })
            .forward(sender.input_sender(), |out| match out {
                VideoPlayerOutput::ActivityCheckpoint {
                    resume_secs,
                    play_duration_secs,
                } => SceneMsg::SaveActivity {
                    resume_secs,
                    play_duration_secs,
                },
                VideoPlayerOutput::ControlsRevealedChanged(on) => {
                    SceneMsg::SetHeaderRevealed(on)
                }
            });

        let model = ScenePage {
            client: init.client,
            scene_id: init.scene_id,
            state: State::Loading,
            context: init.context,
            autoplay: init.autoplay,
            player,
        };

        let widgets = view_output!();

        widgets
            .video_overlay
            .set_child(Some(model.player.widget()));

        let client = model.client.clone();
        let id = model.scene_id.clone();
        sender.oneshot_command(async move {
            SceneCmd::Loaded(Box::new(
                load_one(&client, &id).await.map_err(|e| e.to_string()),
            ))
        });

        ComponentParts { model, widgets }
    }

    fn update_with_view(
        &mut self,
        widgets: &mut Self::Widgets,
        msg: SceneMsg,
        sender: ComponentSender<Self>,
        _root: &Self::Root,
    ) {
        match msg {
            SceneMsg::OpenInBrowser => {
                if matches!(self.state, State::Loaded(_)) {
                    let url = stash_scene_url(&self.client, &self.scene_id);
                    let _ = gtk::gio::AppInfo::launch_default_for_uri(
                        &url,
                        None::<&gtk::gio::AppLaunchContext>,
                    );
                }
            }
            SceneMsg::Prev => self.start_navigate(widgets, &sender, NavDirection::Prev),
            SceneMsg::Next => self.start_navigate(widgets, &sender, NavDirection::Next),
            SceneMsg::AutoplayToggled(on) => {
                // Guard against the toggled signal that fires when the
                // #[watch] binding programmatically syncs `set_active` —
                // otherwise toggling once round-trips into a save loop.
                if self.autoplay != on {
                    self.autoplay = on;
                    self.player.emit(VideoPlayerMsg::SetAutoplay(on));
                    let _ = sender.output(SceneOutput::SetAutoplay(on));
                }
            }
            SceneMsg::SetHeaderRevealed(on) => {
                widgets.toolbar_view.set_reveal_top_bars(on);
            }
            SceneMsg::SaveActivity {
                resume_secs,
                play_duration_secs,
            } => {
                // Capture the scene id at dispatch time. If the user
                // races a Prev/Next during the round-trip, we still
                // attribute the save to the scene the player was on
                // when it emitted the checkpoint — the player flushes
                // before swapping URLs, so this is the same scene.
                let client = self.client.clone();
                let scene_id = self.scene_id.clone();
                // Stash treats a missing playDuration as "leave it",
                // which is also how we want a zero delta handled. Same
                // for a 0 resume_secs immediately after a fresh load.
                let resume_arg = if resume_secs > 0.0 {
                    Some(resume_secs)
                } else {
                    None
                };
                let duration_arg = if play_duration_secs > 0.0 {
                    Some(play_duration_secs)
                } else {
                    None
                };
                if resume_arg.is_none() && duration_arg.is_none() {
                    // Nothing to write; skip the round-trip.
                    return;
                }
                sender.oneshot_command(async move {
                    let result = client
                        .save_scene_activity(&scene_id, resume_arg, duration_arg)
                        .await
                        .map_err(|e| e.to_string());
                    SceneCmd::ActivitySaved {
                        scene_id,
                        result,
                    }
                });
            }
        }
        self.update_view(widgets, sender);
    }

    fn update_cmd_with_view(
        &mut self,
        widgets: &mut Self::Widgets,
        msg: SceneCmd,
        sender: ComponentSender<Self>,
        _root: &Self::Root,
    ) {
        match msg {
            SceneCmd::Loaded(boxed) => match *boxed {
                Ok(Some(scene)) => {
                    self.scene_id = scene.id.clone();
                    populate_scene(widgets, &scene);
                    self.player.emit(VideoPlayerMsg::SetUrl {
                        url: build_stream_url(&self.client, &scene),
                        resume_secs: scene.resume_time,
                    });
                    self.state = State::Loaded(Box::new(scene));
                }
                Ok(None) => {
                    self.state = State::NotFound;
                }
                Err(e) => {
                    self.state = State::Failed(e);
                }
            },
            SceneCmd::Neighbor { direction, target_index, result } => match *result {
                Ok(Some(scene)) => {
                    self.scene_id = scene.id.clone();
                    if let Some(ctx) = self.context.as_mut() {
                        ctx.index = target_index;
                    }
                    populate_scene(widgets, &scene);
                    self.player.emit(VideoPlayerMsg::SetUrl {
                        url: build_stream_url(&self.client, &scene),
                        resume_secs: scene.resume_time,
                    });
                    self.state = State::Loaded(Box::new(scene));
                }
                Ok(None) => {
                    tracing::debug!(
                        "no scene at index {target_index} for {direction:?} navigation"
                    );
                    self.state = State::NotFound;
                }
                Err(e) => {
                    tracing::warn!("scene navigation failed: {e}");
                    self.state = State::Failed(e);
                }
            },
            SceneCmd::ActivitySaved { scene_id, result } => match result {
                Ok(_) => tracing::debug!("activity saved for scene {scene_id}"),
                Err(e) => tracing::warn!("activity save failed for scene {scene_id}: {e}"),
            },
        }
        self.update_view(widgets, sender);
    }
}

impl ScenePage {
    fn stack_name(&self) -> &'static str {
        match &self.state {
            State::Loading => "loading",
            State::Loaded(_) => "loaded",
            State::NotFound => "missing",
            State::Failed(_) => "error",
        }
    }

    fn failure_message(&self) -> Option<&str> {
        match &self.state {
            State::Failed(msg) => Some(msg.as_str()),
            _ => None,
        }
    }

    fn can_go_prev(&self) -> bool {
        matches!(&self.state, State::Loaded(_) | State::NotFound | State::Failed(_))
            && self
                .context
                .as_ref()
                .map(|c| c.index > 0)
                .unwrap_or(false)
    }

    fn can_go_next(&self) -> bool {
        matches!(&self.state, State::Loaded(_) | State::NotFound | State::Failed(_))
            && self
                .context
                .as_ref()
                .map(|c| c.total < 0 || (c.index as i64) + 1 < c.total)
                .unwrap_or(false)
    }

    fn start_navigate(
        &mut self,
        _widgets: &<Self as Component>::Widgets,
        sender: &ComponentSender<Self>,
        direction: NavDirection,
    ) {
        let Some(ctx) = self.context.as_ref() else {
            return;
        };
        let target_index = match direction {
            NavDirection::Prev => {
                if ctx.index == 0 {
                    return;
                }
                ctx.index - 1
            }
            NavDirection::Next => {
                if ctx.total >= 0 && (ctx.index as i64) + 1 >= ctx.total {
                    return;
                }
                ctx.index + 1
            }
        };

        // Stop the currently playing media before swapping in the new scene
        // so audio doesn't keep playing while the loading spinner is up.
        self.player.emit(VideoPlayerMsg::SetUrl {
            url: None,
            resume_secs: None,
        });

        self.state = State::Loading;

        let client = self.client.clone();
        let filter = ctx.filter.clone();
        sender.oneshot_command(async move {
            // Stash pages are 1-indexed; per_page=1 means we read exactly the
            // scene at `target_index` from the same filter ordering the user
            // is browsing (including a stable `random_<seed>` for shuffle).
            let page = target_index + 1;
            let result = client
                .find_scenes(&filter, page, 1)
                .await
                .map(|p| p.scenes.into_iter().next())
                .map_err(|e| e.to_string());
            SceneCmd::Neighbor {
                direction,
                target_index,
                result: Box::new(result),
            }
        });
    }
}

fn populate_scene(widgets: &<ScenePage as Component>::Widgets, scene: &Scene) {
    widgets.title_label.set_label(&scene.display_title());

    let subtitle = subtitle_text(scene);
    widgets.subtitle_label.set_visible(!subtitle.is_empty());
    widgets.subtitle_label.set_label(&subtitle);

    if let Some(rating) = scene.rating100.filter(|r| *r > 0) {
        let stars = rating as f32 / 10.0;
        widgets.rating_badge.set_label(&format!("★ {stars:.1}"));
        widgets.rating_badge.set_visible(true);
    } else {
        widgets.rating_badge.set_visible(false);
    }

    populate_performers(&widgets.performers_box, &scene.performers);
    widgets
        .performers_section
        .set_visible(!scene.performers.is_empty());

    let details = scene.details.as_deref().unwrap_or("").trim();
    widgets.details_label.set_label(details);
    widgets.details_section.set_visible(!details.is_empty());

    populate_file_group(&widgets.file_group, scene.files.first());
}

/// Build the authenticated stream URL for the scene. GTK's media stack
/// can't carry our `ApiKey` request header, so we lean on Stash's
/// query-param auth via `authenticated_url`.
fn build_stream_url(client: &stash_api::Client, scene: &Scene) -> Option<String> {
    let stream = scene.paths.stream.as_deref()?;
    match client.authenticated_url(stream) {
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

fn populate_file_group(group: &adw::PreferencesGroup, file: Option<&SceneFile>) {
    let Some(file) = file else {
        group.set_visible(false);
        return;
    };

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

    group.set_visible(shown);
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

async fn load_one(client: &stash_api::Client, id: &str) -> stash_api::Result<Option<Scene>> {
    client.find_scene(id).await
}

fn page_title(state: &State) -> String {
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

fn stash_scene_url(client: &stash_api::Client, scene_id: &str) -> String {
    let mut url = client.base_url().clone();
    url.set_path(&format!("/scenes/{scene_id}"));
    url.to_string()
}
