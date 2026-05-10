//! Inline video player with a custom on-screen display.
//!
//! Wraps `gtk::Picture` + `gtk::MediaFile` (which is itself a GdkPaintable
//! and a GtkMediaStream) and lays a libadwaita-flavoured OSD on top: a seek
//! bar, transport buttons, time labels, a volume slider, and a fullscreen
//! toggle. Controls fade out after a short period of pointer / keyboard
//! inactivity, mpv-style.
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
//! Position polling runs at 4 Hz via `glib::timeout_add_local`. We avoid a
//! feedback loop on the seek slider by suppressing our own programmatic
//! updates with an `Rc<Cell<bool>>` flag — the user-driven `value-changed`
//! emits while the flag is clear go through `UserSeek`, which seeks the
//! underlying stream immediately.

use std::cell::Cell;
use std::rc::Rc;
use std::time::{Duration, Instant};

use gtk::glib;
use gtk::prelude::*;
use relm4::gtk;
use relm4::prelude::*;

const TICK_INTERVAL_MS: u32 = 250;
const HIDE_DELAY_MS: u32 = 2500;
/// Wall-clock minimum between activity checkpoints while playing. Matches
/// the cadence Stash's web UI uses.
const ACTIVITY_THROTTLE: Duration = Duration::from_secs(10);

#[derive(Debug, Default)]
pub struct VideoPlayerInit {
    pub url: Option<String>,
    /// Start playing as soon as a stream is loaded (initial URL and any
    /// later `SetUrl`).
    pub autoplay: bool,
    /// Saved resume position (seconds) for the initial URL. Applied once
    /// the stream is prepared, then forgotten.
    pub resume_secs: Option<f64>,
}

/// What the player tells the parent (the scene page) about playback.
#[derive(Debug)]
pub enum VideoPlayerOutput {
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
}

#[derive(Debug)]
pub enum VideoPlayerMsg {
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
}

pub struct VideoPlayer {
    media: Option<gtk::MediaFile>,
    url: Option<String>,
    duration_us: i64,
    position_us: i64,
    volume: f64,
    muted: bool,
    playing: bool,
    autoplay: bool,
    is_fullscreen: bool,
    /// Transient borderless window holding the player while in fullscreen.
    /// `None` outside fullscreen.
    fs_window: Option<gtk::Window>,
    /// Original parent of `root_box` to reparent back to on exit. Stored as
    /// the inline overlay we were embedded in.
    fs_original_parent: Option<gtk::Widget>,
    show_controls: bool,
    /// Latched copy of the most recently emitted reveal state. We diff
    /// against this in `update_with_view` so the parent only hears about
    /// real edge transitions, not every tick.
    controls_revealed: bool,
    hide_source: Option<glib::SourceId>,
    tick_source: Option<glib::SourceId>,
    /// Flag set while we update the seek scale programmatically so the
    /// `value-changed` handler can ignore our own writes.
    suppress_scale: Rc<Cell<bool>>,
    suppress_volume: Rc<Cell<bool>>,
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
}

#[relm4::component(pub)]
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
                        set_height_request: 540,
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

                // Buffering / loading spinner.
                add_overlay = &gtk::Box {
                    set_halign: gtk::Align::Center,
                    set_valign: gtk::Align::Center,
                    set_can_target: false,

                    #[name = "loading_spinner"]
                    gtk::Spinner {
                        set_spinning: true,
                        set_width_request: 48,
                        set_height_request: 48,
                        set_visible: false,
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

        let model = VideoPlayer {
            media: None,
            url: init.url.clone(),
            duration_us: 0,
            position_us: 0,
            volume: 1.0,
            muted: false,
            playing: false,
            autoplay: init.autoplay,
            is_fullscreen: false,
            fs_window: None,
            fs_original_parent: None,
            show_controls: true,
            controls_revealed: true,
            hide_source: None,
            tick_source: None,
            suppress_scale: suppress_scale.clone(),
            suppress_volume: suppress_volume.clone(),
            playing_since: None,
            play_duration_us: 0,
            last_save_at: None,
            resume_pending: None,
        };

        let widgets = view_output!();

        // Hook seek slider: only treat as a user seek when not suppressed.
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

        // Hook volume slider similarly.
        {
            let sender = sender.clone();
            let suppress = suppress_volume.clone();
            widgets.volume_scale.connect_value_changed(move |s| {
                if suppress.get() {
                    return;
                }
                sender.input(VideoPlayerMsg::SetVolume(s.value()));
            });
        }

        // Pointer motion → wake controls. Single click anywhere on the
        // surface toggles play/pause; double click toggles fullscreen.
        {
            let motion = gtk::EventControllerMotion::new();
            let sender_m = sender.clone();
            motion.connect_motion(move |_, _, _| {
                sender_m.input(VideoPlayerMsg::PointerActive);
            });
            widgets.stack_overlay.add_controller(motion);
        }

        {
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
            // Attach to the picture (not the controls bar) so clicks on
            // the OSD don't steal play/pause toggles.
            widgets.picture.add_controller(click);
        }

        // Keyboard shortcuts: capture phase so the slider (and any other
        // focused descendant) doesn't eat arrow keys before we see them.
        // Return `Stop` for keys we recognise so we don't double-handle
        // (e.g. focused seek slider + our own seek-by-5s).
        {
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

        let mut model = model;
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
                // Flush activity for the outgoing scene first so the
                // parent records its final resume + watched-time delta.
                if self.media.is_some() {
                    self.emit_checkpoint(&sender);
                }

                self.url = url.clone();
                self.duration_us = 0;
                self.position_us = 0;
                self.playing = false;
                self.playing_since = None;
                self.play_duration_us = 0;
                self.last_save_at = None;
                // Treat 0 (or negative) as "no saved resume" — Stash
                // returns 0 for unwatched scenes and we don't want to
                // re-seek to 0 every load.
                self.resume_pending = resume_secs.filter(|s| *s > 0.0);

                if let Some(url) = url {
                    let file = gtk::gio::File::for_uri(&url);
                    let media = gtk::MediaFile::for_file(&file);
                    media.set_loop(false);
                    media.set_volume(self.volume);
                    media.set_muted(self.muted);

                    // Refresh on prepared / duration / playing changes —
                    // they fire once, well after construction.
                    let s_prepared = sender.clone();
                    media.connect_prepared_notify(move |_| {
                        s_prepared.input(VideoPlayerMsg::Tick);
                    });
                    let s_dur = sender.clone();
                    media.connect_duration_notify(move |_| {
                        s_dur.input(VideoPlayerMsg::Tick);
                    });
                    let s_play = sender.clone();
                    media.connect_playing_notify(move |_| {
                        s_play.input(VideoPlayerMsg::Tick);
                    });
                    media.connect_error_notify(|m| {
                        if let Some(err) = m.error() {
                            tracing::warn!("media stream error: {err}");
                        }
                    });

                    widgets.picture.set_paintable(Some(&media));
                    if self.autoplay {
                        // GtkMediaFile queues the play action until the
                        // stream is prepared, so calling here is fine even
                        // before the prepared signal fires.
                        media.play();
                        self.playing = true;
                        self.playing_since = Some(Instant::now());
                    }
                    self.media = Some(media);
                    // Anchor the throttle so the first checkpoint fires
                    // 10s into playback, not on the very first tick.
                    self.last_save_at = Some(Instant::now());
                } else {
                    widgets.picture.set_paintable(gtk::gdk::Paintable::NONE);
                    self.media = None;
                }
            }

            VideoPlayerMsg::SetAutoplay(on) => {
                self.autoplay = on;
            }

            VideoPlayerMsg::Tick => {
                // Clone the MediaFile GObject ref so we can borrow self
                // mutably below (capture_play_time / emit_checkpoint).
                // GObject clones are cheap refcount bumps.
                if let Some(media) = self.media.clone() {
                    let was_playing = self.playing;
                    let now_playing = media.is_playing();

                    // Track playing-state transitions so play_duration_us
                    // reflects only the time the stream was actually
                    // playing (paused/seeking time doesn't count).
                    if !was_playing && now_playing {
                        if self.playing_since.is_none() {
                            self.playing_since = Some(Instant::now());
                        }
                    } else if was_playing && !now_playing {
                        self.capture_play_time();
                    }

                    self.duration_us = media.duration().max(0);
                    self.position_us = media.timestamp().max(0);
                    self.playing = now_playing;
                    self.volume = media.volume();
                    self.muted = media.is_muted();

                    // Apply the pending resume seek once the stream is
                    // ready enough that a clamp against duration is
                    // meaningful. duration() can be 0 right after
                    // prepared fires; the duration-notify signal also
                    // routes back through Tick so we'll catch it.
                    if media.is_prepared() && self.duration_us > 0
                        && let Some(resume) = self.resume_pending.take()
                    {
                        let target_us = (resume * 1_000_000.0) as i64;
                        let target = target_us.clamp(0, self.duration_us);
                        media.seek(target);
                        self.position_us = target;
                    }

                    // Throttled activity checkpoint while playing. The
                    // last_save_at anchor is set to "now" at SetUrl time,
                    // so the first save fires ~10s after a stream starts.
                    if now_playing {
                        let due = self
                            .last_save_at
                            .map(|t| t.elapsed() >= ACTIVITY_THROTTLE)
                            .unwrap_or(true);
                        if due {
                            self.emit_checkpoint(&sender);
                        }
                    }

                    // Show spinner while media is preparing or seeking
                    // and we have nothing to show yet.
                    let loading = !media.is_prepared() || media.is_seeking();
                    widgets.loading_spinner.set_visible(loading);
                }
            }

            VideoPlayerMsg::TogglePlay => {
                if let Some(media) = self.media.clone() {
                    let was_playing = media.is_playing();
                    if was_playing {
                        media.pause();
                        // User-initiated pause — flush a checkpoint so
                        // resume_time on Stash mirrors the spot they
                        // stopped at. emit_checkpoint also captures any
                        // play_duration accumulated since the last save.
                        self.emit_checkpoint(&sender);
                    } else {
                        media.play();
                        self.playing_since = Some(Instant::now());
                    }
                    self.playing = media.is_playing();
                    flash_center(&widgets.center_indicator, self.playing);
                    sender.input(VideoPlayerMsg::PointerActive);
                }
            }

            VideoPlayerMsg::SeekRelative(secs) => {
                if let Some(media) = &self.media {
                    if !media.is_prepared() {
                        return;
                    }
                    let delta = secs.saturating_mul(1_000_000);
                    let target = (media.timestamp().saturating_add(delta))
                        .clamp(0, media.duration().max(0));
                    media.seek(target);
                    self.position_us = target;
                    self.emit_checkpoint(&sender);
                    sender.input(VideoPlayerMsg::PointerActive);
                }
            }

            VideoPlayerMsg::SeekFraction(f) => {
                if let Some(media) = &self.media
                    && media.is_prepared()
                {
                    let dur = media.duration().max(0);
                    let target = ((dur as f64) * f.clamp(0.0, 1.0)) as i64;
                    media.seek(target);
                    self.position_us = target;
                    self.emit_checkpoint(&sender);
                    sender.input(VideoPlayerMsg::PointerActive);
                }
            }

            VideoPlayerMsg::UserSeek(us) => {
                if let Some(media) = &self.media
                    && media.is_prepared()
                {
                    let target = us.clamp(0, media.duration().max(0));
                    media.seek(target);
                    self.position_us = target;
                    self.emit_checkpoint(&sender);
                }
            }

            VideoPlayerMsg::SetVolume(v) => {
                let v = v.clamp(0.0, 1.0);
                self.volume = v;
                if let Some(media) = &self.media {
                    media.set_volume(v);
                    if v > 0.0 && media.is_muted() {
                        media.set_muted(false);
                        self.muted = false;
                    }
                }
            }

            VideoPlayerMsg::AdjustVolume(delta) => {
                let v = (self.volume + delta).clamp(0.0, 1.0);
                sender.input(VideoPlayerMsg::SetVolume(v));
                sender.input(VideoPlayerMsg::PointerActive);
            }

            VideoPlayerMsg::ToggleMute => {
                if let Some(media) = &self.media {
                    let new_muted = !media.is_muted();
                    media.set_muted(new_muted);
                    self.muted = new_muted;
                    sender.input(VideoPlayerMsg::PointerActive);
                }
            }

            VideoPlayerMsg::ToggleFullscreen => {
                if !self.is_fullscreen {
                    // Reparent the player into a transient borderless window
                    // so fullscreen covers only the video, not the rest of
                    // the app chrome. The root_box is removed from its
                    // current parent (an Overlay in the scene page) and
                    // reattached on exit.
                    if let Some(parent) = widgets.root_box.parent()
                        && let Some(overlay) = parent.downcast_ref::<gtk::Overlay>()
                    {
                        overlay.set_child(gtk::Widget::NONE);

                        let app_window =
                            widgets.root_box.root().and_downcast::<gtk::Window>();
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
                    }
                } else {
                    sender.input(VideoPlayerMsg::ExitFullscreen);
                }
            }

            VideoPlayerMsg::ExitFullscreen => {
                if self.is_fullscreen
                    && let Some(fs_window) = self.fs_window.take()
                {
                    // Detach from the fullscreen window before destroying so
                    // the widget survives, then reparent into the original
                    // overlay slot.
                    fs_window.set_child(gtk::Widget::NONE);
                    if let Some(overlay) = self
                        .fs_original_parent
                        .take()
                        .and_then(|p| p.downcast::<gtk::Overlay>().ok())
                    {
                        overlay.set_child(Some(&widgets.root_box));
                    }
                    fs_window.destroy();
                    self.is_fullscreen = false;
                }
            }

            VideoPlayerMsg::PointerActive => {
                self.show_controls = true;
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

            VideoPlayerMsg::HideControls => {
                self.hide_source = None;
                self.show_controls = false;
            }

            VideoPlayerMsg::KeyPressed(key, mods) => {
                let handled = self.handle_key(&sender, key, mods);
                if handled {
                    sender.input(VideoPlayerMsg::PointerActive);
                }
            }
        }

        // Notify the parent on reveal-state edges so it can fade the
        // floating header bar together with the OSD. Computed here (not
        // in `refresh_widgets`) because we need `&mut self` to latch the
        // last value, and emitting only on changes avoids spamming the
        // parent on every tick.
        let force_visible = self.media.is_none() || self.duration_us == 0;
        let revealed = self.show_controls || force_visible;
        if revealed != self.controls_revealed {
            self.controls_revealed = revealed;
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
        let resume_secs = self.position_us.max(0) as f64 / 1_000_000.0;
        let play_duration_secs = self.play_duration_us as f64 / 1_000_000.0;
        if self.media.is_some() && (play_duration_secs > 0.0 || resume_secs > 0.0) {
            let _ = output.send(VideoPlayerOutput::ActivityCheckpoint {
                resume_secs,
                play_duration_secs,
            });
        }
    }
}

impl VideoPlayer {
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
        let resume_secs = self.position_us.max(0) as f64 / 1_000_000.0;
        let play_duration_secs = self.play_duration_us as f64 / 1_000_000.0;
        self.play_duration_us = 0;
        self.last_save_at = Some(Instant::now());
        let _ = sender.output(VideoPlayerOutput::ActivityCheckpoint {
            resume_secs,
            play_duration_secs,
        });
        if self.playing {
            self.playing_since = Some(Instant::now());
        }
    }

    fn refresh_widgets(
        &self,
        widgets: &<Self as Component>::Widgets,
        _root: &<Self as Component>::Root,
    ) {
        // Seek slider: max = duration, value = position. Clamp to a tiny
        // positive max to avoid GtkRange complaining when duration is 0.
        // Skip pushing values while the stream is mid-seek — the polled
        // timestamp lags the user's drag and would yank the thumb back.
        let media_seeking = self.media.as_ref().is_some_and(|m| m.is_seeking());
        let max = (self.duration_us.max(1)) as f64;
        widgets.seek_scale.set_range(0.0, max);
        if !media_seeking {
            let pos = (self.position_us.clamp(0, self.duration_us.max(0))) as f64;
            self.suppress_scale.set(true);
            widgets.seek_scale.set_value(pos);
            self.suppress_scale.set(false);
        }
        widgets.seek_scale.set_sensitive(self.duration_us > 0);

        widgets
            .position_label
            .set_label(&format_us(self.position_us));
        let duration_text = if self.duration_us > 0 {
            format_us(self.duration_us)
        } else {
            "--:--".into()
        };
        widgets.duration_label.set_label(&duration_text);

        // Play / pause icon.
        widgets.play_button.set_icon_name(if self.playing {
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

        // OSD visibility: stay up only when no media is loaded yet so the
        // user has something to look at; otherwise let the inactivity timer
        // hide it whether playing or paused. `controls_revealed` was
        // computed (and emitted upward) in `update_with_view`.
        widgets.controls_revealer.set_reveal_child(self.controls_revealed);

        // Cursor: hide on the player widget when controls are hidden so
        // the OSD "gets out of the way". Scoped to the widget (not the
        // toplevel surface) so the rest of the page keeps a normal
        // pointer.
        let cursor = if self.controls_revealed {
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
