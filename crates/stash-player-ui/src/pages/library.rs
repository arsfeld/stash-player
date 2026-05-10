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

use stash_api::{FindScenesPage, Scene, SceneFilter, SortDirection, SortKey};

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

const PAGE_SIZE: u32 = 24;
/// Cap concurrent thumbnail fetches so we don't open a connection per scene
/// the moment a page lands. 12 keeps the pipe full without thrashing reqwest's
/// per-host pool (default 10) too hard.
const MAX_PARALLEL_THUMBS: usize = 12;
const CARD_WIDTH: i32 = 240;
const THUMB_WIDTH: i32 = CARD_WIDTH;
const THUMB_HEIGHT: i32 = 135;
const THUMB_BYTES: usize = (THUMB_WIDTH as usize) * (THUMB_HEIGHT as usize) * 4;

#[derive(Debug)]
pub struct LibraryInit {
    pub client: Option<stash_api::Client>,
}

pub struct LibraryPage {
    client: Option<stash_api::Client>,
    filter: SceneFilter,
    page: u32,
    total: i64,
    loaded: u32,
    loading: bool,
    error: Option<String>,
    /// Pictures keyed by scene id so the async thumbnail handler can
    /// patch the right cell when the bytes arrive.
    cells: Rc<RefCell<HashMap<String, gtk::Picture>>>,
    fetch_sem: Arc<Semaphore>,
}

#[derive(Debug)]
pub enum LibraryMsg {
    SetClient(stash_api::Client),
    Refresh,
    LoadMore,
    SearchChanged(String),
    SortKeyChanged(u32),
    SetDirection(SortDirection),
    OrganizedChanged(bool),
    MinRatingChanged(u32),
    SceneActivated { id: String, index: u32 },
    OpenSettings,
    PlayRandom,
}

pub enum LibraryCmd {
    Page(Result<FindScenesPage, String>),
    Random(Result<RandomPick, String>),
    Thumbnail {
        scene_id: String,
        rgba: Vec<u8>,
        width: u32,
        height: u32,
    },
}

pub struct RandomPick {
    pub scene: Option<Scene>,
    pub total: i64,
    pub filter: SceneFilter,
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
            LibraryCmd::Thumbnail {
                scene_id,
                width,
                height,
                ..
            } => f
                .debug_struct("Thumbnail")
                .field("scene_id", scene_id)
                .field("size", &format_args!("{width}x{height}"))
                .finish(),
        }
    }
}

#[derive(Debug)]
pub enum LibraryOutput {
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
            set_child = &adw::ToolbarView {
                add_top_bar = &adw::HeaderBar {
                    pack_start = &gtk::Button {
                        set_icon_name: "media-playlist-shuffle-symbolic",
                        set_tooltip_text: Some("Play random scene"),
                        #[watch]
                        set_sensitive: model.client.is_some(),
                        connect_clicked => LibraryMsg::PlayRandom,
                    },

                    pack_end = &gtk::Button {
                        set_icon_name: "preferences-system-symbolic",
                        set_tooltip_text: Some("Settings"),
                        connect_clicked => LibraryMsg::OpenSettings,
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
                },

                #[wrap(Some)]
                set_content = &gtk::Stack {
                    set_transition_type: gtk::StackTransitionType::Crossfade,

                    add_named[Some("empty")] = &adw::StatusPage {
                        set_icon_name: Some("network-server-symbolic"),
                        set_title: "No server configured",
                        set_description: Some("Add your Stash server URL and API key in settings."),

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

                    add_named[Some("grid")] = &gtk::ScrolledWindow {
                        set_hscrollbar_policy: gtk::PolicyType::Never,
                        connect_edge_reached[sender] => move |_, edge| {
                            if edge == gtk::PositionType::Bottom {
                                sender.input(LibraryMsg::LoadMore);
                            }
                        },

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
                                    let id = unsafe {
                                        child.data::<String>("scene-id")
                                            .map(|n| n.as_ref().clone())
                                    };
                                    let index = unsafe {
                                        child.data::<u32>("scene-index")
                                            .map(|n| *n.as_ref())
                                    };
                                    if let (Some(id), Some(index)) = (id, index) {
                                        sender.input(LibraryMsg::SceneActivated { id, index });
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
        }
    }

    fn init(
        init: Self::Init,
        root: Self::Root,
        sender: ComponentSender<Self>,
    ) -> ComponentParts<Self> {
        let model = LibraryPage {
            client: init.client,
            filter: SceneFilter::new(),
            page: 0,
            total: 0,
            loaded: 0,
            loading: false,
            error: None,
            cells: Rc::new(RefCell::new(HashMap::new())),
            fetch_sem: Arc::new(Semaphore::new(MAX_PARALLEL_THUMBS)),
        };

        let widgets = view_output!();

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
                    && self.client.is_some()
                    && (self.total == 0 || self.loaded < self.total as u32)
                {
                    self.fetch_next_page(&sender);
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
            LibraryMsg::SceneActivated { id, index } => {
                let _ = sender.output(LibraryOutput::OpenScene {
                    id,
                    index,
                    filter: self.filter.clone(),
                    total: self.total,
                });
            }
            LibraryMsg::OpenSettings => {
                let _ = sender.output(LibraryOutput::OpenSettings);
            }
            LibraryMsg::PlayRandom => {
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
                        .map(|p| RandomPick {
                            scene: p.scenes.into_iter().next(),
                            total: p.count,
                            filter: req_filter,
                        })
                        .map_err(|e| e.to_string());
                    LibraryCmd::Random(result)
                });
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
            }
            LibraryCmd::Page(Err(e)) => {
                self.loading = false;
                self.error = Some(e);
            }
            LibraryCmd::Random(Ok(RandomPick { scene: Some(scene), total, filter })) => {
                let _ = sender.output(LibraryOutput::OpenScene {
                    id: scene.id,
                    index: 0,
                    filter,
                    total,
                });
            }
            LibraryCmd::Random(Ok(RandomPick { scene: None, .. })) => {
                tracing::debug!("play random: no scenes match current filter");
            }
            LibraryCmd::Random(Err(e)) => {
                tracing::warn!("play random failed: {e}");
            }
            LibraryCmd::Thumbnail {
                scene_id,
                rgba,
                width,
                height,
            } => {
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
        }
        self.update_view(widgets, sender);
    }
}

impl LibraryPage {
    fn reset(&mut self, widgets: &<Self as Component>::Widgets) {
        self.page = 0;
        self.total = 0;
        self.loaded = 0;
        self.error = None;
        self.cells.borrow_mut().clear();
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

        card.append(&body);

        let child = gtk::FlowBoxChild::builder()
            .child(&card)
            // Without this each child stretches to fill the row, which in
            // a non-homogeneous FlowBox with only a couple of fitting cards
            // leaves them comically wide.
            .hexpand(false)
            .halign(gtk::Align::Start)
            .build();
        unsafe {
            child.set_data("scene-id", id.clone());
            child.set_data::<u32>("scene-index", index);
        }
        widgets.grid.append(&child);

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

fn empty_thumbnail(scene_id: String) -> LibraryCmd {
    LibraryCmd::Thumbnail {
        scene_id,
        rgba: Vec::new(),
        width: 0,
        height: 0,
    }
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
        return LibraryCmd::Thumbnail {
            scene_id,
            rgba: bytes,
            width: THUMB_WIDTH as u32,
            height: THUMB_HEIGHT as u32,
        };
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
            LibraryCmd::Thumbnail {
                scene_id,
                rgba,
                width,
                height,
            }
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
