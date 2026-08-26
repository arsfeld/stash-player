//! GStreamer `playbin3` pipeline backing the video player.
//!
//! Behaves like `gtk::MediaFile` did: build with a URL, drive state with
//! `play`/`pause`, query timing in microseconds. Bus messages drive the
//! shared event flags and post a `Tick` to the widget so it refreshes.

use std::cell::{Cell, RefCell};
use std::rc::Rc;

use gst::prelude::*;
use gtk::glib;
use relm4::gtk;
use relm4::prelude::*;

use super::{VideoPlayer, VideoPlayerMsg};

/// Owned GStreamer pipeline driving a single stream.
///
/// Behaves like `gtk::MediaFile` did: build with a URL, set state
/// transitions via `play`/`pause`, query timing in microseconds, etc.
/// Bus messages drive event-flag transitions (`prepared`, `seeking`)
/// and post a `Tick` to the relm4 sender so the widget refreshes.
pub(super) struct PlaybackPipeline {
    pipeline: gst::Pipeline,
    playbin: gst::Element,
    paintable: gtk::gdk::Paintable,
    bus_watch: Option<gst::bus::BusWatchGuard>,
    prepared: Rc<Cell<bool>>,
    seeking: Rc<Cell<bool>>,
    playing: Rc<Cell<bool>>,
    error: Rc<RefCell<Option<String>>>,
}

impl PlaybackPipeline {
    pub(super) fn new(
        url: &str,
        autoplay: bool,
        sender: &ComponentSender<VideoPlayer>,
    ) -> Option<Self> {
        let playbin = make_element("playbin3")?;
        let sink = make_element("gtk4paintablesink")?;

        let paintable = sink.property::<gtk::gdk::Paintable>("paintable");
        playbin.set_property("video-sink", &sink);
        playbin.set_property("uri", url);

        let pipeline = gst::Pipeline::new();
        if let Err(e) = pipeline.add(&playbin) {
            tracing::warn!("failed to add playbin to pipeline: {e}");
            return None;
        }

        let prepared = Rc::new(Cell::new(false));
        let seeking = Rc::new(Cell::new(false));
        let playing = Rc::new(Cell::new(false));
        let error: Rc<RefCell<Option<String>>> = Rc::new(RefCell::new(None));

        let bus_watch = install_bus_watch(
            &pipeline,
            sender.clone(),
            BusFlags {
                prepared: prepared.clone(),
                seeking: seeking.clone(),
                playing: playing.clone(),
                error: error.clone(),
            },
        );

        // Drive directly to the user-visible target state. Going Null →
        // Paused → Playing as two separate set_state calls races the bus
        // watch and leaves `self.playing` stuck at false on autoplay.
        let target = if autoplay {
            gst::State::Playing
        } else {
            gst::State::Paused
        };
        if let Err(e) = pipeline.set_state(target) {
            tracing::warn!("failed to set pipeline to {target:?}: {e}");
        }

        Some(Self {
            pipeline,
            playbin,
            paintable,
            bus_watch,
            prepared,
            seeking,
            playing,
            error,
        })
    }

    pub(super) fn paintable(&self) -> &gtk::gdk::Paintable {
        &self.paintable
    }

    pub(super) fn play(&self) {
        let _ = self.pipeline.set_state(gst::State::Playing);
    }

    pub(super) fn pause(&self) {
        let _ = self.pipeline.set_state(gst::State::Paused);
    }

    pub(super) fn is_playing(&self) -> bool {
        self.playing.get()
    }

    pub(super) fn is_prepared(&self) -> bool {
        self.prepared.get()
    }

    pub(super) fn is_seeking(&self) -> bool {
        self.seeking.get()
    }

    pub(super) fn error_message(&self) -> Option<String> {
        self.error.borrow().clone()
    }

    pub(super) fn duration_us(&self) -> i64 {
        self.pipeline
            .query_duration::<gst::ClockTime>()
            .map(|t| t.useconds() as i64)
            .unwrap_or(0)
    }

    pub(super) fn position_us(&self) -> i64 {
        self.pipeline
            .query_position::<gst::ClockTime>()
            .map(|t| t.useconds() as i64)
            .unwrap_or(0)
    }

    pub(super) fn set_volume(&self, v: f64) {
        self.playbin.set_property("volume", v);
    }

    pub(super) fn volume(&self) -> f64 {
        self.playbin.property::<f64>("volume")
    }

    pub(super) fn set_muted(&self, m: bool) {
        self.playbin.set_property("mute", m);
    }

    pub(super) fn is_muted(&self) -> bool {
        self.playbin.property::<bool>("mute")
    }

    pub(super) fn seek(&self, target_us: i64) {
        if !self.prepared.get() {
            tracing::debug!(target_us, "seek skipped: pipeline not prepared");
            return;
        }
        let pos = gst::ClockTime::from_useconds(target_us.max(0) as u64);
        let was_seeking = self.seeking.get();
        let pre_position_us = self
            .pipeline
            .query_position::<gst::ClockTime>()
            .map(|t| t.useconds() as i64)
            .unwrap_or(-1);
        // KEY_UNIT | SNAP_BEFORE keeps the HTTP range request cheap by
        // landing on the keyframe at-or-before the target (one fetch,
        // smooth playback resumption). ACCURATE then asks the decoder to
        // chase forward from that keyframe to the exact requested frame
        // — without it, several rapid "+5s" nudges between two sparse
        // keyframes all land on the same earlier keyframe and the
        // playhead visibly stalls while the slider keeps jumping.
        let result = self.pipeline.seek_simple(
            gst::SeekFlags::FLUSH
                | gst::SeekFlags::KEY_UNIT
                | gst::SeekFlags::SNAP_BEFORE
                | gst::SeekFlags::ACCURATE,
            pos,
        );
        match result {
            Ok(()) => {
                tracing::debug!(
                    target_us,
                    pre_position_us,
                    was_seeking,
                    "seek submitted"
                );
            }
            Err(e) => {
                tracing::warn!(target_us, "seek failed: {e}");
            }
        }
    }
}

impl Drop for PlaybackPipeline {
    fn drop(&mut self) {
        if let Some(watch) = self.bus_watch.take() {
            // Dropping the guard removes the watch.
            drop(watch);
        }
        let _ = self.pipeline.set_state(gst::State::Null);
    }
}

/// Build a GStreamer element by factory name, logging on failure.
fn make_element(name: &str) -> Option<gst::Element> {
    match gst::ElementFactory::make(name).build() {
        Ok(el) => Some(el),
        Err(e) => {
            tracing::warn!("{name} unavailable: {e}");
            None
        }
    }
}

/// State flags shared between the bus watch and the owning `PlaybackPipeline`.
struct BusFlags {
    prepared: Rc<Cell<bool>>,
    seeking: Rc<Cell<bool>>,
    playing: Rc<Cell<bool>>,
    error: Rc<RefCell<Option<String>>>,
}

/// Wire up `pipeline`'s bus watch to drive the supplied flags and post a
/// `Tick` to the widget after every message.
fn install_bus_watch(
    pipeline: &gst::Pipeline,
    sender: ComponentSender<VideoPlayer>,
    flags: BusFlags,
) -> Option<gst::bus::BusWatchGuard> {
    let bus = pipeline.bus().expect("pipeline has a bus");
    let pipeline_weak = pipeline.downgrade();
    bus.add_watch_local(move |_, msg| {
        handle_bus_message(msg, &flags, &pipeline_weak);
        sender.input(VideoPlayerMsg::Tick);
        glib::ControlFlow::Continue
    })
    .ok()
}

fn handle_bus_message(
    msg: &gst::Message,
    flags: &BusFlags,
    pipeline_weak: &glib::WeakRef<gst::Pipeline>,
) {
    use gst::MessageView;
    match msg.view() {
        MessageView::Error(err) => {
            let glib_err = err.error();
            tracing::warn!(
                "gstreamer error from {:?}: {} ({:?})",
                err.src().map(|s| s.path_string()),
                glib_err,
                err.debug()
            );
            *flags.error.borrow_mut() = Some(glib_err.to_string());
            // An error means we'll never finish preparing; clear the
            // seeking flag so the loading overlay logic in the widget
            // can switch to the error state.
            flags.seeking.set(false);
        }
        MessageView::AsyncDone(_) => {
            let landed_us = pipeline_weak
                .upgrade()
                .and_then(|p| p.query_position::<gst::ClockTime>())
                .map(|t| t.useconds() as i64)
                .unwrap_or(-1);
            tracing::debug!(landed_us, "bus: AsyncDone — seek complete, prepared");
            flags.prepared.set(true);
            flags.seeking.set(false);
        }
        MessageView::AsyncStart(_) => {
            tracing::debug!("bus: AsyncStart — seek/preroll begin");
            flags.seeking.set(true);
        }
        MessageView::StateChanged(sc) => apply_state_change(sc, flags, pipeline_weak),
        MessageView::DurationChanged(_) | MessageView::Eos(_) => {}
        _ => {}
    }
}

fn apply_state_change(
    sc: &gst::message::StateChanged,
    flags: &BusFlags,
    pipeline_weak: &glib::WeakRef<gst::Pipeline>,
) {
    // Only the pipeline's own state changes are load-bearing; child
    // elements emit their own.
    let Some(pipe) = pipeline_weak.upgrade() else {
        return;
    };
    if !sc
        .src()
        .map(|s| s == pipe.upcast_ref::<gst::Object>())
        .unwrap_or(false)
    {
        return;
    }
    let current = sc.current();
    flags.playing.set(current == gst::State::Playing);
    if current == gst::State::Paused || current == gst::State::Playing {
        flags.prepared.set(true);
    } else if current == gst::State::Null || current == gst::State::Ready {
        flags.prepared.set(false);
    }
}
