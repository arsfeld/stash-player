//! Inline video player with a custom on-screen display.
//!
//! Wraps `gtk::Picture` driven by a hand-built GStreamer `playbin3`
//! pipeline (with `gtk4paintablesink` as the video sink) and lays a
//! libadwaita-flavoured OSD on top: a seek bar, transport buttons, time
//! labels, a volume slider, and a fullscreen toggle. Controls fade out
//! after a short period of pointer / keyboard inactivity, mpv-style.
//!
//! Standard mpv shortcuts honoured (when the player has focus):
//!   Space / k       toggle play/pause
//!   Left / Right    seek -5s / +5s
//!   Shift+L/R       seek -1s / +1s
//!   j / l           seek -10s / +10s
//!   Up / Down       seek +60s / -60s   (mpv default)
//!   Home / 0        seek to start
//!   End             seek to end
//!   m               mute toggle
//!   9 / 0           volume down / up   (mpv uses 9/0; we also use Up/Down for seek)
//!   f               toggle fullscreen
//!   Esc             exit fullscreen
//!
//! Position polling runs at 4 Hz via `glib::timeout_add_local`, feeding a
//! `SeekTracker` that ignores readings inconsistent with an outstanding
//! seek — see `stash_player_core::playback`.

mod pipeline;

use pipeline::PlaybackPipeline;

use std::cell::Cell;
use std::rc::Rc;
use std::time::{Duration, Instant};

use gtk::glib;
use gtk::prelude::*;
use relm4::gtk;
use relm4::prelude::*;
use stash_player_core::playback::SeekTracker;

const TICK_INTERVAL_MS: u32 = 250;
const HIDE_DELAY_MS: u32 = 2500;
/// Wall-clock minimum between activity checkpoints while playing. Matches
/// the cadence Stash's web UI uses.
const ACTIVITY_THROTTLE: Duration = Duration::from_secs(10);

#[derive(Debug)]
pub(crate) struct VideoPlayerInit {
    pub(crate) url: Option<String>,
    /// Start playing as soon as a stream is loaded (initial URL and any
    /// later `SetUrl`).
    pub(crate) autoplay: bool,
    /// Saved resume position (seconds) for the initial URL. Applied once
    /// the stream is prepared, then forgotten.
    pub(crate) resume_secs: Option<f64>,
    /// Initial volume in `0.0..=1.0`. Restored from app config so the
    /// user's preference survives across scenes and restarts.
    pub(crate) volume: f64,
    /// Initial mute state, paired with `volume` so unmuting returns to
    /// the previously chosen level.
    pub(crate) muted: bool,
}

impl Default for VideoPlayerInit {
    fn default() -> Self {
        Self {
            url: None,
            autoplay: false,
            resume_secs: None,
            volume: 1.0,
            muted: false,
        }
    }
}

/// What the player tells the parent (the scene page) about playback.
#[derive(Debug)]
pub(crate) enum VideoPlayerOutput {
    /// Activity checkpoint — fires on a 10s throttle while playing, on
    /// pause, on user-initiated seek, and right before a URL swap or
    /// clear. `resume_secs` is the current playback position;
    /// `play_duration_secs` is the wall-clock seconds spent playing
    /// since the previous checkpoint (a non-negative delta the parent
    /// should hand to Stash so play counts can increment).
    ActivityCheckpoint {
        resume_secs: f64,
        play_duration_secs: f64,
    },
    /// The OSD just revealed (true) or hid (false). The scene page uses
    /// this to fade the floating header bar in lockstep so window chrome
    /// disappears alongside the player controls when the mouse is idle.
    ControlsRevealedChanged(bool),
    /// User changed the volume or mute state via the OSD or a keyboard
    /// shortcut. The scene page forwards this to the app so the config
    /// gets persisted — the slider's pipeline state is already up to date.
    VolumeChanged { volume: f64, muted: bool },
    /// A scene-level OSD control was activated. The player has no idea
    /// what these mean — the scene page does.
    SceneAction(SceneAction),
    /// Fullscreen was entered (true) or left (false).
    FullscreenChanged(bool),
}

/// Everything the OSD needs to render the scene-level controls. Grouped
/// into one record so `VideoPlayerMsg` doesn't grow a cluster of
/// near-identical variants — the player treats these as opaque display
/// values and never interprets them.
#[derive(Debug, Clone, Copy, Default)]
pub(crate) struct SceneActionState {
    pub(crate) can_prev: bool,
    pub(crate) can_next: bool,
    /// `None` when no scene is currently loaded (e.g. mid-navigation) —
    /// the O-counter group renders insensitive in that case. This is a
    /// different kind of absence than `rating100`'s `None`, which means
    /// "loaded, but unrated": don't conflate the two.
    pub(crate) o_count: Option<i32>,
    pub(crate) rating100: Option<i32>,
}

/// A scene-level control the user activated. The player forwards these
/// verbatim; the scene page decides what they do.
#[derive(Debug, Clone, Copy)]
pub(crate) enum SceneAction {
    Prev,
    Next,
    IncrementO,
    ResetO,
}

#[derive(Debug)]
pub(crate) enum VideoPlayerMsg {
    /// Load a new stream URI. Pass `url: None` to clear. `resume_secs`
    /// is applied once the new stream reports a duration, then dropped.
    SetUrl {
        url: Option<String>,
        resume_secs: Option<f64>,
    },
    /// Update the autoplay policy for future `SetUrl` calls.
    SetAutoplay(bool),
    /// 4 Hz timer poll: refresh slider + labels from the media stream.
    Tick,
    TogglePlay,
    /// Seek by N seconds, clamped to [0, duration].
    SeekRelative(i64),
    /// Seek to a fraction of the duration.
    SeekFraction(f64),
    /// Seek to absolute microseconds (used by the seek slider).
    UserSeek(i64),
    SetVolume(f64),
    AdjustVolume(f64),
    ToggleMute,
    ToggleFullscreen,
    ExitFullscreen,
    /// Pointer moved or a key was pressed — extend the controls' visible
    /// window.
    PointerActive,
    /// Inactivity timer fired — hide controls if not interacting.
    HideControls,
    /// Forwarded from the EventControllerKey on the player surface.
    KeyPressed(gtk::gdk::Key, gtk::gdk::ModifierType),
    /// The pipeline reported a seek completed, at this position in
    /// microseconds. Negative means the position query failed.
    SeekLanded(i64),
    /// Refresh the OSD's scene-level controls.
    SetSceneActions(SceneActionState),
    /// An OSD scene-level control was clicked; forwarded to the parent.
    SceneActionClicked(SceneAction),
}

/// Independent playback flags grouped to keep `VideoPlayer`'s top-level
/// bool count under the `struct_excessive_bools` threshold.
#[derive(Debug, Default)]
struct PlaybackFlags {
    /// Stream is actually playing (mirrors `media.is_playing()` between ticks).
    playing: bool,
    /// New streams should auto-start; updated by `SetAutoplay`.
    autoplay: bool,
}

/// OSD reveal flags, similarly grouped.
#[derive(Debug, Default)]
struct OsdState {
    /// Most recent request to reveal the OSD (driven by inactivity timer).
    show_controls: bool,
    /// Latched copy of the most recently emitted reveal state. We diff
    /// against this in `update_with_view` so the parent only hears about
    /// real edge transitions, not every tick.
    controls_revealed: bool,
}

pub(crate) struct VideoPlayer {
    media: Option<PlaybackPipeline>,
    url: Option<String>,
    /// Playhead position and duration, including seeks that haven't
    /// landed yet. See `stash_player_core::playback` for why this can't
    /// just be the polled position.
    seek: SeekTracker,
    volume: f64,
    muted: bool,
    playback: PlaybackFlags,
    is_fullscreen: bool,
    /// Transient borderless window holding the player while in fullscreen.
    /// `None` outside fullscreen.
    fs_window: Option<gtk::Window>,
    /// Original parent of `root_box` to reparent back to on exit. Stored as
    /// the inline overlay we were embedded in.
    fs_original_parent: Option<gtk::Widget>,
    /// OSD reveal-state flags (current request + most recently emitted edge).
    osd: OsdState,
    hide_source: Option<glib::SourceId>,
    tick_source: Option<glib::SourceId>,
    /// Flag set while we update the seek scale programmatically so the
    /// `value-changed` handler can ignore our own writes.
    suppress_scale: Rc<Cell<bool>>,
    suppress_volume: Rc<Cell<bool>>,
    /// True while a pointer button is held on the seek slider, so
    /// `refresh_widgets` doesn't fight the user's drag.
    dragging: Rc<Cell<bool>>,
    // ─── activity tracking ───────────────────────────────────────────────
    /// Set while the underlying stream reports `is_playing()`; cleared on
    /// every transition out of playing so we can sum up watched time.
    playing_since: Option<Instant>,
    /// Wall-clock microseconds spent playing since the last checkpoint.
    play_duration_us: u64,
    /// When the last `ActivityCheckpoint` was emitted, so the 10s throttle
    /// can decide when the next one is due.
    last_save_at: Option<Instant>,
    /// Resume position (seconds) waiting to be applied once the freshly
    /// loaded stream reports a non-zero duration. `take()`-d on apply.
    resume_pending: Option<f64>,
    /// Display state for the OSD's scene-level controls, pushed in by
    /// the scene page.
    scene_actions: SceneActionState,
}

#[relm4::component(pub(crate))]
impl Component for VideoPlayer {
    type Init = VideoPlayerInit;
    type Input = VideoPlayerMsg;
    type Output = VideoPlayerOutput;
    type CommandOutput = ();

    view! {
        #[name = "root_box"]
        gtk::Box {
            set_orientation: gtk::Orientation::Vertical,
            set_focusable: true,
            set_can_focus: true,
            add_css_class: "video-player",
            set_overflow: gtk::Overflow::Hidden,

            #[name = "stack_overlay"]
            gtk::Overlay {
                set_hexpand: true,
                set_vexpand: true,

                // Wrap the GtkPicture in a GtkGraphicsOffload (4.14+) so
                // the video paintable is composited directly by the
                // Wayland compositor instead of going through GSK every
                // frame — same trick GtkVideo uses internally. Without
                // this, decoded frames hit GTK's normal render pass and
                // playback stutters under load.
                #[wrap(Some)]
                set_child = &gtk::GraphicsOffload {
                    set_enabled: gtk::GraphicsOffloadEnabled::Enabled,

                    #[wrap(Some)]
                    #[name = "picture"]
                    set_child = &gtk::Picture {
                        set_hexpand: true,
                        set_vexpand: true,
                        // Just a floor against degenerate allocations —
                        // the real height comes from the window now that
                        // nothing above us is a ScrolledWindow.
                        set_height_request: 200,
                        set_content_fit: gtk::ContentFit::Contain,
                        add_css_class: "video-surface",
                    },
                },

                // Centred big play / pause / replay glyph that flashes on
                // state change. Hidden when controls fade out.
                add_overlay = &gtk::Box {
                    set_halign: gtk::Align::Center,
                    set_valign: gtk::Align::Center,
                    set_can_target: false,

                    #[name = "center_indicator"]
                    gtk::Image {
                        add_css_class: "video-center-indicator",
                        set_pixel_size: 96,
                        set_visible: false,
                        set_icon_name: Some("media-playback-start-symbolic"),
                    },
                },

                // Loading / error plate. Shown while the pipeline is
                // preparing (so opening a stream is visible feedback) and
                // swapped to an error message if the pipeline fails. Not
                // shown during seeks — playbin3 prepares fast enough that
                // a flashing spinner during scrubbing was just noise.
                add_overlay = &gtk::Box {
                    set_halign: gtk::Align::Center,
                    set_valign: gtk::Align::Center,
                    set_can_target: false,

                    #[name = "status_plate"]
                    gtk::Box {
                        set_orientation: gtk::Orientation::Vertical,
                        set_spacing: 12,
                        set_halign: gtk::Align::Center,
                        set_valign: gtk::Align::Center,
                        add_css_class: "video-status-plate",
                        set_visible: false,

                        #[name = "status_spinner"]
                        gtk::Spinner {
                            set_spinning: true,
                            set_width_request: 48,
                            set_height_request: 48,
                            set_halign: gtk::Align::Center,
                        },

                        #[name = "status_icon"]
                        gtk::Image {
                            set_icon_name: Some("dialog-error-symbolic"),
                            set_pixel_size: 48,
                            set_halign: gtk::Align::Center,
                            set_visible: false,
                        },

                        #[name = "status_title"]
                        gtk::Label {
                            set_label: "Loading video…",
                            add_css_class: "video-status-title",
                            set_halign: gtk::Align::Center,
                        },

                        #[name = "status_detail"]
                        gtk::Label {
                            add_css_class: "video-status-detail",
                            set_halign: gtk::Align::Center,
                            set_wrap: true,
                            set_justify: gtk::Justification::Center,
                            set_max_width_chars: 48,
                            set_visible: false,
                        },
                    },
                },

                // The OSD bar lives in a Revealer so we can fade it
                // smoothly. `set_can_target: false` on the surrounding box
                // would block clicks on the controls — we want them
                // clickable, so leave targeting on for the inner content.
                add_overlay = &gtk::Box {
                    set_valign: gtk::Align::End,
                    set_halign: gtk::Align::Fill,

                    #[name = "controls_revealer"]
                    gtk::Revealer {
                        set_transition_type: gtk::RevealerTransitionType::Crossfade,
                        set_transition_duration: 180,
                        set_reveal_child: true,
                        set_hexpand: true,

                        #[name = "controls_box"]
                        gtk::Box {
                            set_orientation: gtk::Orientation::Vertical,
                            add_css_class: "video-osd",
                            set_hexpand: true,

                            // Seek bar row.
                            gtk::Box {
                                set_orientation: gtk::Orientation::Horizontal,
                                set_spacing: 10,
                                set_margin_start: 16,
                                set_margin_end: 16,
                                set_margin_top: 8,

                                #[name = "position_label"]
                                gtk::Label {
                                    set_label: "0:00",
                                    add_css_class: "video-osd-time",
                                    set_width_chars: 5,
                                    set_xalign: 1.0,
                                },

                                #[name = "seek_scale"]
                                gtk::Scale {
                                    set_orientation: gtk::Orientation::Horizontal,
                                    set_hexpand: true,
                                    set_draw_value: false,
                                    set_range: (0.0, 1.0),
                                    add_css_class: "video-osd-seek",
                                },

                                #[name = "duration_label"]
                                gtk::Label {
                                    set_label: "--:--",
                                    add_css_class: "video-osd-time",
                                    set_width_chars: 5,
                                    set_xalign: 0.0,
                                },
                            },

                            // Transport row.
                            gtk::Box {
                                set_orientation: gtk::Orientation::Horizontal,
                                set_spacing: 6,
                                set_margin_start: 12,
                                set_margin_end: 12,
                                set_margin_top: 4,
                                set_margin_bottom: 12,

                                #[name = "prev_scene_button"]
                                gtk::Button {
                                    set_icon_name: "media-skip-backward-symbolic",
                                    add_css_class: "flat",
                                    add_css_class: "circular",
                                    set_tooltip_text: Some("Previous scene"),
                                    connect_clicked[sender] => move |_| {
                                        sender.input(VideoPlayerMsg::SceneActionClicked(
                                            SceneAction::Prev,
                                        ));
                                    },
                                },

                                #[name = "play_button"]
                                gtk::Button {
                                    set_icon_name: "media-playback-start-symbolic",
                                    add_css_class: "circular",
                                    add_css_class: "video-osd-primary",
                                    set_tooltip_text: Some("Play / pause (Space)"),
                                    connect_clicked[sender] => move |_| {
                                        sender.input(VideoPlayerMsg::TogglePlay);
                                    },
                                },

                                #[name = "next_scene_button"]
                                gtk::Button {
                                    set_icon_name: "media-skip-forward-symbolic",
                                    add_css_class: "flat",
                                    add_css_class: "circular",
                                    set_tooltip_text: Some("Next scene"),
                                    connect_clicked[sender] => move |_| {
                                        sender.input(VideoPlayerMsg::SceneActionClicked(
                                            SceneAction::Next,
                                        ));
                                    },
                                },

                                gtk::Button {
                                    set_icon_name: "media-seek-backward-symbolic",
                                    add_css_class: "flat",
                                    add_css_class: "circular",
                                    set_tooltip_text: Some("Back 10s (j)"),
                                    connect_clicked[sender] => move |_| {
                                        sender.input(VideoPlayerMsg::SeekRelative(-10));
                                    },
                                },

                                gtk::Button {
                                    set_icon_name: "media-seek-forward-symbolic",
                                    add_css_class: "flat",
                                    add_css_class: "circular",
                                    set_tooltip_text: Some("Forward 10s (l)"),
                                    connect_clicked[sender] => move |_| {
                                        sender.input(VideoPlayerMsg::SeekRelative(10));
                                    },
                                },

                                gtk::Box { set_hexpand: true },

                                #[name = "osd_o_counter_group"]
                                gtk::Box {
                                    add_css_class: "linked",
                                    set_valign: gtk::Align::Center,

                                    gtk::Button {
                                        add_css_class: "flat",
                                        set_tooltip_text: Some("Bump O-counter"),
                                        connect_clicked[sender] => move |_| {
                                            sender.input(VideoPlayerMsg::SceneActionClicked(
                                                SceneAction::IncrementO,
                                            ));
                                        },

                                        #[wrap(Some)]
                                        set_child = &gtk::Box {
                                            set_orientation: gtk::Orientation::Horizontal,
                                            set_spacing: 6,
                                            set_valign: gtk::Align::Center,

                                            gtk::Image {
                                                set_icon_name: Some("o-counter-symbolic"),
                                                set_pixel_size: 14,
                                            },

                                            #[name = "osd_o_count_label"]
                                            gtk::Label {
                                                add_css_class: "o-counter-pill",
                                            },
                                        },
                                    },

                                    #[name = "osd_o_reset_button"]
                                    gtk::Button {
                                        set_icon_name: "edit-clear-symbolic",
                                        add_css_class: "flat",
                                        set_tooltip_text: Some("Reset O-counter to 0"),
                                        connect_clicked[sender] => move |_| {
                                            sender.input(VideoPlayerMsg::SceneActionClicked(
                                                SceneAction::ResetO,
                                            ));
                                        },
                                    },
                                },

                                #[name = "osd_rating_label"]
                                gtk::Label {
                                    add_css_class: "rating-badge",
                                    set_valign: gtk::Align::Center,
                                    set_margin_start: 8,
                                    set_visible: false,
                                },

                                gtk::Box { set_hexpand: true },

                                #[name = "volume_button"]
                                gtk::Button {
                                    set_icon_name: "audio-volume-high-symbolic",
                                    add_css_class: "flat",
                                    add_css_class: "circular",
                                    set_tooltip_text: Some("Mute (m)"),
                                    connect_clicked[sender] => move |_| {
                                        sender.input(VideoPlayerMsg::ToggleMute);
                                    },
                                },

                                #[name = "volume_scale"]
                                gtk::Scale {
                                    set_orientation: gtk::Orientation::Horizontal,
                                    set_draw_value: false,
                                    set_range: (0.0, 1.0),
                                    set_value: 1.0,
                                    set_width_request: 110,
                                    add_css_class: "video-osd-volume",
                                },

                                #[name = "fullscreen_button"]
                                gtk::Button {
                                    set_icon_name: "view-fullscreen-symbolic",
                                    add_css_class: "flat",
                                    add_css_class: "circular",
                                    set_tooltip_text: Some("Fullscreen (f)"),
                                    connect_clicked[sender] => move |_| {
                                        sender.input(VideoPlayerMsg::ToggleFullscreen);
                                    },
                                },
                            },
                        },
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
        let suppress_scale = Rc::new(Cell::new(false));
        let suppress_volume = Rc::new(Cell::new(false));
        let dragging = Rc::new(Cell::new(false));

        let mut model = VideoPlayer::new_model(
            &init,
            suppress_scale.clone(),
            suppress_volume.clone(),
            dragging.clone(),
        );

        let widgets = view_output!();

        wire_slider_handlers(
            &widgets,
            &sender,
            &suppress_scale,
            &suppress_volume,
            &dragging,
        );
        wire_pointer_handlers(&widgets, &sender);
        wire_keyboard_handlers(&widgets, &sender);

        // Kick off the position-polling timer.
        let tick = glib::timeout_add_local(
            std::time::Duration::from_millis(TICK_INTERVAL_MS as u64),
            {
                let sender = sender.clone();
                move || {
                    sender.input(VideoPlayerMsg::Tick);
                    glib::ControlFlow::Continue
                }
            },
        );

        // Start the inactivity timer immediately so controls hide on a
        // still scene. They'll re-reveal on the next pointer/keypress.
        sender.input(VideoPlayerMsg::PointerActive);

        model.tick_source = Some(tick);

        if let Some(url) = init.url {
            sender.input(VideoPlayerMsg::SetUrl {
                url: Some(url),
                resume_secs: init.resume_secs,
            });
        }

        ComponentParts { model, widgets }
    }

    fn update_with_view(
        &mut self,
        widgets: &mut Self::Widgets,
        msg: VideoPlayerMsg,
        sender: ComponentSender<Self>,
        root: &Self::Root,
    ) {
        match msg {
            VideoPlayerMsg::SetUrl { url, resume_secs } => {
                self.handle_set_url(widgets, &sender, url, resume_secs);
            }
            VideoPlayerMsg::SetAutoplay(on) => self.playback.autoplay = on,
            VideoPlayerMsg::Tick => self.handle_tick(widgets, &sender),
            VideoPlayerMsg::TogglePlay => self.handle_toggle_play(widgets, &sender),
            VideoPlayerMsg::SeekRelative(secs) => self.handle_seek_relative(&sender, secs),
            VideoPlayerMsg::SeekFraction(f) => self.handle_seek_fraction(&sender, f),
            VideoPlayerMsg::UserSeek(us) => self.handle_user_seek(&sender, us),
            VideoPlayerMsg::SetVolume(v) => self.handle_set_volume(&sender, v),
            VideoPlayerMsg::AdjustVolume(delta) => {
                let v = (self.volume + delta).clamp(0.0, 1.0);
                sender.input(VideoPlayerMsg::SetVolume(v));
                sender.input(VideoPlayerMsg::PointerActive);
            }
            VideoPlayerMsg::ToggleMute => self.handle_toggle_mute(&sender),
            VideoPlayerMsg::ToggleFullscreen => self.handle_toggle_fullscreen(widgets, &sender),
            VideoPlayerMsg::ExitFullscreen => self.handle_exit_fullscreen(widgets, &sender),
            VideoPlayerMsg::PointerActive => self.handle_pointer_active(&sender),
            VideoPlayerMsg::HideControls => {
                self.hide_source = None;
                self.osd.show_controls = false;
            }
            VideoPlayerMsg::KeyPressed(key, mods) => {
                if self.handle_key(&sender, key, mods) {
                    sender.input(VideoPlayerMsg::PointerActive);
                }
            }
            VideoPlayerMsg::SeekLanded(landed_us) => self.seek.on_async_done(landed_us),
            VideoPlayerMsg::SetSceneActions(state) => self.scene_actions = state,
            VideoPlayerMsg::SceneActionClicked(action) => {
                let _ = sender.output(VideoPlayerOutput::SceneAction(action));
                sender.input(VideoPlayerMsg::PointerActive);
            }
        }

        // Notify the parent on reveal-state edges so it can fade the
        // floating header bar together with the OSD. Computed here (not
        // in `refresh_widgets`) because we need `&mut self` to latch the
        // last value, and emitting only on changes avoids spamming the
        // parent on every tick.
        let force_visible = self.media.is_none() || self.seek.duration_us() == 0;
        let revealed = self.osd.show_controls || force_visible;
        if revealed != self.osd.controls_revealed {
            self.osd.controls_revealed = revealed;
            let _ = sender.output(VideoPlayerOutput::ControlsRevealedChanged(revealed));
        }

        // Re-render derived widget state. We keep this manual because
        // many of these properties depend on multiple model fields and a
        // few need to skip our own value-changed handlers.
        self.refresh_widgets(widgets, root);
        let _ = root;
    }

    fn shutdown(&mut self, _widgets: &mut Self::Widgets, output: relm4::Sender<Self::Output>) {
        if let Some(id) = self.tick_source.take() {
            id.remove();
        }
        if let Some(id) = self.hide_source.take() {
            id.remove();
        }
        if let Some(media) = &self.media {
            media.pause();
        }
        // Drop the pipeline so its bus watch and any audio output are
        // torn down before the widget tree is finalized.
        self.media = None;
        if let Some(fs_window) = self.fs_window.take() {
            fs_window.set_child(gtk::Widget::NONE);
            fs_window.destroy();
        }

        // Best-effort final activity flush. The receiving component (the
        // scene page) is being torn down too, so the message may or may
        // not be processed; the URL-swap and pause flushes carry the
        // weight, this is just a safety net for the close-while-playing
        // case.
        self.capture_play_time();
        let resume_secs = self.seek.position_us().max(0) as f64 / 1_000_000.0;
        let play_duration_secs = self.play_duration_us as f64 / 1_000_000.0;
        if self.media.is_some() && (play_duration_secs > 0.0 || resume_secs > 0.0) {
            let _ = output.send(VideoPlayerOutput::ActivityCheckpoint {
                resume_secs,
                play_duration_secs,
            });
        }
    }
}

/// Hook the seek + volume scales: anything that isn't our own programmatic
/// write becomes a UserSeek/SetVolume. A capture-phase click gesture on the
/// seek scale tracks whether a pointer button is currently held, so
/// `refresh_widgets` can leave the thumb alone mid-drag.
fn wire_slider_handlers(
    widgets: &VideoPlayerWidgets,
    sender: &ComponentSender<VideoPlayer>,
    suppress_scale: &Rc<Cell<bool>>,
    suppress_volume: &Rc<Cell<bool>>,
    dragging: &Rc<Cell<bool>>,
) {
    {
        let sender = sender.clone();
        let suppress = suppress_scale.clone();
        widgets.seek_scale.connect_value_changed(move |s| {
            if suppress.get() {
                return;
            }
            sender.input(VideoPlayerMsg::UserSeek(s.value() as i64));
        });
    }
    {
        // Capture phase: GtkScale's own gestures would otherwise claim
        // the sequence before we see the press.
        let drag = gtk::GestureClick::new();
        drag.set_propagation_phase(gtk::PropagationPhase::Capture);
        let on_press = dragging.clone();
        drag.connect_pressed(move |_, _, _, _| on_press.set(true));
        let on_release = dragging.clone();
        drag.connect_released(move |_, _, _, _| on_release.set(false));
        // A cancelled gesture (grab stolen, pointer left the surface)
        // never delivers `released`; without this the thumb would stay
        // frozen for the rest of the session.
        let on_cancel = dragging.clone();
        drag.connect_cancel(move |_, _| on_cancel.set(false));
        widgets.seek_scale.add_controller(drag);
    }
    let sender = sender.clone();
    let suppress = suppress_volume.clone();
    widgets.volume_scale.connect_value_changed(move |s| {
        if suppress.get() {
            return;
        }
        sender.input(VideoPlayerMsg::SetVolume(s.value()));
    });
}

/// Pointer motion → wake controls. Single click anywhere on the surface
/// toggles play/pause; double click toggles fullscreen. Both paths also
/// keep the OSD visible (PointerActive).
fn wire_pointer_handlers(
    widgets: &VideoPlayerWidgets,
    sender: &ComponentSender<VideoPlayer>,
) {
    let motion = gtk::EventControllerMotion::new();
    let sender_m = sender.clone();
    motion.connect_motion(move |_, _, _| {
        sender_m.input(VideoPlayerMsg::PointerActive);
    });
    widgets.stack_overlay.add_controller(motion);

    let click = gtk::GestureClick::new();
    click.set_button(gtk::gdk::BUTTON_PRIMARY);
    let sender_c = sender.clone();
    let root_for_focus = widgets.root_box.clone();
    click.connect_pressed(move |_, n, _, _| {
        root_for_focus.grab_focus();
        if n == 1 {
            sender_c.input(VideoPlayerMsg::TogglePlay);
        } else if n == 2 {
            sender_c.input(VideoPlayerMsg::ToggleFullscreen);
        }
        sender_c.input(VideoPlayerMsg::PointerActive);
    });
    // Attach to the picture (not the controls bar) so clicks on the OSD
    // don't steal play/pause toggles.
    widgets.picture.add_controller(click);
}

/// Keyboard shortcuts: capture phase so the slider (and any other focused
/// descendant) doesn't eat arrow keys before we see them. Return `Stop`
/// for keys we recognise so we don't double-handle (e.g. focused seek
/// slider + our own seek-by-5s).
fn wire_keyboard_handlers(
    widgets: &VideoPlayerWidgets,
    sender: &ComponentSender<VideoPlayer>,
) {
    let key = gtk::EventControllerKey::new();
    key.set_propagation_phase(gtk::PropagationPhase::Capture);
    let sender_k = sender.clone();
    key.connect_key_pressed(move |_, keyval, _, mods| {
        if is_player_shortcut(keyval) {
            sender_k.input(VideoPlayerMsg::KeyPressed(keyval, mods));
            glib::Propagation::Stop
        } else {
            glib::Propagation::Proceed
        }
    });
    widgets.root_box.add_controller(key);
}

impl VideoPlayer {
    /// Build the model struct with the right initial flags and shared
    /// suppression cells. Pulled out of `init` to keep that function
    /// short.
    fn new_model(
        init: &VideoPlayerInit,
        suppress_scale: Rc<Cell<bool>>,
        suppress_volume: Rc<Cell<bool>>,
        dragging: Rc<Cell<bool>>,
    ) -> Self {
        VideoPlayer {
            media: None,
            url: init.url.clone(),
            seek: SeekTracker::new(),
            volume: init.volume.clamp(0.0, 1.0),
            muted: init.muted,
            playback: PlaybackFlags {
                playing: false,
                autoplay: init.autoplay,
            },
            is_fullscreen: false,
            fs_window: None,
            fs_original_parent: None,
            osd: OsdState {
                show_controls: true,
                controls_revealed: true,
            },
            hide_source: None,
            tick_source: None,
            suppress_scale,
            suppress_volume,
            dragging,
            playing_since: None,
            play_duration_us: 0,
            last_save_at: None,
            resume_pending: None,
            scene_actions: SceneActionState::default(),
        }
    }

    /// Move any in-flight "currently playing" interval into the
    /// accumulator. Called on every transition out of playing (pause,
    /// seek, URL swap, shutdown) so play_duration_us is always current.
    fn capture_play_time(&mut self) {
        if let Some(start) = self.playing_since.take() {
            let elapsed = start.elapsed().as_micros() as u64;
            self.play_duration_us = self.play_duration_us.saturating_add(elapsed);
        }
    }

    /// Emit an `ActivityCheckpoint` to the parent and reset the
    /// per-checkpoint accumulators. If we're still playing, restart the
    /// `playing_since` watermark so subsequent ticks keep counting.
    fn emit_checkpoint(&mut self, sender: &ComponentSender<Self>) {
        self.capture_play_time();
        let resume_secs = self.seek.position_us().max(0) as f64 / 1_000_000.0;
        let play_duration_secs = self.play_duration_us as f64 / 1_000_000.0;
        self.play_duration_us = 0;
        self.last_save_at = Some(Instant::now());
        let _ = sender.output(VideoPlayerOutput::ActivityCheckpoint {
            resume_secs,
            play_duration_secs,
        });
        if self.playback.playing {
            self.playing_since = Some(Instant::now());
        }
    }

    fn refresh_widgets(
        &self,
        widgets: &<Self as Component>::Widgets,
        _root: &<Self as Component>::Root,
    ) {
        // The tracker's position never regresses spuriously, so we push
        // it unconditionally — except while the user has the thumb held,
        // where our writes would fight the drag.
        let duration_us = self.seek.duration_us();
        let max = duration_us.max(1) as f64;
        widgets.seek_scale.set_range(0.0, max);
        if !self.dragging.get() {
            let pos = self.seek.position_us().clamp(0, duration_us.max(0)) as f64;
            self.suppress_scale.set(true);
            widgets.seek_scale.set_value(pos);
            self.suppress_scale.set(false);
        }
        widgets.seek_scale.set_sensitive(duration_us > 0);

        widgets
            .position_label
            .set_label(&format_us(self.seek.position_us()));
        let duration_text = if duration_us > 0 {
            format_us(duration_us)
        } else {
            "--:--".into()
        };
        widgets.duration_label.set_label(&duration_text);

        // Play / pause icon.
        widgets.play_button.set_icon_name(if self.playback.playing {
            "media-playback-pause-symbolic"
        } else {
            "media-playback-start-symbolic"
        });

        // Volume slider + button icon.
        let vol = if self.muted { 0.0 } else { self.volume };
        self.suppress_volume.set(true);
        widgets.volume_scale.set_value(vol);
        self.suppress_volume.set(false);
        widgets
            .volume_button
            .set_icon_name(volume_icon(self.muted, self.volume));

        // Fullscreen icon.
        widgets
            .fullscreen_button
            .set_icon_name(if self.is_fullscreen {
                "view-restore-symbolic"
            } else {
                "view-fullscreen-symbolic"
            });

        // Scene-level OSD controls. Purely a projection of whatever the
        // scene page last pushed in.
        refresh_scene_actions(widgets, self.scene_actions);

        // OSD visibility: stay up only when no media is loaded yet so the
        // user has something to look at; otherwise let the inactivity timer
        // hide it whether playing or paused. `controls_revealed` was
        // computed (and emitted upward) in `update_with_view`.
        widgets.controls_revealer.set_reveal_child(self.osd.controls_revealed);

        // Cursor: hide on the player widget when controls are hidden so
        // the OSD "gets out of the way". Scoped to the widget (not the
        // toplevel surface) so the rest of the page keeps a normal
        // pointer.
        let cursor = if self.osd.controls_revealed {
            None
        } else {
            gtk::gdk::Cursor::from_name("none", None)
        };
        widgets.root_box.set_cursor(cursor.as_ref());
    }

    fn handle_key(
        &mut self,
        sender: &ComponentSender<Self>,
        key: gtk::gdk::Key,
        mods: gtk::gdk::ModifierType,
    ) -> bool {
        use gtk::gdk::Key;
        let shift = mods.contains(gtk::gdk::ModifierType::SHIFT_MASK);
        match key {
            Key::space | Key::k | Key::K => {
                sender.input(VideoPlayerMsg::TogglePlay);
                true
            }
            Key::Left => {
                let step = if shift { -1 } else { -5 };
                sender.input(VideoPlayerMsg::SeekRelative(step));
                true
            }
            Key::Right => {
                let step = if shift { 1 } else { 5 };
                sender.input(VideoPlayerMsg::SeekRelative(step));
                true
            }
            Key::j | Key::J => {
                sender.input(VideoPlayerMsg::SeekRelative(-10));
                true
            }
            Key::l | Key::L => {
                sender.input(VideoPlayerMsg::SeekRelative(10));
                true
            }
            Key::Up => {
                sender.input(VideoPlayerMsg::SeekRelative(60));
                true
            }
            Key::Down => {
                sender.input(VideoPlayerMsg::SeekRelative(-60));
                true
            }
            Key::Home => {
                sender.input(VideoPlayerMsg::SeekFraction(0.0));
                true
            }
            Key::End => {
                sender.input(VideoPlayerMsg::SeekFraction(1.0));
                true
            }
            Key::m | Key::M => {
                sender.input(VideoPlayerMsg::ToggleMute);
                true
            }
            Key::_9 => {
                sender.input(VideoPlayerMsg::AdjustVolume(-0.05));
                true
            }
            Key::_0 => {
                sender.input(VideoPlayerMsg::AdjustVolume(0.05));
                true
            }
            Key::f | Key::F => {
                sender.input(VideoPlayerMsg::ToggleFullscreen);
                true
            }
            Key::Escape if self.is_fullscreen => {
                sender.input(VideoPlayerMsg::ExitFullscreen);
                true
            }
            _ => false,
        }
    }

    fn handle_set_url(
        &mut self,
        widgets: &mut <Self as Component>::Widgets,
        sender: &ComponentSender<Self>,
        url: Option<String>,
        resume_secs: Option<f64>,
    ) {
        // Flush activity for the outgoing scene first so the parent
        // records its final resume + watched-time delta.
        if self.media.is_some() {
            self.emit_checkpoint(sender);
        }

        self.url = url.clone();
        self.seek.on_stream_reset();
        self.playback.playing = false;
        self.playing_since = None;
        self.play_duration_us = 0;
        self.last_save_at = None;
        // Treat 0 (or negative) as "no saved resume" — Stash returns 0
        // for unwatched scenes and we don't want to re-seek to 0 every
        // load.
        self.resume_pending = resume_secs.filter(|s| *s > 0.0);

        // Tear down any existing pipeline before creating a new one so
        // audio doesn't leak between scenes.
        self.media = None;

        let Some(url) = url else {
            widgets.picture.set_paintable(gtk::gdk::Paintable::NONE);
            return;
        };
        let Some(pipeline) = PlaybackPipeline::new(&url, self.playback.autoplay, sender) else {
            widgets.picture.set_paintable(gtk::gdk::Paintable::NONE);
            return;
        };
        pipeline.set_volume(self.volume);
        pipeline.set_muted(self.muted);
        widgets.picture.set_paintable(Some(pipeline.paintable()));
        if self.playback.autoplay {
            self.playback.playing = true;
            self.playing_since = Some(Instant::now());
        }
        self.media = Some(pipeline);
        // Anchor the throttle so the first checkpoint fires 10s into
        // playback, not on the very first tick.
        self.last_save_at = Some(Instant::now());
    }

    fn handle_tick(
        &mut self,
        widgets: &mut <Self as Component>::Widgets,
        sender: &ComponentSender<Self>,
    ) {
        let Some(media) = self.media.as_ref() else {
            return;
        };
        let was_playing = self.playback.playing;
        let snapshot = TickSnapshot {
            status: PipelineStatus {
                now_playing: media.is_playing(),
                is_prepared: media.is_prepared(),
            },
            duration_us: media.duration_us().max(0),
            position_us: media.position_us().max(0),
            volume: media.volume(),
            muted: media.is_muted(),
            error_msg: media.error_message(),
        };
        let status = snapshot.status;

        self.update_playing_window(was_playing, status.now_playing);

        // Duration queries can transiently return 0 while a flushing
        // seek is in flight; SeekTracker::set_duration_us ignores those.
        self.seek.set_duration_us(snapshot.duration_us);
        self.playback.playing = status.now_playing;
        self.volume = snapshot.volume;
        self.muted = snapshot.muted;

        self.seek.on_poll(snapshot.position_us, Instant::now());
        self.apply_pending_resume(status.is_prepared);

        // Throttled activity checkpoint while playing.
        if status.now_playing && self.checkpoint_due() {
            self.emit_checkpoint(sender);
        }

        update_status_plate(widgets, snapshot.error_msg.as_deref(), status.is_prepared);
    }

    /// Track playing-state transitions so play_duration_us reflects only
    /// the time the stream was actually playing (paused/seeking time
    /// doesn't count).
    fn update_playing_window(&mut self, was_playing: bool, now_playing: bool) {
        if !was_playing && now_playing && self.playing_since.is_none() {
            self.playing_since = Some(Instant::now());
        } else if was_playing && !now_playing {
            self.capture_play_time();
        }
    }

    /// Apply the pending resume seek once the stream is ready enough
    /// that a clamp against duration is meaningful.
    fn apply_pending_resume(&mut self, is_prepared: bool) {
        if !is_prepared || self.seek.duration_us() <= 0 {
            return;
        }
        let Some(resume) = self.resume_pending.take() else {
            return;
        };
        let target = self
            .seek
            .seek_absolute((resume * 1_000_000.0) as i64, Instant::now());
        self.issue_seek(target);
    }

    fn checkpoint_due(&self) -> bool {
        self.last_save_at
            .map(|t| t.elapsed() >= ACTIVITY_THROTTLE)
            .unwrap_or(true)
    }

    fn handle_toggle_play(
        &mut self,
        widgets: &mut <Self as Component>::Widgets,
        sender: &ComponentSender<Self>,
    ) {
        let was_playing = self.media.as_ref().is_some_and(|m| m.is_playing());
        let Some(media) = self.media.as_ref() else {
            return;
        };
        if was_playing {
            media.pause();
            // User-initiated pause — flush a checkpoint so resume_time
            // on Stash mirrors the spot they stopped at.
            self.emit_checkpoint(sender);
        } else {
            media.play();
            self.playing_since = Some(Instant::now());
        }
        let now_playing = self.media.as_ref().is_some_and(|m| m.is_playing());
        // playbin3 state changes are async — assume the requested state
        // until the bus confirms.
        self.playback.playing = if was_playing { now_playing } else { true };
        flash_center(&widgets.center_indicator, self.playback.playing);
        sender.input(VideoPlayerMsg::PointerActive);
    }

    fn handle_seek_relative(&mut self, sender: &ComponentSender<Self>, secs: i64) {
        if !self.is_prepared() {
            return;
        }
        let target = self
            .seek
            .seek_relative(secs.saturating_mul(1_000_000), Instant::now());
        tracing::debug!(secs, target_us = target, "SeekRelative");
        self.issue_seek(target);
        self.emit_checkpoint(sender);
        sender.input(VideoPlayerMsg::PointerActive);
    }

    fn handle_seek_fraction(&mut self, sender: &ComponentSender<Self>, fraction: f64) {
        if !self.is_prepared() {
            return;
        }
        let target = self.seek.seek_fraction(fraction, Instant::now());
        tracing::debug!(fraction, target_us = target, "SeekFraction");
        self.issue_seek(target);
        self.emit_checkpoint(sender);
        sender.input(VideoPlayerMsg::PointerActive);
    }

    fn handle_user_seek(&mut self, sender: &ComponentSender<Self>, us: i64) {
        if !self.is_prepared() {
            return;
        }
        let target = self.seek.seek_absolute(us, Instant::now());
        tracing::debug!(slider_us = us, target_us = target, "UserSeek");
        self.issue_seek(target);
        self.emit_checkpoint(sender);
    }

    /// True when there's a stream loaded and prepared enough to seek.
    fn is_prepared(&self) -> bool {
        self.media.as_ref().is_some_and(|m| m.is_prepared())
    }

    /// Hand a target the tracker has already clamped to the pipeline.
    fn issue_seek(&self, target_us: i64) {
        if let Some(media) = self.media.as_ref() {
            media.seek(target_us);
        }
    }

    fn handle_set_volume(&mut self, sender: &ComponentSender<Self>, v: f64) {
        let v = v.clamp(0.0, 1.0);
        self.volume = v;
        if let Some(media) = self.media.as_ref() {
            media.set_volume(v);
            if v > 0.0 && media.is_muted() {
                media.set_muted(false);
                self.muted = false;
            }
        }
        let _ = sender.output(VideoPlayerOutput::VolumeChanged {
            volume: self.volume,
            muted: self.muted,
        });
    }

    fn handle_toggle_mute(&mut self, sender: &ComponentSender<Self>) {
        let Some(media) = self.media.as_ref() else {
            return;
        };
        let new_muted = !media.is_muted();
        media.set_muted(new_muted);
        self.muted = new_muted;
        sender.input(VideoPlayerMsg::PointerActive);
        let _ = sender.output(VideoPlayerOutput::VolumeChanged {
            volume: self.volume,
            muted: self.muted,
        });
    }

    fn handle_toggle_fullscreen(
        &mut self,
        widgets: &mut <Self as Component>::Widgets,
        sender: &ComponentSender<Self>,
    ) {
        if self.is_fullscreen {
            sender.input(VideoPlayerMsg::ExitFullscreen);
            return;
        }
        // Reparent the player into a transient borderless window so
        // fullscreen covers only the video, not the rest of the app
        // chrome. The root_box is removed from its current parent (the
        // scene page's player_slot Box) and reattached on exit.
        let Some(parent) = widgets.root_box.parent() else {
            return;
        };
        let Some(parent_box) = parent.downcast_ref::<gtk::Box>() else {
            return;
        };
        parent_box.remove(&widgets.root_box);

        let app_window = widgets.root_box.root().and_downcast::<gtk::Window>();
        let fs_window = gtk::Window::builder()
            .decorated(false)
            .child(&widgets.root_box)
            .build();
        if let Some(app) = app_window.as_ref() {
            fs_window.set_transient_for(Some(app));
        }
        fs_window.fullscreen();

        let sender_close = sender.clone();
        fs_window.connect_close_request(move |_| {
            sender_close.input(VideoPlayerMsg::ExitFullscreen);
            glib::Propagation::Stop
        });

        fs_window.present();
        widgets.root_box.grab_focus();

        self.fs_window = Some(fs_window);
        self.fs_original_parent = Some(parent);
        self.is_fullscreen = true;
        sender.input(VideoPlayerMsg::PointerActive);
        let _ = sender.output(VideoPlayerOutput::FullscreenChanged(self.is_fullscreen));
    }

    fn handle_exit_fullscreen(
        &mut self,
        widgets: &mut <Self as Component>::Widgets,
        sender: &ComponentSender<Self>,
    ) {
        if !self.is_fullscreen {
            return;
        }
        let Some(fs_window) = self.fs_window.take() else {
            return;
        };
        // Detach from the fullscreen window before destroying so the
        // widget survives, then reparent into the original player_slot.
        fs_window.set_child(gtk::Widget::NONE);
        if let Some(parent_box) = self
            .fs_original_parent
            .take()
            .and_then(|p| p.downcast::<gtk::Box>().ok())
        {
            parent_box.append(&widgets.root_box);
        }
        fs_window.destroy();
        self.is_fullscreen = false;
        let _ = sender.output(VideoPlayerOutput::FullscreenChanged(self.is_fullscreen));
    }

    fn handle_pointer_active(&mut self, sender: &ComponentSender<Self>) {
        self.osd.show_controls = true;
        if let Some(id) = self.hide_source.take() {
            id.remove();
        }
        let sender = sender.clone();
        let id = glib::timeout_add_local_once(
            std::time::Duration::from_millis(HIDE_DELAY_MS as u64),
            move || sender.input(VideoPlayerMsg::HideControls),
        );
        self.hide_source = Some(id);
    }
}

/// Pipeline-state flags captured at the start of a tick.
#[derive(Clone, Copy)]
struct PipelineStatus {
    now_playing: bool,
    is_prepared: bool,
}

/// Snapshot of pipeline state captured once per tick so the rest of the
/// handler can read consistent values without re-querying GStreamer.
struct TickSnapshot {
    status: PipelineStatus,
    duration_us: i64,
    position_us: i64,
    volume: f64,
    muted: bool,
    error_msg: Option<String>,
}

/// Render the OSD's scene-level controls (prev/next, O-counter, rating).
/// Pulled out of `refresh_widgets` to keep that function under the line
/// ceiling — purely a projection of `SceneActionState`, no interpretation.
fn refresh_scene_actions(widgets: &VideoPlayerWidgets, actions: SceneActionState) {
    widgets.prev_scene_button.set_sensitive(actions.can_prev);
    widgets.next_scene_button.set_sensitive(actions.can_next);
    // No loaded scene (mid-navigation): grey the whole group out and
    // blank the count rather than show a stale or misleadingly-zero
    // number on a control that currently does nothing.
    widgets
        .osd_o_counter_group
        .set_sensitive(actions.o_count.is_some());
    widgets.osd_o_count_label.set_label(
        &actions
            .o_count
            .map(|count| count.to_string())
            .unwrap_or_default(),
    );
    widgets
        .osd_o_reset_button
        .set_visible(actions.o_count.is_some_and(|count| count > 0));
    match actions.rating100.filter(|r| *r > 0) {
        Some(rating) => {
            let stars = rating as f32 / 10.0;
            widgets.osd_rating_label.set_label(&format!("★ {stars:.1}"));
            widgets.osd_rating_label.set_visible(true);
        }
        None => widgets.osd_rating_label.set_visible(false),
    }
}

/// Drive the central status plate. We only show it for initial loading
/// and for terminal errors — seeking intentionally doesn't trigger it.
fn update_status_plate(
    widgets: &VideoPlayerWidgets,
    error_msg: Option<&str>,
    is_prepared: bool,
) {
    if let Some(msg) = error_msg {
        widgets.status_spinner.set_spinning(false);
        widgets.status_spinner.set_visible(false);
        widgets.status_icon.set_visible(true);
        widgets.status_title.set_label("Couldn't play video");
        widgets.status_detail.set_label(msg);
        widgets.status_detail.set_visible(true);
        widgets.status_plate.set_visible(true);
    } else if !is_prepared {
        widgets.status_icon.set_visible(false);
        widgets.status_spinner.set_visible(true);
        widgets.status_spinner.set_spinning(true);
        widgets.status_title.set_label("Loading video…");
        widgets.status_detail.set_visible(false);
        widgets.status_plate.set_visible(true);
    } else {
        widgets.status_plate.set_visible(false);
        widgets.status_spinner.set_spinning(false);
    }
}

fn is_player_shortcut(key: gtk::gdk::Key) -> bool {
    use gtk::gdk::Key;
    matches!(
        key,
        Key::space
            | Key::k
            | Key::K
            | Key::Left
            | Key::Right
            | Key::Up
            | Key::Down
            | Key::j
            | Key::J
            | Key::l
            | Key::L
            | Key::Home
            | Key::End
            | Key::m
            | Key::M
            | Key::_9
            | Key::_0
            | Key::f
            | Key::F
            | Key::Escape
    )
}

fn flash_center(image: &gtk::Image, playing: bool) {
    image.set_icon_name(Some(if playing {
        "media-playback-start-symbolic"
    } else {
        "media-playback-pause-symbolic"
    }));
    image.set_visible(true);
    image.remove_css_class("video-center-indicator-flash");
    image.add_css_class("video-center-indicator-flash");
    let weak = image.downgrade();
    glib::timeout_add_local_once(std::time::Duration::from_millis(550), move || {
        if let Some(img) = weak.upgrade() {
            img.set_visible(false);
            img.remove_css_class("video-center-indicator-flash");
        }
    });
}

fn format_us(us: i64) -> String {
    let total = (us.max(0) / 1_000_000) as u64;
    let h = total / 3600;
    let m = (total % 3600) / 60;
    let s = total % 60;
    if h > 0 {
        format!("{h}:{m:02}:{s:02}")
    } else {
        format!("{m}:{s:02}")
    }
}

fn volume_icon(muted: bool, volume: f64) -> &'static str {
    if muted || volume <= 0.001 {
        "audio-volume-muted-symbolic"
    } else if volume < 0.34 {
        "audio-volume-low-symbolic"
    } else if volume < 0.67 {
        "audio-volume-medium-symbolic"
    } else {
        "audio-volume-high-symbolic"
    }
}
