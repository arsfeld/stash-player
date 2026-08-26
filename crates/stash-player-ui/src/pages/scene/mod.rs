//! Scene detail page. Inline player at the top (matches Stash's web UI),
//! followed by metadata, performers, and a file-info group.

mod metadata;

use metadata::{build_stream_url, page_title, populate_scene, stash_scene_url};

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
    /// Whether the metadata drawer is open. Mirrored onto the split view
    /// and the header toggle.
    drawer_shown: bool,
    /// True between starting a prev/next fetch and its result landing.
    /// Keeps the stack on the player instead of crossfading it out.
    navigating: bool,
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
    /// Show or hide the metadata drawer. Kept in sync in both
    /// directions — the split view can close itself on an outside click.
    SetDrawerShown(bool),
    /// The player entered (true) or left (false) fullscreen.
    FullscreenChanged(bool),
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

                    #[wrap(Some)]
                    #[name = "window_title"]
                    set_title_widget = &adw::WindowTitle {
                        set_title: "",
                        set_subtitle: "",
                    },

                    #[name = "drawer_button"]
                    pack_end = &gtk::ToggleButton {
                        // dialog-information-symbolic ships in every
                        // Adwaita version we support. If the GNOME 47+
                        // "info-outline-symbolic" is present it reads
                        // better in a header bar — check with
                        // `gtk4-icon-browser` before swapping.
                        set_icon_name: "dialog-information-symbolic",
                        set_tooltip_text: Some("Scene details"),
                        connect_toggled[sender] => move |b| {
                            sender.input(SceneMsg::SetDrawerShown(b.is_active()));
                        },
                    },

                    pack_end = &gtk::MenuButton {
                        set_icon_name: "view-more-symbolic",
                        set_tooltip_text: Some("More"),

                        #[wrap(Some)]
                        set_popover = &gtk::Popover {
                            #[wrap(Some)]
                            set_child = &gtk::Box {
                                set_orientation: gtk::Orientation::Vertical,
                                set_spacing: 6,
                                set_margin_start: 6,
                                set_margin_end: 6,
                                set_margin_top: 6,
                                set_margin_bottom: 6,

                                gtk::Box {
                                    set_orientation: gtk::Orientation::Horizontal,
                                    set_spacing: 12,

                                    gtk::Label {
                                        set_label: "Autoplay",
                                        set_hexpand: true,
                                        set_xalign: 0.0,
                                    },

                                    gtk::Switch {
                                        set_valign: gtk::Align::Center,
                                        #[watch]
                                        set_active: model.autoplay,
                                        connect_active_notify[sender] => move |s| {
                                            sender.input(SceneMsg::AutoplayToggled(s.is_active()));
                                        },
                                    },
                                },

                                gtk::Button {
                                    add_css_class: "flat",
                                    set_label: "Open in Stash",
                                    #[watch]
                                    set_sensitive: matches!(model.state, State::Loaded(_)),
                                    connect_clicked => SceneMsg::OpenInBrowser,
                                },
                            },
                        },
                    },
                },

                #[wrap(Some)]
                #[name = "split_view"]
                set_content = &adw::OverlaySplitView {
                    // Pinned collapsed on purpose, never bound to a
                    // breakpoint: an overlaying sidebar can't reallocate
                    // the player, which is what kept the video area
                    // shrinking on every scene change.
                    set_collapsed: true,
                    set_sidebar_position: gtk::PackType::End,
                    set_max_sidebar_width: 360.0,
                    set_show_sidebar: false,
                    // gir renames boolean getters, so the accessor for
                    // the `show-sidebar` property is `shows_sidebar()` —
                    // if the compiler disagrees it will be
                    // `is_show_sidebar()`. Take whichever it accepts;
                    // both read the same property.
                    connect_show_sidebar_notify[sender] => move |v| {
                        sender.input(SceneMsg::SetDrawerShown(v.shows_sidebar()));
                    },

                    #[wrap(Some)]
                    set_sidebar = &gtk::ScrolledWindow {
                        set_hscrollbar_policy: gtk::PolicyType::Never,

                        gtk::Box {
                            set_orientation: gtk::Orientation::Vertical,
                            set_spacing: 24,
                            set_margin_top: 24,
                            set_margin_bottom: 24,
                            set_margin_start: 18,
                            set_margin_end: 18,

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

                                #[name = "performers_box"]
                                gtk::Box {
                                    set_orientation: gtk::Orientation::Vertical,
                                    set_spacing: 8,
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

                            // Rebuilt wholesale by `populate_file_group` so
                            // navigating between scenes replaces the rows
                            // instead of appending to them.
                            #[name = "file_section"]
                            gtk::Box {
                                set_orientation: gtk::Orientation::Vertical,
                                set_visible: false,
                            },
                        },
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

                        // The player goes straight in — no ScrolledWindow,
                        // no Overlay, nothing that would size it from its
                        // content instead of from the window.
                        #[name = "player_slot"]
                        add_named[Some("loaded")] = &gtk::Box {
                            set_orientation: gtk::Orientation::Vertical,
                        },

                        #[watch]
                        set_visible_child_name: model.stack_name(),
                    },
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
                VideoPlayerOutput::FullscreenChanged(on) => SceneMsg::FullscreenChanged(on),
            });

        let model = ScenePage {
            client: init.client,
            scene_id: init.scene_id,
            state: State::Loading,
            context: init.context,
            autoplay: init.autoplay,
            player,
            drawer_shown: false,
            navigating: false,
        };

        let widgets = view_output!();

        widgets.player_slot.append(model.player.widget());

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
                widgets
                    .toolbar_view
                    .set_reveal_top_bars(on || self.drawer_shown);
            }
            SceneMsg::IncrementO => self.spawn_o_mutation(&sender, OMutation::Increment),
            SceneMsg::ResetO => self.spawn_o_mutation(&sender, OMutation::Reset),
            SceneMsg::VolumeChanged { volume, muted } => {
                let _ = sender.output(SceneOutput::SetVolume { volume, muted });
            }
            SceneMsg::SetDrawerShown(shown) => {
                // Guard the round trip: the split view and the toggle
                // each notify us when we set the other.
                if self.drawer_shown != shown {
                    self.drawer_shown = shown;
                }
                if widgets.split_view.shows_sidebar() != shown {
                    widgets.split_view.set_show_sidebar(shown);
                }
                if widgets.drawer_button.is_active() != shown {
                    widgets.drawer_button.set_active(shown);
                }
                if shown {
                    // Keep the header up while the drawer is open, or the
                    // toggle that closes it fades away.
                    widgets.toolbar_view.set_reveal_top_bars(true);
                }
            }
            SceneMsg::FullscreenChanged(on) => {
                if on {
                    sender.input(SceneMsg::SetDrawerShown(false));
                }
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
                        show_loading: false,
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
            SceneCmd::Neighbor {
                direction,
                target_index,
                result,
            } => {
                // Cleared before applying, so a failed navigation still
                // reaches the error or missing page.
                self.navigating = false;
                match *result {
                    Ok(Some(scene)) => {
                        self.scene_id = scene.id.clone();
                        if let Some(ctx) = self.context.as_mut() {
                            ctx.index = target_index;
                        }
                        populate_scene(widgets, &scene);
                        self.player.emit(VideoPlayerMsg::SetUrl {
                            url: build_stream_url(&self.client, &scene),
                            resume_secs: scene.effective_resume_secs(),
                            show_loading: false,
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
                }
            }
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
        if self.navigating {
            // Keep the player on screen and let it show its own spinner.
            return "loaded";
        }
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
        !self.navigating
            && matches!(&self.state, State::Loaded(_) | State::NotFound | State::Failed(_))
            && self.context.as_ref().map(|c| c.index > 0).unwrap_or(false)
    }

    fn can_go_next(&self) -> bool {
        !self.navigating
            && matches!(&self.state, State::Loaded(_) | State::NotFound | State::Failed(_))
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
        if self.navigating {
            return;
        }
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

        // Stop the outgoing stream (this also flushes its activity) but
        // keep the player mapped and show its own spinner. Swapping the
        // whole stack out would remap the paintable widget on every
        // navigation.
        self.player.emit(VideoPlayerMsg::SetUrl {
            url: None,
            resume_secs: None,
            show_loading: true,
        });

        // Only hold the player on screen if there's one to hold. From
        // any other state there's nothing loaded, so fall back to the
        // full-page spinner.
        if matches!(self.state, State::Loaded(_)) {
            self.navigating = true;
        } else {
            self.state = State::Loading;
        }

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
