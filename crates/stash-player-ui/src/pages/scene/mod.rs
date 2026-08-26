//! Scene detail page. Inline player at the top (matches Stash's web UI),
//! followed by metadata, performers, and a file-info group.

mod metadata;

use metadata::{build_stream_url, page_title, populate_scene, stash_scene_url, update_o_widgets};

use relm4::prelude::*;
use relm4::{adw, gtk};

use adw::prelude::*;

use stash_api::{Scene, SceneFilter};

use crate::widgets::video_player::{
    SceneAction, SceneActionState, VideoPlayer, VideoPlayerInit, VideoPlayerMsg,
    VideoPlayerOutput,
};

/// Position within a filtered result set so the scene page can fetch
/// neighbors in the same order the user is browsing.
#[derive(Debug, Clone)]
pub(crate) struct SceneNavContext {
    pub filter: SceneFilter,
    /// 0-based index of the currently displayed scene.
    pub index: u32,
    /// Total scenes for `filter`. Negative means unknown.
    pub total: i64,
}

#[derive(Debug)]
pub(crate) struct SceneInit {
    pub client: stash_api::Client,
    pub scene_id: String,
    pub context: Option<SceneNavContext>,
    pub autoplay: bool,
    /// Initial player volume, restored from app config.
    pub volume: f64,
    /// Initial mute state, restored from app config.
    pub muted: bool,
}

pub(crate) struct ScenePage {
    client: stash_api::Client,
    scene_id: String,
    state: State,
    context: Option<SceneNavContext>,
    autoplay: bool,
    player: Controller<VideoPlayer>,
}

pub(super) enum State {
    Loading,
    Loaded(Box<Scene>),
    NotFound,
    Failed(String),
}

#[derive(Debug)]
pub(crate) enum SceneMsg {
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
    /// Bump the scene's O-counter by one.
    IncrementO,
    /// Zero the scene's O-counter.
    ResetO,
    /// Player reported a new volume/mute state — bubble up to the app so
    /// it can persist to config.
    VolumeChanged { volume: f64, muted: bool },
}

#[derive(Debug)]
pub(crate) enum SceneOutput {
    /// User flipped the autoplay toggle — persist this in app config.
    SetAutoplay(bool),
    /// User adjusted the video player volume or mute state — persist
    /// both so the next scene + next launch resume at the same level.
    SetVolume { volume: f64, muted: bool },
}

#[derive(Debug, Clone, Copy)]
pub(crate) enum NavDirection {
    Prev,
    Next,
}

#[derive(Debug)]
pub(crate) enum SceneCmd {
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
    /// Result of a `sceneIncrementO` / `sceneResetO` mutation. The new
    /// counter value the server settled on; we ignore late results that
    /// don't match the currently-loaded scene.
    OUpdated {
        scene_id: String,
        result: Result<i32, String>,
    },
}

#[derive(Debug, Clone, Copy)]
enum OMutation {
    Increment,
    Reset,
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
                                                set_sensitive: matches!(model.state, State::Loaded(_)),

                                                gtk::Button {
                                                    set_tooltip_text: Some("Bump O-counter"),
                                                    connect_clicked => SceneMsg::IncrementO,

                                                    #[wrap(Some)]
                                                    set_child = &gtk::Box {
                                                        set_orientation: gtk::Orientation::Horizontal,
                                                        set_spacing: 6,
                                                        set_valign: gtk::Align::Center,

                                                        gtk::Image {
                                                            set_icon_name: Some("o-counter-symbolic"),
                                                            set_pixel_size: 14,
                                                        },

                                                        #[name = "o_count_label"]
                                                        gtk::Label {
                                                            add_css_class: "o-counter-pill",
                                                        },
                                                    },
                                                },

                                                #[name = "o_reset_btn"]
                                                gtk::Button {
                                                    set_icon_name: "edit-clear-symbolic",
                                                    set_tooltip_text: Some("Reset O-counter to 0"),
                                                    connect_clicked => SceneMsg::ResetO,
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

                                    // Rebuilt wholesale by
                                    // `populate_file_group` so navigating
                                    // between scenes replaces the rows
                                    // instead of appending to them.
                                    #[name = "file_section"]
                                    gtk::Box {
                                        set_orientation: gtk::Orientation::Vertical,
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
                volume: init.volume,
                muted: init.muted,
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
                VideoPlayerOutput::VolumeChanged { volume, muted } => {
                    SceneMsg::VolumeChanged { volume, muted }
                }
                VideoPlayerOutput::SceneAction(action) => match action {
                    SceneAction::Prev => SceneMsg::Prev,
                    SceneAction::Next => SceneMsg::Next,
                    SceneAction::IncrementO => SceneMsg::IncrementO,
                    SceneAction::ResetO => SceneMsg::ResetO,
                },
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
            SceneMsg::IncrementO => self.spawn_o_mutation(&sender, OMutation::Increment),
            SceneMsg::ResetO => self.spawn_o_mutation(&sender, OMutation::Reset),
            SceneMsg::VolumeChanged { volume, muted } => {
                let _ = sender.output(SceneOutput::SetVolume { volume, muted });
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
        self.push_scene_actions();
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
                        resume_secs: scene.effective_resume_secs(),
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
                        resume_secs: scene.effective_resume_secs(),
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
            SceneCmd::OUpdated { scene_id, result } => match result {
                Ok(new_count) => {
                    // Drop late results that don't match the currently
                    // loaded scene — the user may have hit prev/next
                    // before the round-trip landed.
                    if scene_id == self.scene_id
                        && let State::Loaded(scene) = &mut self.state
                    {
                        scene.o_counter = Some(new_count);
                        update_o_widgets(widgets, new_count);
                    }
                }
                Err(e) => tracing::warn!("o-counter update failed for scene {scene_id}: {e}"),
            },
        }
        self.push_scene_actions();
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

    /// Push the OSD's scene-level control state to the player. Called
    /// after anything that changes what those controls should show.
    fn push_scene_actions(&self) {
        // `None` here means "no scene is loaded right now" (e.g.
        // mid-navigation) — a different absence than `rating100`'s
        // `None`, which means "loaded, but unrated".
        let o_count = match &self.state {
            State::Loaded(scene) => Some(scene.o_counter.unwrap_or(0)),
            _ => None,
        };
        let rating100 = match &self.state {
            State::Loaded(scene) => scene.rating100,
            _ => None,
        };
        self.player
            .emit(VideoPlayerMsg::SetSceneActions(SceneActionState {
                can_prev: self.can_go_prev(),
                can_next: self.can_go_next(),
                o_count,
                rating100,
            }));
    }

    fn spawn_o_mutation(&self, sender: &ComponentSender<Self>, mutation: OMutation) {
        if !matches!(self.state, State::Loaded(_)) {
            return;
        }
        let client = self.client.clone();
        let scene_id = self.scene_id.clone();
        sender.oneshot_command(async move {
            let result = match mutation {
                OMutation::Increment => client.increment_o(&scene_id).await,
                OMutation::Reset => client.reset_o(&scene_id).await,
            };
            SceneCmd::OUpdated {
                scene_id,
                result: result.map_err(|e| e.to_string()),
            }
        });
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

async fn load_one(client: &stash_api::Client, id: &str) -> stash_api::Result<Option<Scene>> {
    client.find_scene(id).await
}
