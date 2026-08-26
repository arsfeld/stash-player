//! Library page — paged grid of scenes. Lazy-loads thumbnails on the GTK
//! main loop after fetching their bytes off-thread.

use std::cell::RefCell;
use std::collections::HashMap;
use std::rc::Rc;
use std::sync::Arc;

use relm4::prelude::*;
use relm4::{adw, gtk};

use adw::prelude::*;
use gtk::glib;
use tokio::sync::Semaphore;

use stash_api::{FindScenesPage, Job, JobStatus, Scene, SceneFilter, SortDirection, SortKey};

/// Stash's rating100 increments per "star" — 1 ★ = 20, 5 ★ = 100. The min-rating
/// dropdown indexes into this list (index 0 == no filter).
const MIN_RATING_OPTIONS: &[(&str, Option<i32>)] = &[
    ("Any rating", None),
    ("1+ stars", Some(20)),
    ("2+ stars", Some(40)),
    ("3+ stars", Some(60)),
    ("4+ stars", Some(80)),
    ("5 stars", Some(100)),
];

const PAGE_SIZE: u32 = 48;
/// How many viewport-heights of not-yet-scrolled content to keep loaded
/// ahead of the user.
const PREFETCH_VIEWPORTS: f64 = 1.5;
/// Cap concurrent thumbnail fetches so we don't open a connection per scene
/// the moment a page lands. 12 keeps the pipe full without thrashing reqwest's
/// per-host pool (default 10) too hard.
const MAX_PARALLEL_THUMBS: usize = 12;
const CARD_WIDTH: i32 = 240;
const THUMB_WIDTH: i32 = CARD_WIDTH;
const THUMB_HEIGHT: i32 = 135;
const THUMB_BYTES: usize = (THUMB_WIDTH as usize) * (THUMB_HEIGHT as usize) * 4;

#[derive(Debug)]
pub(crate) struct LibraryInit {
    pub(crate) client: Option<stash_api::Client>,
    /// Initial value of the "Hide interactive" toolbar toggle, sourced from
    /// `Config::hide_interactive` so the choice persists across launches.
    pub(crate) hide_interactive: bool,
}

pub(crate) struct LibraryPage {
    client: Option<stash_api::Client>,
    filter: SceneFilter,
    page: u32,
    total: i64,
    loaded: u32,
    loading: bool,
    /// Set once the server returns a short page — there is nothing left
    /// to fetch for the current filter, whatever `total` claims.
    exhausted: bool,
    error: Option<String>,
    /// Pictures keyed by scene id so the async thumbnail handler can
    /// patch the right cell when the bytes arrive.
    cells: Rc<RefCell<HashMap<String, gtk::Picture>>>,
    /// Scene ids in the order they appear in the FlowBox, so the activation
    /// handler can resolve `FlowBoxChild::index()` back to a scene id without
    /// stashing user data on the child via gtk-rs's unsafe `set_data` API.
    scene_ids: Rc<RefCell<Vec<String>>>,
    fetch_sem: Arc<Semaphore>,
    /// Server-side jobs the user cares about (scan, generate, etc.).
    active_jobs: Vec<Job>,
    /// Handle for the periodic job-poll timer. `None` when not polling.
    job_poll_handle: Option<glib::SourceId>,
    /// Guards against double-scan — true while a metadataScan is in flight.
    scanning: bool,
}

#[derive(Debug)]
pub(crate) enum LibraryMsg {
    SetClient(stash_api::Client),
    Refresh,
    LoadMore,
    /// Re-evaluate whether another page is needed, based on how much
    /// unscrolled content is left. Cheap and idempotent.
    MaybeLoadMore,
    SearchChanged(String),
    SortKeyChanged(u32),
    SetDirection(SortDirection),
    OrganizedChanged(bool),
    MinRatingChanged(u32),
    HideTrackedChanged(bool),
    HideInteractiveChanged(bool),
    ChildActivatedAt(u32),
    OpenSettings,
    PlayRandom,
    StartScan,
    ShowTasks,
    PollJobs,
    TasksPopoverClosed,
    ClearJobs,
}

pub(crate) enum LibraryCmd {
    Page(Result<FindScenesPage, String>),
    Random(Result<Box<RandomPick>, String>),
    Thumbnail(Box<ThumbnailPayload>),
    ScanTriggered(Result<String, String>),
    JobsFetched(Result<Vec<Job>, String>),
}

pub(crate) struct ThumbnailPayload {
    pub(crate) scene_id: String,
    pub(crate) rgba: Vec<u8>,
    pub(crate) width: u32,
    pub(crate) height: u32,
}

pub(crate) struct RandomPick {
    pub(crate) scene: Option<Scene>,
    pub(crate) total: i64,
    pub(crate) filter: SceneFilter,
}

impl std::fmt::Debug for LibraryCmd {
    // Custom impl so a thumbnail's raw bytes don't flood tracing logs at
    // debug level — just print the dimensions.
    fn fmt(&self, f: &mut std::fmt::Formatter<'_>) -> std::fmt::Result {
        match self {
            LibraryCmd::Page(res) => f.debug_tuple("Page").field(res).finish(),
            LibraryCmd::Random(res) => f
                .debug_tuple("Random")
                .field(&res.as_ref().map(|p| p.scene.as_ref().map(|s| &s.id)))
                .finish(),
            LibraryCmd::Thumbnail(payload) => f
                .debug_struct("Thumbnail")
                .field("scene_id", &payload.scene_id)
                .field(
                    "size",
                    &format_args!("{}x{}", payload.width, payload.height),
                )
                .finish(),
            LibraryCmd::ScanTriggered(res) => f.debug_tuple("ScanTriggered").field(res).finish(),
            LibraryCmd::JobsFetched(res) => f
                .debug_tuple("JobsFetched")
                .field(&res.as_ref().map(|js| js.len()))
                .finish(),
        }
    }
}

#[derive(Debug)]
pub(crate) enum LibraryOutput {
    OpenSettings,
    OpenScene {
        id: String,
        /// 0-based position in the current filter result.
        index: u32,
        /// Snapshot of the filter (with stable random seed) so the scene
        /// page can fetch neighbors in the same order.
        filter: SceneFilter,
        /// Total scenes matching `filter`. Negative means unknown.
        total: i64,
    },
    /// User flipped the "Hide interactive" toggle; the parent persists it
    /// to `Config` so the choice survives restarts.
    HideInteractiveChanged(bool),
}

#[relm4::component(pub)]
impl Component for LibraryPage {
    type Init = LibraryInit;
    type Input = LibraryMsg;
    type Output = LibraryOutput;
    type CommandOutput = LibraryCmd;

    view! {
        adw::NavigationPage {
            set_title: "Library",
            set_tag: Some("library"),

            #[wrap(Some)]
            set_child = &gtk::Box {
                set_orientation: gtk::Orientation::Vertical,
                set_hexpand: true,
                set_vexpand: true,

                adw::ToolbarView {
                    add_top_bar = &adw::HeaderBar {
                    pack_start = &gtk::Box {
                        set_spacing: 6,

                        gtk::Button {
                            set_icon_name: "view-refresh-symbolic",
                            set_tooltip_text: Some("Refresh scene list"),
                            #[watch]
                            set_sensitive: model.client.is_some(),
                            connect_clicked => LibraryMsg::Refresh,
                        },

                        gtk::Separator {
                            set_orientation: gtk::Orientation::Vertical,
                            set_margin_start: 6,
                            set_margin_end: 6,
                        },

                        gtk::Button {
                            set_icon_name: "media-playlist-shuffle-symbolic",
                            set_tooltip_text: Some("Play random scene"),
                            #[watch]
                            set_sensitive: model.client.is_some(),
                            connect_clicked => LibraryMsg::PlayRandom,
                        },
                    },

                    #[name = "tasks_btn"]
                    pack_end = &gtk::Button {
                        set_icon_name: "view-list-symbolic",
                        set_tooltip_text: Some("Background tasks"),
                        #[watch]
                        set_sensitive: model.client.is_some(),
                        connect_clicked => LibraryMsg::ShowTasks,
                    },

                    #[name = "menu_btn"]
                    pack_end = &gtk::MenuButton {
                        set_icon_name: "open-menu-symbolic",
                        set_tooltip_text: Some("Main menu"),
                        set_direction: gtk::ArrowType::None,

                        #[wrap(Some)]
                        set_popover = &gtk::Popover {
                            #[wrap(Some)]
                            set_child = &gtk::Box {
                                set_orientation: gtk::Orientation::Vertical,
                                set_spacing: 0,
                                set_margin_start: 6,
                                set_margin_end: 6,
                                set_margin_top: 6,
                                set_margin_bottom: 6,

                                #[name = "menu_scan_btn"]
                                gtk::Button {
                                    set_label: "Re-scan library",
                                    set_halign: gtk::Align::Fill,
                                    add_css_class: "flat",
                                    #[watch]
                                    set_sensitive: model.client.is_some(),
                                    connect_clicked => LibraryMsg::StartScan,
                                },

                                gtk::Button {
                                    set_label: "Settings",
                                    set_halign: gtk::Align::Fill,
                                    add_css_class: "flat",
                                    connect_clicked => LibraryMsg::OpenSettings,
                                },
                            },
                        },
                    },

                    #[wrap(Some)]
                    set_title_widget = &gtk::SearchEntry {
                        set_placeholder_text: Some("Search scenes…"),
                        set_width_request: 360,
                        connect_search_changed[sender] => move |entry| {
                            sender.input(LibraryMsg::SearchChanged(entry.text().to_string()));
                        },
                    },
                },

                add_top_bar = &gtk::Box {
                    add_css_class: "toolbar",
                    set_spacing: 6,

                    gtk::Label {
                        set_label: "Sort by",
                        add_css_class: "dim-label",
                    },

                    gtk::DropDown {
                        set_model: Some(&sort_string_list()),
                        set_selected: model.sort_index() as u32,
                        connect_selected_notify[sender] => move |dd| {
                            sender.input(LibraryMsg::SortKeyChanged(dd.selected()));
                        },
                    },

                    gtk::Box {
                        add_css_class: "linked",

                        #[name = "dir_asc_btn"]
                        gtk::ToggleButton {
                            set_icon_name: "view-sort-ascending-symbolic",
                            set_tooltip_text: Some("Ascending"),
                            #[watch]
                            set_active: model.filter.direction == SortDirection::Asc,
                            connect_toggled[sender] => move |btn| {
                                if btn.is_active() {
                                    sender.input(LibraryMsg::SetDirection(SortDirection::Asc));
                                }
                            },
                        },

                        gtk::ToggleButton {
                            set_icon_name: "view-sort-descending-symbolic",
                            set_tooltip_text: Some("Descending"),
                            set_group: Some(&dir_asc_btn),
                            #[watch]
                            set_active: model.filter.direction == SortDirection::Desc,
                            connect_toggled[sender] => move |btn| {
                                if btn.is_active() {
                                    sender.input(LibraryMsg::SetDirection(SortDirection::Desc));
                                }
                            },
                        },
                    },

                    gtk::Separator {
                        set_orientation: gtk::Orientation::Vertical,
                        set_margin_start: 6,
                        set_margin_end: 6,
                    },

                    gtk::Switch {
                        set_valign: gtk::Align::Center,
                        set_tooltip_text: Some("Show only organized scenes"),
                        #[watch]
                        set_active: model.filter.organized.unwrap_or(false),
                        connect_active_notify[sender] => move |sw| {
                            sender.input(LibraryMsg::OrganizedChanged(sw.is_active()));
                        },
                    },

                    gtk::Label {
                        set_label: "Organized",
                    },

                    gtk::Separator {
                        set_orientation: gtk::Orientation::Vertical,
                        set_margin_start: 6,
                        set_margin_end: 6,
                    },

                    gtk::Label {
                        set_label: "Min rating",
                        add_css_class: "dim-label",
                    },

                    gtk::DropDown {
                        set_model: Some(&rating_string_list()),
                        set_selected: model.rating_index() as u32,
                        connect_selected_notify[sender] => move |dd| {
                            sender.input(LibraryMsg::MinRatingChanged(dd.selected()));
                        },
                    },

                    gtk::Separator {
                        set_orientation: gtk::Orientation::Vertical,
                        set_margin_start: 6,
                        set_margin_end: 6,
                    },

                    gtk::Switch {
                        set_valign: gtk::Align::Center,
                        set_tooltip_text: Some("Show only scenes with O-counter = 0"),
                        #[watch]
                        set_active: model.filter.hide_tracked,
                        connect_active_notify[sender] => move |sw| {
                            sender.input(LibraryMsg::HideTrackedChanged(sw.is_active()));
                        },
                    },

                    gtk::Image {
                        set_icon_name: Some("o-counter-symbolic"),
                        set_pixel_size: 16,
                        set_tooltip_text: Some("O-counter filter"),
                    },

                    gtk::Separator {
                        set_orientation: gtk::Orientation::Vertical,
                        set_margin_start: 6,
                        set_margin_end: 6,
                    },

                    gtk::Switch {
                        set_valign: gtk::Align::Center,
                        set_tooltip_text: Some("Hide scenes flagged as interactive (funscript)"),
                        #[watch]
                        set_active: model.filter.interactive == Some(false),
                        connect_active_notify[sender] => move |sw| {
                            sender.input(LibraryMsg::HideInteractiveChanged(sw.is_active()));
                        },
                    },

                    gtk::Label {
                        set_label: "Hide interactive",
                    },
                },

                #[wrap(Some)]
                set_content = &gtk::Stack {
                    set_transition_type: gtk::StackTransitionType::Crossfade,

                    add_named[Some("empty")] = &adw::StatusPage {
                        set_icon_name: Some("network-server-symbolic"),
                        set_title: "No server configured",
                        set_description: Some("Add your Stash server URL in settings."),

                        #[wrap(Some)]
                        set_child = &gtk::Button {
                            set_label: "Open settings",
                            set_halign: gtk::Align::Center,
                            add_css_class: "suggested-action",
                            add_css_class: "pill",
                            connect_clicked => LibraryMsg::OpenSettings,
                        },
                    },

                    add_named[Some("loading")] = &adw::StatusPage {
                        set_title: "Loading…",
                        #[wrap(Some)]
                        set_child = &gtk::Spinner {
                            set_spinning: true,
                            set_width_request: 32,
                            set_height_request: 32,
                        },
                    },

                    add_named[Some("error")] = &adw::StatusPage {
                        set_icon_name: Some("dialog-error-symbolic"),
                        set_title: "Couldn't load scenes",
                        #[watch]
                        set_description: model.error.as_deref(),

                        #[wrap(Some)]
                        set_child = &gtk::Button {
                            set_label: "Retry",
                            set_halign: gtk::Align::Center,
                            add_css_class: "pill",
                            connect_clicked => LibraryMsg::Refresh,
                        },
                    },

                    #[name = "scroller"]
                    add_named[Some("grid")] = &gtk::ScrolledWindow {
                        set_hscrollbar_policy: gtk::PolicyType::Never,

                        gtk::Box {
                            set_orientation: gtk::Orientation::Vertical,

                            #[name = "grid"]
                            gtk::FlowBox {
                                set_margin_top: 18,
                                set_margin_bottom: 6,
                                set_margin_start: 18,
                                set_margin_end: 18,
                                set_row_spacing: 18,
                                set_column_spacing: 18,
                                set_homogeneous: false,
                                set_min_children_per_line: 1,
                                set_max_children_per_line: 12,
                                set_selection_mode: gtk::SelectionMode::None,
                                set_valign: gtk::Align::Start,
                                set_halign: gtk::Align::Center,

                                connect_child_activated[sender] => move |_, child| {
                                    let position = child.index();
                                    if position >= 0 {
                                        sender.input(LibraryMsg::ChildActivatedAt(position as u32));
                                    }
                                },
                            },

                            #[name = "load_more_spinner"]
                            gtk::Spinner {
                                set_halign: gtk::Align::Center,
                                set_width_request: 28,
                                set_height_request: 28,
                                set_margin_top: 8,
                                set_margin_bottom: 24,
                                #[watch]
                                set_spinning: model.is_loading_more(),
                                #[watch]
                                set_visible: model.is_loading_more(),
                            },
                        },
                    },

                    #[watch]
                    set_visible_child_name: model.stack_name(),
                },
            },

            #[name = "tasks_popover"]
            gtk::Popover {
                set_autohide: true,
                set_position: gtk::PositionType::Bottom,
                set_width_request: 300,
                connect_closed => LibraryMsg::TasksPopoverClosed,

                #[wrap(Some)]
                set_child = &gtk::Box {
                    set_orientation: gtk::Orientation::Vertical,
                    set_spacing: 6,
                    set_margin_start: 12,
                    set_margin_end: 12,
                    set_margin_top: 12,
                    set_margin_bottom: 12,

                    gtk::Label {
                        set_label: "Tasks",
                        set_halign: gtk::Align::Start,
                        add_css_class: "heading",
                    },

                    gtk::Separator {
                        set_orientation: gtk::Orientation::Horizontal,
                    },

                    #[name = "job_list"]
                    gtk::Box {
                        set_orientation: gtk::Orientation::Vertical,
                        set_spacing: 4,
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
        let model = LibraryPage {
            client: init.client,
            // Default view: untracked-only. The user can toggle this off
            // from the toolbar; we don't persist the choice across launches.
            // `hide_interactive` IS persisted via Config — collapse the
            // boolean into the wire-format `Option<bool>` (Some(false) keeps
            // only non-interactive scenes; None doesn't filter).
            filter: SceneFilter {
                hide_tracked: true,
                interactive: if init.hide_interactive { Some(false) } else { None },
                ..SceneFilter::new()
            },
            page: 0,
            total: 0,
            loaded: 0,
            loading: false,
            exhausted: false,
            error: None,
            cells: Rc::new(RefCell::new(HashMap::new())),
            scene_ids: Rc::new(RefCell::new(Vec::new())),
            fetch_sem: Arc::new(Semaphore::new(MAX_PARALLEL_THUMBS)),
            active_jobs: Vec::new(),
            job_poll_handle: None,
            scanning: false,
        };

        let widgets = view_output!();

        widgets
            .tasks_popover
            .set_parent(&widgets.tasks_btn);

        // Scroll-driven prefetch. This replaces `edge-reached`, which
        // never fires when the content already fits the viewport.
        //
        // Both signals are needed, not just one: `value-changed` fires when
        // the user scrolls, but not when the *layout* settles after a page
        // lands — if the deferred idle check in `update_cmd_with_view` runs
        // before the scroller has been through its first size-allocate
        // (adjustment still all zeros), nothing else ever re-checks, and the
        // grid can stall at page 1 forever — the original bug via a
        // different path. `changed` fires exactly when `upper`/`page-size`
        // change (layout settling or content growing), so it catches that
        // case; `value-changed` still covers actual scrolling.
        {
            let sender = sender.clone();
            widgets
                .scroller
                .vadjustment()
                .connect_value_changed(move |_| {
                    sender.input(LibraryMsg::MaybeLoadMore);
                });
        }
        {
            let sender = sender.clone();
            widgets.scroller.vadjustment().connect_changed(move |_| {
                sender.input(LibraryMsg::MaybeLoadMore);
            });
        }

        if model.client.is_some() {
            sender.input(LibraryMsg::Refresh);
        }

        ComponentParts { model, widgets }
    }

    fn update_with_view(
        &mut self,
        widgets: &mut Self::Widgets,
        msg: LibraryMsg,
        sender: ComponentSender<Self>,
        _root: &Self::Root,
    ) {
        match msg {
            LibraryMsg::SetClient(client) => {
                self.client = Some(client);
                self.reset(widgets);
                self.fetch_next_page(&sender);
            }
            LibraryMsg::Refresh => {
                self.reset(widgets);
                self.fetch_next_page(&sender);
            }
            LibraryMsg::LoadMore => {
                if !self.loading
                    && !self.exhausted
                    && self.client.is_some()
                    && (self.total == 0 || self.loaded < self.total as u32)
                {
                    self.fetch_next_page(&sender);
                }
            }
            LibraryMsg::MaybeLoadMore => {
                if should_load_more(&widgets.scroller.vadjustment()) {
                    sender.input(LibraryMsg::LoadMore);
                }
            }
            LibraryMsg::SearchChanged(q) => {
                self.filter.query = if q.is_empty() { None } else { Some(q) };
                self.reset(widgets);
                self.fetch_next_page(&sender);
            }
            LibraryMsg::SortKeyChanged(index) => {
                if let Some(key) = SortKey::ALL.get(index as usize).copied()
                    && key != self.filter.sort
                {
                    self.filter.sort = key;
                    // Drop any previous seed so reset() picks the right
                    // seed-or-no-seed for the new sort key.
                    self.filter.random_seed = None;
                    self.reset(widgets);
                    self.fetch_next_page(&sender);
                }
            }
            LibraryMsg::SetDirection(dir) => {
                if dir != self.filter.direction {
                    self.filter.direction = dir;
                    self.reset(widgets);
                    self.fetch_next_page(&sender);
                }
            }
            LibraryMsg::OrganizedChanged(active) => {
                let new_value = if active { Some(true) } else { None };
                if new_value != self.filter.organized {
                    self.filter.organized = new_value;
                    self.reset(widgets);
                    self.fetch_next_page(&sender);
                }
            }
            LibraryMsg::MinRatingChanged(index) => {
                let new_value = MIN_RATING_OPTIONS
                    .get(index as usize)
                    .and_then(|(_, v)| *v);
                if new_value != self.filter.min_rating {
                    self.filter.min_rating = new_value;
                    self.reset(widgets);
                    self.fetch_next_page(&sender);
                }
            }
            LibraryMsg::HideTrackedChanged(active) => {
                if active != self.filter.hide_tracked {
                    self.filter.hide_tracked = active;
                    self.reset(widgets);
                    self.fetch_next_page(&sender);
                }
            }
            LibraryMsg::HideInteractiveChanged(active) => {
                // `Some(false)` excludes interactive scenes; `None` means no
                // filter. Match the binary toolbar control to that shape.
                let new_value = if active { Some(false) } else { None };
                if new_value != self.filter.interactive {
                    self.filter.interactive = new_value;
                    self.reset(widgets);
                    self.fetch_next_page(&sender);
                    let _ = sender.output(LibraryOutput::HideInteractiveChanged(active));
                }
            }
            LibraryMsg::ChildActivatedAt(index) => self.open_scene_at(widgets, &sender, index),
            LibraryMsg::OpenSettings => {
                let _ = sender.output(LibraryOutput::OpenSettings);
            }
            LibraryMsg::PlayRandom => self.spawn_play_random(&sender),
            LibraryMsg::StartScan => self.start_scan(widgets, &sender),
            LibraryMsg::ShowTasks => self.show_tasks(widgets, &sender),
            LibraryMsg::PollJobs => self.poll_jobs(&sender),
            LibraryMsg::TasksPopoverClosed => {
                if !self.scanning {
                    self.stop_job_polling();
                }
            }
            LibraryMsg::ClearJobs => {
                self.active_jobs.clear();
                self.rebuild_job_list(widgets);
            }
        }
        self.update_view(widgets, sender);
    }

    fn update_cmd_with_view(
        &mut self,
        widgets: &mut Self::Widgets,
        msg: LibraryCmd,
        sender: ComponentSender<Self>,
        _root: &Self::Root,
    ) {
        match msg {
            LibraryCmd::Page(Ok(page)) => {
                self.loading = false;
                self.error = None;
                self.total = page.count;
                let start_index = self.loaded;
                let count = page.scenes.len() as u32;
                for (i, scene) in page.scenes.into_iter().enumerate() {
                    self.append_cell(widgets, scene, start_index + i as u32, &sender);
                }
                self.loaded = start_index + count;
                // A short page means the result set is done, whatever
                // `count` claims — this is what stops the fill loop if
                // the server over-reports its total.
                if count < PAGE_SIZE {
                    self.exhausted = true;
                }
                // The adjustment still holds pre-layout values right
                // after appending children, so defer the check by one
                // main-loop iteration.
                let tx = sender.input_sender().clone();
                glib::idle_add_local_once(move || {
                    let _ = tx.send(LibraryMsg::MaybeLoadMore);
                });
            }
            LibraryCmd::Page(Err(e)) => {
                self.loading = false;
                self.error = Some(e);
            }
            LibraryCmd::Random(Ok(pick)) => {
                let RandomPick { scene, total, filter } = *pick;
                if let Some(scene) = scene {
                    let _ = sender.output(LibraryOutput::OpenScene {
                        id: scene.id,
                        index: 0,
                        filter,
                        total,
                    });
                } else {
                    tracing::debug!("play random: no scenes match current filter");
                }
            }
            LibraryCmd::Random(Err(e)) => {
                tracing::warn!("play random failed: {e}");
            }
            LibraryCmd::Thumbnail(payload) => {
                let ThumbnailPayload {
                    scene_id,
                    rgba,
                    width,
                    height,
                } = *payload;
                if rgba.is_empty() {
                    return;
                }
                if let Some(picture) = self.cells.borrow().get(&scene_id) {
                    let bytes = glib::Bytes::from_owned(rgba);
                    let texture = gtk::gdk::MemoryTexture::new(
                        width as i32,
                        height as i32,
                        gtk::gdk::MemoryFormat::R8g8b8a8,
                        &bytes,
                        (width * 4) as usize,
                    );
                    picture.set_paintable(Some(&texture));
                }
            }
            LibraryCmd::ScanTriggered(Ok(_job_id)) => {
                self.scanning = false;
            }
            LibraryCmd::ScanTriggered(Err(e)) => self.handle_scan_error(widgets, e),
            LibraryCmd::JobsFetched(Ok(jobs)) => self.handle_jobs_fetched(widgets, &sender, jobs),
            LibraryCmd::JobsFetched(Err(e)) => {
                tracing::warn!("jobs query failed: {e}");
            }
        }
        self.update_view(widgets, sender);
    }
}

impl LibraryPage {
    fn reset(&mut self, widgets: &<Self as Component>::Widgets) {
        self.page = 0;
        self.total = 0;
        self.loaded = 0;
        self.exhausted = false;
        self.error = None;
        self.cells.borrow_mut().clear();
        self.scene_ids.borrow_mut().clear();
        // FlowBox::remove_all is the cleanest way to drop every child.
        widgets.grid.remove_all();
        // Reseed shuffle each time the result set is reloaded so a fresh
        // random order is shown — and so that order stays stable across the
        // pagination + scene-page neighbor lookups that follow.
        self.filter.random_seed = if self.filter.sort == SortKey::Random {
            Some(fresh_seed())
        } else {
            None
        };
    }

    fn spawn_play_random(&self, sender: &ComponentSender<Self>) {
        let Some(client) = self.client.clone() else { return };
        let mut filter = self.filter.clone();
        filter.sort = SortKey::Random;
        // Always reseed so each click produces a fresh order.
        filter.random_seed = Some(fresh_seed());
        let req_filter = filter.clone();
        sender.oneshot_command(async move {
            let result = client
                .find_scenes(&req_filter, 1, 1)
                .await
                .map(|p| {
                    Box::new(RandomPick {
                        scene: p.scenes.into_iter().next(),
                        total: p.count,
                        filter: req_filter,
                    })
                })
                .map_err(|e| e.to_string());
            LibraryCmd::Random(result)
        });
    }

    fn fetch_next_page(&mut self, sender: &ComponentSender<Self>) {
        let Some(client) = self.client.clone() else { return };
        if self.loading {
            return;
        }
        self.loading = true;
        self.page += 1;
        let filter = self.filter.clone();
        let page = self.page;
        tracing::debug!("fetching scenes page {page}");
        sender.oneshot_command(async move {
            let result = client.find_scenes(&filter, page, PAGE_SIZE).await;
            match &result {
                Ok(p) => tracing::debug!("got {} scenes (total {})", p.scenes.len(), p.count),
                Err(e) => tracing::warn!("find_scenes failed: {e}"),
            }
            LibraryCmd::Page(result.map_err(|e| e.to_string()))
        });
    }

    fn rebuild_job_list(&self, widgets: &<Self as Component>::Widgets) {
        let container = widgets.job_list.clone();
        // Remove all existing children.
        while let Some(child) = container.first_child() {
            container.remove(&child);
        }

        if self.active_jobs.is_empty() {
            let placeholder = gtk::Label::builder()
                .label("No active tasks")
                .css_classes(["dim-label"])
                .halign(gtk::Align::Start)
                .margin_top(4)
                .build();
            container.append(&placeholder);
            return;
        }

        for job in &self.active_jobs {
            let row = gtk::Box::builder()
                .orientation(gtk::Orientation::Horizontal)
                .spacing(8)
                .margin_top(4)
                .build();

            let (icon_name, spinning) = match job.status {
                JobStatus::Running | JobStatus::Ready => ("content-loading-symbolic", true),
                JobStatus::Finished => ("emblem-ok-symbolic", false),
                JobStatus::Cancelled | JobStatus::Failed => ("dialog-error-symbolic", false),
            };

            if spinning {
                let spinner = gtk::Spinner::builder()
                    .spinning(true)
                    .width_request(16)
                    .height_request(16)
                    .build();
                row.append(&spinner);
            } else {
                let icon = gtk::Image::builder()
                    .icon_name(icon_name)
                    .pixel_size(16)
                    .build();
                row.append(&icon);
            }

            let info_box = gtk::Box::builder()
                .orientation(gtk::Orientation::Vertical)
                .spacing(2)
                .hexpand(true)
                .build();

            let desc_label = gtk::Label::builder()
                .label(&job.description)
                .halign(gtk::Align::Start)
                .wrap(true)
                .wrap_mode(gtk::pango::WrapMode::WordChar)
                .xalign(0.0)
                .build();
            info_box.append(&desc_label);

            if let Some(progress) = job.progress
                && progress > 0.0
            {
                let bar = gtk::ProgressBar::builder()
                    .fraction(progress)
                    .show_text(false)
                    .margin_top(2)
                    .build();
                info_box.append(&bar);
            }

            row.append(&info_box);
            container.append(&row);
        }
    }

    fn start_job_polling(&mut self, sender: &ComponentSender<Self>) {
        self.stop_job_polling();
        let tx = sender.input_sender().clone();
        let handle = glib::timeout_add_local(std::time::Duration::from_secs(2), move || {
            let _ = tx.send(LibraryMsg::PollJobs);
            glib::ControlFlow::Continue
        });
        self.job_poll_handle = Some(handle);
    }

    fn stop_job_polling(&mut self) {
        if let Some(handle) = self.job_poll_handle.take() {
            handle.remove();
        }
    }

    fn show_tasks(
        &mut self,
        widgets: &<Self as Component>::Widgets,
        sender: &ComponentSender<Self>,
    ) {
        self.poll_jobs(sender);
        self.start_job_polling(sender);
        widgets.tasks_popover.popup();
    }

    fn start_scan(
        &mut self,
        widgets: &<Self as Component>::Widgets,
        sender: &ComponentSender<Self>,
    ) {
        // Close the primary menu popover — it's still open when this
        // handler fires from the "Re-scan library" menu item.
        widgets.menu_btn.popdown();

        if self.scanning {
            return;
        }
        let Some(client) = self.client.clone() else {
            return;
        };
        self.scanning = true;
        self.active_jobs.clear();
        // Show a synthetic entry immediately so the user sees feedback
        // even when the server-side job finishes before the first poll.
        self.active_jobs.push(Job {
            id: "__scan__".into(),
            status: JobStatus::Running,
            progress: None,
            description: "Starting scan…".into(),
        });
        self.rebuild_job_list(widgets);
        self.start_job_polling(sender);

        sender.oneshot_command(async move {
            let result = client.metadata_scan().await.map_err(|e| e.to_string());
            LibraryCmd::ScanTriggered(result)
        });
    }

    fn poll_jobs(&self, sender: &ComponentSender<Self>) {
        if let Some(client) = self.client.clone() {
            sender.oneshot_command(async move {
                let result = client.jobs().await.map_err(|e| e.to_string());
                LibraryCmd::JobsFetched(result)
            });
        }
    }

    fn handle_scan_error(
        &mut self,
        widgets: &<Self as Component>::Widgets,
        error: String,
    ) {
        self.scanning = false;
        self.stop_job_polling();
        self.active_jobs.clear();
        self.rebuild_job_list(widgets);
        tracing::warn!("metadata scan failed: {error}");
    }

    fn open_scene_at(
        &self,
        _widgets: &<Self as Component>::Widgets,
        sender: &ComponentSender<Self>,
        index: u32,
    ) {
        let id = self
            .scene_ids
            .borrow()
            .get(index as usize)
            .cloned();
        if let Some(id) = id {
            let _ = sender.output(LibraryOutput::OpenScene {
                id,
                index,
                filter: self.filter.clone(),
                total: self.total,
            });
        }
    }

    fn handle_jobs_fetched(
        &mut self,
        widgets: &<Self as Component>::Widgets,
        sender: &ComponentSender<Self>,
        jobs: Vec<Job>,
    ) {
        if jobs.is_empty() && self.active_jobs.iter().any(|j| j.id == "__scan__") {
            self.active_jobs = vec![Job {
                id: "__scan__".into(),
                status: JobStatus::Finished,
                progress: Some(1.0),
                description: "Scan complete".into(),
            }];
            self.rebuild_job_list(widgets);
            self.stop_job_polling();
            self.scanning = false;
            let tx = sender.input_sender().clone();
            glib::timeout_add_local(std::time::Duration::from_secs(3), move || {
                let _ = tx.send(LibraryMsg::ClearJobs);
                let _ = tx.send(LibraryMsg::Refresh);
                glib::ControlFlow::Break
            });
        } else {
            self.active_jobs = jobs;
            self.rebuild_job_list(widgets);
            let any_active = self
                .active_jobs
                .iter()
                .any(|j| matches!(j.status, JobStatus::Ready | JobStatus::Running));
            if !any_active {
                self.stop_job_polling();
                self.scanning = false;
                // Refresh the scene grid now that server-side jobs are done.
                let tx = sender.input_sender().clone();
                glib::timeout_add_local(std::time::Duration::from_secs(1), move || {
                    let _ = tx.send(LibraryMsg::Refresh);
                    glib::ControlFlow::Break
                });
            }
        }
    }

    fn append_cell(
        &mut self,
        widgets: &<Self as Component>::Widgets,
        scene: Scene,
        index: u32,
        sender: &ComponentSender<Self>,
    ) {
        let id = scene.id.clone();
        let title = scene.display_title();
        let studio = scene
            .studio
            .as_ref()
            .map(|s| s.name.as_str())
            .unwrap_or("");
        let duration = scene
            .duration_seconds()
            .map(format_duration)
            .unwrap_or_default();

        let card = gtk::Box::builder()
            .orientation(gtk::Orientation::Vertical)
            .spacing(0)
            .width_request(CARD_WIDTH)
            .css_classes(["scene-card"])
            .overflow(gtk::Overflow::Hidden)
            .build();

        // Thumbnail container — fixed-height box that always reserves space
        // (so the cell isn't a featureless rectangle while the image loads)
        // and shows a placeholder icon via CSS until the picture lands.
        let thumb_box = gtk::Box::builder()
            .css_classes(["scene-thumb"])
            .height_request(THUMB_HEIGHT)
            .build();

        let picture = gtk::Picture::builder()
            .content_fit(gtk::ContentFit::Cover)
            .can_shrink(true)
            .hexpand(true)
            .vexpand(true)
            .build();
        thumb_box.append(&picture);
        card.append(&thumb_box);

        let body = gtk::Box::builder()
            .orientation(gtk::Orientation::Vertical)
            .spacing(2)
            .css_classes(["scene-body"])
            .build();

        let title_label = gtk::Label::builder()
            .label(&title)
            .xalign(0.0)
            .ellipsize(gtk::pango::EllipsizeMode::End)
            // Cap the label's natural width — without this the FlowBox row
            // sizes to fit the longest title and the cards balloon.
            .max_width_chars(1)
            .width_chars(0)
            .hexpand(true)
            .css_classes(["scene-title"])
            .build();
        body.append(&title_label);

        let meta_text = match (studio.is_empty(), duration.is_empty()) {
            (true, true) => String::new(),
            (false, true) => studio.to_owned(),
            (true, false) => duration.clone(),
            (false, false) => format!("{studio} · {duration}"),
        };
        if !meta_text.is_empty() {
            let meta_label = gtk::Label::builder()
                .label(&meta_text)
                .xalign(0.0)
                .ellipsize(gtk::pango::EllipsizeMode::End)
                .max_width_chars(1)
                .width_chars(0)
                .hexpand(true)
                .css_classes(["scene-meta"])
                .build();
            body.append(&meta_label);
        }

        if let Some(badge) = o_counter_badge(scene.o_counter.unwrap_or(0)) {
            body.append(&badge);
        }

        card.append(&body);

        let child = gtk::FlowBoxChild::builder()
            .child(&card)
            // Without this each child stretches to fill the row, which in
            // a non-homogeneous FlowBox with only a couple of fitting cards
            // leaves them comically wide.
            .hexpand(false)
            .halign(gtk::Align::Start)
            .build();
        widgets.grid.append(&child);

        // Track scene ids by their FlowBox position so the activation
        // handler can resolve `FlowBoxChild::index()` back to a scene id.
        // `index` is the current scene's 0-based position in the result set
        // and matches the order children are appended; assert in debug.
        debug_assert_eq!(self.scene_ids.borrow().len() as u32, index);
        self.scene_ids.borrow_mut().push(id.clone());
        self.cells.borrow_mut().insert(id.clone(), picture);

        if let Some(url) = scene.paths.screenshot.clone() {
            let Some(client) = self.client.clone() else { return };
            let sem = self.fetch_sem.clone();
            let scene_id = id.clone();
            sender.oneshot_command(async move {
                let _permit = sem.acquire_owned().await.ok();
                load_thumbnail(&client, &url, scene_id).await
            });
        }
    }
}

/// Drop-icon + count badge shown on the library card when a scene has
/// been tracked at least once. Returns `None` for `count == 0` so the
/// caller can skip appending entirely.
fn o_counter_badge(count: i32) -> Option<gtk::Box> {
    if count <= 0 {
        return None;
    }
    let badge = gtk::Box::builder()
        .orientation(gtk::Orientation::Horizontal)
        .spacing(4)
        .halign(gtk::Align::Start)
        .css_classes(["o-counter-badge"])
        .build();
    badge.append(
        &gtk::Image::builder()
            .icon_name("o-counter-symbolic")
            .pixel_size(12)
            .build(),
    );
    badge.append(&gtk::Label::builder().label(count.to_string()).build());
    Some(badge)
}

fn empty_thumbnail(scene_id: String) -> LibraryCmd {
    LibraryCmd::Thumbnail(Box::new(ThumbnailPayload {
        scene_id,
        rgba: Vec::new(),
        width: 0,
        height: 0,
    }))
}

/// Look up a thumbnail in the on-disk cache, falling back to a fetch +
/// decode + cache-write on a miss. Decoding runs on the blocking pool so
/// CPU-heavy WebP / JPEG decompression doesn't stall other in-flight
/// fetches sharing the async runtime.
async fn load_thumbnail(
    client: &stash_api::Client,
    url: &str,
    scene_id: String,
) -> LibraryCmd {
    let cache_path = thumb_cache_path(url);

    if let Ok(bytes) = tokio::fs::read(&cache_path).await
        && bytes.len() == THUMB_BYTES
    {
        return LibraryCmd::Thumbnail(Box::new(ThumbnailPayload {
            scene_id,
            rgba: bytes,
            width: THUMB_WIDTH as u32,
            height: THUMB_HEIGHT as u32,
        }));
    }

    let original = match client.fetch_bytes(url).await {
        Ok(b) => b,
        Err(e) => {
            tracing::debug!("fetch thumbnail {scene_id}: {e}");
            return empty_thumbnail(scene_id);
        }
    };

    let decoded = tokio::task::spawn_blocking(move || {
        decode_thumbnail(&original, THUMB_WIDTH as u32, THUMB_HEIGHT as u32)
    })
    .await;

    match decoded {
        Ok(Ok((rgba, width, height))) => {
            // Fire-and-forget cache write; failure is non-fatal.
            let bytes_for_cache = rgba.clone();
            tokio::spawn(async move {
                if let Some(parent) = cache_path.parent() {
                    let _ = tokio::fs::create_dir_all(parent).await;
                }
                if let Err(e) = tokio::fs::write(&cache_path, &bytes_for_cache).await {
                    tracing::debug!("write thumbnail cache: {e}");
                }
            });
            LibraryCmd::Thumbnail(Box::new(ThumbnailPayload {
                scene_id,
                rgba,
                width,
                height,
            }))
        }
        Ok(Err(e)) => {
            tracing::debug!("decode thumbnail {scene_id}: {e}");
            empty_thumbnail(scene_id)
        }
        Err(e) => {
            tracing::debug!("decode task panicked for {scene_id}: {e}");
            empty_thumbnail(scene_id)
        }
    }
}

fn thumb_cache_path(url: &str) -> std::path::PathBuf {
    use std::collections::hash_map::DefaultHasher;
    use std::hash::{Hash, Hasher};

    let mut h = DefaultHasher::new();
    url.hash(&mut h);
    // Embed the dimensions so a future change to THUMB_WIDTH / THUMB_HEIGHT
    // automatically invalidates old entries instead of reading them as the
    // wrong size.
    let name = format!("{:016x}-{}x{}.bin", h.finish(), THUMB_WIDTH, THUMB_HEIGHT);
    stash_player_core::cache::thumb_dir()
        .unwrap_or_else(|_| std::env::temp_dir().join("stash-player-thumbs"))
        .join(name)
}

/// Crop + resize to *exactly* `target_w × target_h` (RGBA8). The exact size
/// is load-bearing for layout: `gtk::Picture` reports its paintable's
/// intrinsic size as the widget's natural width, and FlowBox picks the
/// number of columns from that natural width — so a thumbnail wider than
/// the card means cards stop fitting per row.
fn decode_thumbnail(
    bytes: &[u8],
    target_w: u32,
    target_h: u32,
) -> Result<(Vec<u8>, u32, u32), image::ImageError> {
    let img = image::load_from_memory(bytes)?;
    let target_ratio = target_w as f32 / target_h as f32;
    let img_ratio = img.width() as f32 / img.height() as f32;
    let cropped = if img_ratio > target_ratio {
        // Source is wider than target — crop sides.
        let new_w = ((img.height() as f32) * target_ratio).round().max(1.0) as u32;
        let x = img.width().saturating_sub(new_w) / 2;
        img.crop_imm(x, 0, new_w, img.height())
    } else {
        // Source is taller than target — crop top/bottom.
        let new_h = ((img.width() as f32) / target_ratio).round().max(1.0) as u32;
        let y = img.height().saturating_sub(new_h) / 2;
        img.crop_imm(0, y, img.width(), new_h)
    };
    let scaled = cropped.resize_exact(target_w, target_h, image::imageops::FilterType::Triangle);
    let rgba = scaled.to_rgba8();
    let (w, h) = (rgba.width(), rgba.height());
    Ok((rgba.into_raw(), w, h))
}

fn sort_string_list() -> gtk::StringList {
    let labels: Vec<&str> = SortKey::ALL.iter().map(|k| k.label()).collect();
    gtk::StringList::new(&labels)
}

fn rating_string_list() -> gtk::StringList {
    let labels: Vec<&str> = MIN_RATING_OPTIONS.iter().map(|(l, _)| *l).collect();
    gtk::StringList::new(&labels)
}

impl LibraryPage {
    fn sort_index(&self) -> usize {
        SortKey::ALL
            .iter()
            .position(|k| *k == self.filter.sort)
            .unwrap_or(0)
    }

    fn rating_index(&self) -> usize {
        MIN_RATING_OPTIONS
            .iter()
            .position(|(_, v)| *v == self.filter.min_rating)
            .unwrap_or(0)
    }

}

impl LibraryPage {
    fn stack_name(&self) -> &'static str {
        if self.client.is_none() {
            "empty"
        } else if self.error.is_some() {
            "error"
        } else if self.loaded == 0 && self.loading {
            "loading"
        } else {
            "grid"
        }
    }

    /// True while loading additional pages (not the initial fetch). The
    /// initial fetch shows the full-page Loading state via the Stack; this
    /// drives the small spinner under the grid.
    fn is_loading_more(&self) -> bool {
        self.loading && self.loaded > 0
    }
}

/// Seed for a fresh shuffle. Time-based since we don't depend on `rand`.
fn fresh_seed() -> u32 {
    use std::time::{SystemTime, UNIX_EPOCH};
    SystemTime::now()
        .duration_since(UNIX_EPOCH)
        .map(|d| d.subsec_nanos())
        .unwrap_or(0)
}

/// True when the grid should pull another page.
///
/// One condition covers both cases we care about. If the content doesn't
/// fill the viewport at all, `upper == page_size` and `value == 0`, so
/// `remaining` is 0 and we load more — this is the case `edge-reached`
/// could never catch, because nothing is scrollable. Otherwise it's a
/// plain prefetch check against how much unseen content is left below.
fn should_load_more(adj: &gtk::Adjustment) -> bool {
    let page = adj.page_size();
    if page <= 0.0 {
        return false;
    }
    let remaining = adj.upper() - adj.value() - page;
    remaining < page * PREFETCH_VIEWPORTS
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
