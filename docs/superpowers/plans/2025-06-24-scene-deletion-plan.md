# Scene Deletion Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Add the ability to permanently delete scenes from Stash via a delete button on the scene page and a right-click context menu on library cards, with confirmation dialogs and cache invalidation.

**Architecture:** Add `destroy_scene` to the API client, expose it through FFI, wire confirmation dialogs on both entry points (scene page button + library right-click popover), navigate to next neighbor after deletion, and invalidate the library cache so no ghost cards remain. The app tracks which scene is currently open so it can pop the scene page if the library deletes the active scene.

**Tech Stack:** Rust (stash-api, stash-player-ffi, stash-player-ui), relm4, GTK4/libadwaita, SwiftUI (macOS)

## Global Constraints

- Follow existing patterns: mutations mirror `increment_o`/`reset_o`, messages mirror `IncrementO`/`ResetO`/`OUpdated`
- `AdwMessageDialog` for confirmation (not raw GtkDialog)
- Delete button uses `destructive-action` CSS class; response set to `ResponseAppearance::Destructive`
- Library cache stores scenes as `scene_ids: Rc<RefCell<Vec<String>>>` + `cells: Rc<RefCell<HashMap<String, gtk::Picture>>>` — invalidation removes from both
- UI changes are not tested by policy (relm4 + GStreamer needs end-to-end runs)
- API integration test uses wiremock fixture, following `increment_o_returns_new_count_and_sends_id_variable` pattern
- No right-click context menu on macOS library cards in this round

---

### Task 1: API layer — mutation, response type, client method, fixture, integration test

**Files:**
- Modify: `crates/stash-api/src/lib.rs`
- Create: `crates/stash-api/tests/fixtures/scene_destroy.json`
- Modify: `crates/stash-api/tests/client.rs`

**Interfaces:**
- Produces: `Client::destroy_scene(&self, id: &str) -> Result<bool>` (async)
- Produces: `fixture_json("scene_destroy.json")` returns `{"data":{"sceneDestroy":true}}`

- [ ] **Step 1: Write the fixture file**

Create `crates/stash-api/tests/fixtures/scene_destroy.json`:

```json
{"data":{"sceneDestroy":true}}
```

- [ ] **Step 2: Add mutation constant and response type to lib.rs**

After the `SCENE_RESET_O_MUTATION` / `SceneResetOResponse` block (line ~284), add:

```rust
const SCENE_DESTROY_MUTATION: &str = r#"
mutation SceneDestroy($id: ID!) {
  sceneDestroy(input: { id: $id })
}
"#;

#[derive(Deserialize)]
struct SceneDestroyResponse {
    #[serde(rename = "sceneDestroy")]
    scene_destroy: bool,
}
```

Insert after the `SceneResetOResponse` closing `}` (line 284). Exact anchor:

```rust
struct SceneResetOResponse {
    #[serde(rename = "sceneResetO")]
    scene_reset_o: i32,
}

/// Job status as returned by Stash's GraphQL API.
```

Becomes:

```rust
struct SceneResetOResponse {
    #[serde(rename = "sceneResetO")]
    scene_reset_o: i32,
}

const SCENE_DESTROY_MUTATION: &str = r#"
mutation SceneDestroy($id: ID!) {
  sceneDestroy(input: { id: $id })
}
"#;

#[derive(Deserialize)]
struct SceneDestroyResponse {
    #[serde(rename = "sceneDestroy")]
    scene_destroy: bool,
}

/// Job status as returned by Stash's GraphQL API.
```

- [ ] **Step 3: Add destroy_scene method to Client impl**

After the `reset_o` method (after line 192), insert:

```rust
    /// Permanently delete a scene by id. Returns `true` on success.
    pub async fn destroy_scene(&self, id: &str) -> Result<bool> {
        let variables = serde_json::json!({ "id": id });
        let resp: SceneDestroyResponse = self
            .graphql(SCENE_DESTROY_MUTATION, &variables)
            .await?;
        Ok(resp.scene_destroy)
    }
```

- [ ] **Step 4: Add integration test to client.rs**

After the `reset_o_returns_zero_and_sends_id_variable` test (after line 224), insert:

```rust
#[tokio::test]
async fn destroy_scene_returns_true_and_sends_id_variable() {
    let server = MockServer::start().await;
    Mock::given(method("POST"))
        .and(path("/graphql"))
        .respond_with(
            ResponseTemplate::new(200).set_body_json(fixture_json("scene_destroy.json")),
        )
        .mount(&server)
        .await;

    let client = Client::new(&server.uri(), "test-key").unwrap();
    let ok = client.destroy_scene("1001").await.unwrap();
    assert!(ok);

    let req = &server.received_requests().await.unwrap()[0];
    let body: serde_json::Value = serde_json::from_slice(&req.body).unwrap();
    assert!(body["query"].as_str().unwrap().contains("sceneDestroy"));
    assert_eq!(body["variables"]["id"], "1001");
}
```

- [ ] **Step 5: Run the new test**

```sh
cargo test -p stash-api destroy_scene_returns_true_and_sends_id_variable
```

Expected: test (and all existing tests) pass.

- [ ] **Step 6: Commit**

```sh
git add crates/stash-api/src/lib.rs crates/stash-api/tests/fixtures/scene_destroy.json crates/stash-api/tests/client.rs
git commit -m "feat(stash-api): add destroy_scene mutation"
```

---

### Task 2: FFI layer — destroy_scene wrapper

**Files:**
- Modify: `crates/stash-player-ffi/src/lib.rs`

**Interfaces:**
- Consumes: `Client::destroy_scene(&self, id: &str) -> Result<bool>`
- Produces: `StashPlayer::destroy_scene(&self, id: String) -> Result<bool, FfiError>`

- [ ] **Step 1: Add destroy_scene method to StashPlayer impl**

After the `reset_o` method (after line 405), insert:

```rust
    /// Permanently delete a scene by id. Returns `true` on success.
    pub fn destroy_scene(&self, id: String) -> Result<bool, FfiError> {
        let client = self.client()?;
        Ok(rt().block_on(client.destroy_scene(&id))?)
    }
```

- [ ] **Step 2: Verify it compiles**

```sh
cargo build -p stash-player-ffi
```

- [ ] **Step 3: Commit**

```sh
git add crates/stash-player-ffi/src/lib.rs
git commit -m "feat(ffi): add destroy_scene FFI method"
```

---

### Task 3: GTK scene page — message variants and delete button

**Files:**
- Modify: `crates/stash-player-ui/src/pages/scene.rs`

**Interfaces:**
- Produces: `SceneMsg::Destroy`, `SceneCmd::Destroyed { scene_id, result }`, `SceneOutput::SceneDeleted { scene_id }`
- Produces: Danger Zone section in the loaded stack with "Delete Scene" button

- [ ] **Step 1: Add SceneMsg::Destroy variant**

In `SceneMsg` enum (after `ResetO` on line 73), add:

```rust
    /// User confirmed they want to permanently delete this scene.
    Destroy,
```

- [ ] **Step 2: Add SceneCmd::Destroyed variant**

In `SceneCmd` enum (after `OUpdated` variant ending at line 116), add:

```rust
    /// Result of a `sceneDestroy` mutation.
    Destroyed {
        scene_id: String,
        result: Result<bool, String>,
    },
```

- [ ] **Step 3: Add SceneOutput::SceneDeleted variant**

In `SceneOutput` enum (after `SetVolume` variant ending at line 86), add:

```rust
    /// A scene was deleted — the library should remove it from its cache.
    SceneDeleted { scene_id: String },
```

- [ ] **Step 4: Add Danger Zone section to the loaded stack view**

Find the `file_group` `PreferencesGroup` closing line and the subsequent closing of the `gtk::Box` (the metadata container). After the `#[name = "file_group"]` block (around line 401), but still inside the `adw::Clamp`'s inner `gtk::Box`, add:

```rust
                                    #[name = "delete_section"]
                                    gtk::Box {
                                        set_orientation: gtk::Orientation::Vertical,
                                        set_spacing: 8,
                                        set_margin_top: 16,
                                        set_visible: false,

                                        gtk::Label {
                                            set_label: "Danger Zone",
                                            set_xalign: 0.0,
                                            add_css_class: "heading",
                                        },

                                        gtk::Button {
                                            set_label: "Delete Scene",
                                            add_css_class: "destructive-action",
                                            set_halign: gtk::Align::Start,
                                            #[watch]
                                            set_sensitive: matches!(model.state, State::Loaded(_)),
                                            connect_clicked => SceneMsg::Destroy,
                                        },
                                    },
```

Anchor for insertion: find the closing of the `file_group` block and the closing of the next `gtk::Box`:

```
                                    #[name = "file_group"]
                                    adw::PreferencesGroup {
                                        set_title: "File",
                                        set_visible: false,
                                    },
                                },
                            },
                        },
                    },
```

Insert the `delete_section` between `},` (closing file_group) and `},` (closing the inner gtk::Box, i.e. the one with `set_spacing: 24`).

- [ ] **Step 5: Make delete_section visible in populate_scene**

In `populate_scene` function, find where `file_group` is made visible (around `widgets.file_group.set_visible(true)`). Add:

```rust
    widgets.delete_section.set_visible(true);
```

If `file_group` visibility is set conditionally (e.g. `widgets.file_group.set_visible(file.is_some())`), put `delete_section.set_visible(true)` on its own line nearby — it's always visible when a scene is loaded.

- [ ] **Step 6: Add Destroy arm to update_with_view**

In `update_with_view`, after the `SceneMsg::ResetO` arm (line 502), add:

```rust
            SceneMsg::Destroy => {
                self.spawn_destroy(&sender);
            }
```

Before the closing `}` of the match block that handles `SaveActivity`.

- [ ] **Step 7: Verify it compiles** (will have unused method warning until Task 4)

```sh
cargo build -p stash-player-ui 2>&1 | head -20
```

- [ ] **Step 8: Commit**

```sh
git add crates/stash-player-ui/src/pages/scene.rs
git commit -m "feat(ui): add scene delete button and message variants"
```

---

### Task 4: GTK scene page — confirmation dialog, async command, post-delete navigation

**Files:**
- Modify: `crates/stash-player-ui/src/pages/scene.rs`

**Interfaces:**
- Consumes: `Client::destroy_scene` from Task 1
- Consumes: `SceneMsg::Destroy`, `SceneCmd::Destroyed`, `SceneOutput::SceneDeleted` from Task 3
- Produces: `spawn_destroy` method, `SceneCmd::Destroyed` handler with post-delete navigation

- [ ] **Step 1: Add spawn_destroy helper method**

Add a new method to `impl ScenePage` (after `spawn_o_mutation`, before `start_navigate`):

```rust
    fn spawn_destroy(&self, sender: &ComponentSender<Self>) {
        if !matches!(self.state, State::Loaded(_)) {
            return;
        }
        let title = match &self.state {
            State::Loaded(scene) => scene.display_title(),
            _ => return,
        };

        let root = sender.root_widget();
        let dialog = adw::MessageDialog::builder()
            .heading("Delete Scene")
            .body(format!(
                "Permanently delete \"{title}\"? This cannot be undone."
            ))
            .modal(true)
            .transient_for(&root)
            .build();
        dialog.add_responses(&[("cancel", "Cancel"), ("delete", "Delete")]);
        dialog.set_response_appearance("delete", adw::ResponseAppearance::Destructive);

        let client = self.client.clone();
        let scene_id = self.scene_id.clone();
        let sender2 = sender.clone();
        dialog.connect_response(move |d, response| {
            d.close();
            if response == "delete" {
                let c = client.clone();
                let id = scene_id.clone();
                sender2.oneshot_command(async move {
                    let result = c.destroy_scene(&id).await.map_err(|e| e.to_string());
                    SceneCmd::Destroyed {
                        scene_id: id,
                        result,
                    }
                });
            }
        });
        dialog.present();
    }
```

- [ ] **Step 2: Add Destroyed handler in update_cmd_with_view**

After the `SceneCmd::OUpdated` handler (after line 615), add:

```rust
            SceneCmd::Destroyed { scene_id, result } => match result {
                Ok(true) => {
                    tracing::debug!("scene {scene_id} deleted");
                    let _ = sender.output(SceneOutput::SceneDeleted {
                        scene_id: scene_id.clone(),
                    });
                    // Navigate to next neighbor; if none, pop to library.
                    self.navigate_after_delete(widgets, sender, &scene_id);
                }
                Ok(false) => {
                    tracing::warn!("sceneDestroy returned false for {scene_id}");
                    self.show_toast(widgets, "Server refused to delete this scene.");
                }
                Err(e) => {
                    tracing::warn!("scene deletion failed for {scene_id}: {e}");
                    self.show_toast(widgets, &format!("Deletion failed: {e}"));
                }
            },
```

- [ ] **Step 3: Add navigate_after_delete helper method**

Add to `impl ScenePage` (after `start_navigate`):

```rust
    fn navigate_after_delete(
        &mut self,
        _widgets: &<Self as Component>::Widgets,
        sender: &ComponentSender<Self>,
        _deleted_id: &str,
    ) {
        // Try to go to the next neighbor.
        let Some(ctx) = self.context.as_ref() else {
            // No context — pop back to library.
            sender.root_widget().activate_action(
                "navigation.pop",
                None,
            );
            return;
        };

        // After deletion, total is one less. Adjust the context.
        if let Some(ctx_mut) = self.context.as_mut() {
            if ctx_mut.total > 0 {
                ctx_mut.total -= 1;
            }
        }

        let target_index = ctx.index; // same index — the next scene shifted into this slot
        if ctx.total >= 0 && (target_index as i64) >= ctx.total {
            // No more scenes after this one — try previous.
            if target_index > 0 {
                // Navigate to previous scene.
                self.player.emit(VideoPlayerMsg::SetUrl {
                    url: None,
                    resume_secs: None,
                });
                self.state = State::Loading;
                let client = self.client.clone();
                let filter = ctx.filter.clone();
                let prev_index = target_index - 1;
                sender.oneshot_command(async move {
                    let page = prev_index + 1;
                    let result = client
                        .find_scenes(&filter, page, 1)
                        .await
                        .map(|p| p.scenes.into_iter().next())
                        .map_err(|e| e.to_string());
                    SceneCmd::Neighbor {
                        direction: NavDirection::Prev,
                        target_index: prev_index,
                        result: Box::new(result),
                    }
                });
            } else {
                // No scenes left — pop to library.
                sender.root_widget().activate_action(
                    "navigation.pop",
                    None,
                );
            }
        } else {
            // Navigate to the scene now at this index (was next, now current slot).
            self.player.emit(VideoPlayerMsg::SetUrl {
                url: None,
                resume_secs: None,
            });
            self.state = State::Loading;
            let client = self.client.clone();
            let filter = ctx.filter.clone();
            sender.oneshot_command(async move {
                let page = target_index + 1;
                let result = client
                    .find_scenes(&filter, page, 1)
                    .await
                    .map(|p| p.scenes.into_iter().next())
                    .map_err(|e| e.to_string());
                SceneCmd::Neighbor {
                    direction: NavDirection::Next,
                    target_index,
                    result: Box::new(result),
                }
            });
        }
    }
```

- [ ] **Step 4: Add show_toast helper method**

Add to `impl ScenePage`:

```rust
    fn show_toast(&self, widgets: &<Self as Component>::Widgets, message: &str) {
        let toast = adw::Toast::builder()
            .title(message)
            .timeout(4)
            .build();
        widgets.toolbar_view.add_toast(&toast);
    }
```

- [ ] **Step 5: Add Destroyed arm to failure_message**

In `failure_message` method, add a `Destroyed` arm that returns `None` (the error is shown via toast, not the error page):

```rust
            SceneCmd::Destroyed { .. } => None,
```

- [ ] **Step 6: Verify it compiles**

```sh
cargo build -p stash-player-ui
```

- [ ] **Step 7: Commit**

```sh
git add crates/stash-player-ui/src/pages/scene.rs
git commit -m "feat(ui): add scene delete confirmation and post-delete navigation"
```

---

### Task 5: GTK app routing — current_scene_id, AppMsg::SceneDeleted, forwarding

**Files:**
- Modify: `crates/stash-player-ui/src/app.rs`

**Interfaces:**
- Consumes: `SceneOutput::SceneDeleted` from Task 3
- Produces: `AppMsg::SceneDeleted { scene_id }`, `AppModel::current_scene_id`
- Produces: `LibraryMsg::RemoveScene(String)` forwarding

- [ ] **Step 1: Add current_scene_id to AppModel**

In `AppModel` struct (after `client: Option<stash_api::Client>`):

```rust
    /// Track which scene is open so we can pop it if the library deletes it.
    current_scene_id: Option<String>,
```

Initialize to `None` in the `init` / `ComponentParts` construction.

- [ ] **Step 2: Add AppMsg::SceneDeleted variant**

In `AppMsg` enum, after `SetHideInteractive`, add:

```rust
    /// A scene was deleted (from scene page or library).
    /// If it's the currently open scene, pop the scene page.
    SceneDeleted { scene_id: String },
```

- [ ] **Step 3: Set current_scene_id on OpenScene**

In `AppMsg::OpenScene` handler (around line 175), before or after creating the scene controller, add:

```rust
self.current_scene_id = Some(id.clone());
```

- [ ] **Step 4: Clear current_scene_id on NavPopped**

In `AppMsg::NavPopped` handler, inside the `if self.scene.as_ref().is_some_and(...)` block, add:

```rust
self.current_scene_id = None;
```

- [ ] **Step 5: Forward SceneOutput::SceneDeleted to AppMsg::SceneDeleted**

In the `forward()` closure that maps `SceneOutput` (around line 175), add:

```rust
SceneOutput::SceneDeleted { scene_id } => AppMsg::SceneDeleted { scene_id },
```

- [ ] **Step 6: Handle AppMsg::SceneDeleted**

Add handler before the closing `}` of the `update_with_view` match block:

```rust
AppMsg::SceneDeleted { scene_id } => {
    self.library.emit(LibraryMsg::RemoveScene(scene_id.clone()));
    if self.current_scene_id.as_deref() == Some(&scene_id) {
        // The currently open scene was deleted — pop back to library.
        self.current_scene_id = None;
        if let Some(scene) = self.scene.take() {
            widgets.nav.pop();
            // Drop the scene controller so playback stops.
            drop(scene);
        }
    }
}
```

- [ ] **Step 7: Verify it compiles**

```sh
cargo build -p stash-player-ui
```

- [ ] **Step 8: Commit**

```sh
git add crates/stash-player-ui/src/app.rs
git commit -m "feat(ui): route scene deletion through app to library"
```

---

### Task 6: GTK library — right-click popover, gesture, message variants

**Files:**
- Modify: `crates/stash-player-ui/src/pages/library.rs`

**Interfaces:**
- Consumes: `LibraryMsg::DeleteRequested(String)`, `LibraryMsg::RemoveScene(String)` (new)
- Consumes: `LibraryCmd::Destroyed { scene_id, result }`, `LibraryOutput::SceneDeleted { scene_id }` (new)
- Produces: Per-card `gtk::Popover` + `gtk::GestureClick` in `append_cell`

- [ ] **Step 1: Add message variants**

Add to `LibraryMsg` enum (before the closing `}`):

```rust
    /// User right-clicked a card and chose "Delete" from its popover.
    DeleteRequested(String),
    /// App tells us the scene page deleted a scene; remove from cache.
    RemoveScene(String),
```

Add to `LibraryCmd` enum:

```rust
    /// Result of `destroyScene` mutation.
    Destroyed {
        scene_id: String,
        result: Result<bool, String>,
    },
```

Add to `LibraryOutput` enum:

```rust
    /// A scene was deleted from the library. The app should pop the scene
    /// page if it's showing the deleted scene.
    SceneDeleted { scene_id: String },
```

- [ ] **Step 2: Add right-click popover and gesture to append_cell**

In `append_cell`, after the `FlowBoxChild` is appended to the grid and scene_ids/cells are tracked (after line 1136, after the `self.cells.borrow_mut().insert(...)` call), add:

```rust
        // Right-click context menu with "Delete Scene"
        let popover = gtk::Popover::builder()
            .has_arrow(true)
            .build();
        popover.set_parent(&child);

        let delete_btn = gtk::Button::builder()
            .label("Delete Scene")
            .css_classes(["destructive-action", "flat"])
            .halign(gtk::Align::Fill)
            .build();
        let sender_rc = sender.clone();
        let id_rc = id.clone();
        delete_btn.connect_clicked(move |_| {
            sender_rc.input(LibraryMsg::DeleteRequested(id_rc.clone()));
        });
        let popover_box = gtk::Box::builder()
            .orientation(gtk::Orientation::Vertical)
            .spacing(0)
            .margin_start(6)
            .margin_end(6)
            .margin_top(6)
            .margin_bottom(6)
            .build();
        popover_box.append(&delete_btn);
        popover.set_child(Some(&popover_box));

        let gesture = gtk::GestureClick::new();
        gesture.set_button(3); // right mouse button
        let popover_clone = popover.clone();
        gesture.connect_pressed(move |gesture, _n_press, _x, _y| {
            gesture.set_state(gtk::EventSequenceState::Claimed);
            popover_clone.popup();
        });
        child.add_controller(gesture);
```

- [ ] **Step 3: Add DeleteRequested placeholder handler**

In `update_with_view`, add after the existing match arms (before the closing `}`):

```rust
            LibraryMsg::DeleteRequested(id) => {
                self.confirm_delete(widgets, &sender, &id);
            }
            LibraryMsg::RemoveScene(id) => {
                self.remove_scene_from_cache(widgets, &id);
            }
```

- [ ] **Step 4: Verify it compiles** (will warn about unused methods)

```sh
cargo build -p stash-player-ui
```

- [ ] **Step 5: Commit**

```sh
git add crates/stash-player-ui/src/pages/library.rs
git commit -m "feat(ui): add library right-click delete popover and messages"
```

---

### Task 7: GTK library — confirmation dialog, cache invalidation, SceneDeleted output

**Files:**
- Modify: `crates/stash-player-ui/src/pages/library.rs`

**Interfaces:**
- Consumes: `Client::destroy_scene` from Task 1
- Consumes: Message variants from Task 6
- Produces: `confirm_delete`, `remove_scene_from_cache` methods; `LibraryCmd::Destroyed` handler; `LibraryOutput::SceneDeleted` emission

- [ ] **Step 1: Add confirm_delete method**

Add to `impl LibraryPage`:

```rust
    fn confirm_delete(
        &self,
        widgets: &<Self as Component>::Widgets,
        sender: &ComponentSender<Self>,
        id: &str,
    ) {
        let Some(client) = self.client.clone() else { return };

        // Find the scene title from our cached data for the dialog body.
        // We don't store full scenes, but we have scene_ids. For the dialog,
        // we show a generic message or find a scene from the cells.
        let root = sender.root_widget();
        let dialog = adw::MessageDialog::builder()
            .heading("Delete Scene")
            .body("Permanently delete this scene? This cannot be undone.")
            .modal(true)
            .transient_for(&root)
            .build();
        dialog.add_responses(&[("cancel", "Cancel"), ("delete", "Delete")]);
        dialog.set_response_appearance("delete", adw::ResponseAppearance::Destructive);

        let scene_id = id.to_owned();
        let sender2 = sender.clone();
        dialog.connect_response(move |d, response| {
            d.close();
            if response == "delete" {
                let c = client.clone();
                let sid = scene_id.clone();
                sender2.oneshot_command(async move {
                    let result = c.destroy_scene(&sid).await.map_err(|e| e.to_string());
                    LibraryCmd::Destroyed {
                        scene_id: sid,
                        result,
                    }
                });
            }
        });
        dialog.present();
    }
```

- [ ] **Step 2: Add remove_scene_from_cache method**

Add to `impl LibraryPage`:

```rust
    fn remove_scene_from_cache(
        &mut self,
        widgets: &<Self as Component>::Widgets,
        id: &str,
    ) {
        let mut ids = self.scene_ids.borrow_mut();
        if let Some(pos) = ids.iter().position(|s| s == id) {
            ids.remove(pos);
            self.cells.borrow_mut().remove(id);
            // Remove the FlowBoxChild at the same position.
            if let Some(child) = widgets.grid.row_at_index(pos as i32) {
                widgets.grid.remove(&child);
            }
            self.loaded = self.loaded.saturating_sub(1);
            self.total = (self.total - 1).max(0);
        }
    }
```

- [ ] **Step 3: Add Destroyed handler to update_cmd_with_view**

After the last `LibraryCmd` arm (after `JobsFetched` handling), add:

```rust
            LibraryCmd::Destroyed { scene_id, result } => match result {
                Ok(true) => {
                    tracing::debug!("library: scene {scene_id} deleted");
                    self.remove_scene_from_cache(widgets, &scene_id);
                    let _ = sender.output(LibraryOutput::SceneDeleted { scene_id });
                }
                Ok(false) => {
                    tracing::warn!("library: sceneDestroy returned false for {scene_id}");
                }
                Err(e) => {
                    tracing::warn!("library: scene deletion failed for {scene_id}: {e}");
                }
            },
```

The library has no toast overlay — errors are logged (same pattern as `SceneCmd::ActivitySaved` in the scene page). A deletion failure is rare and transient; logging is sufficient.

- [ ] **Step 4: Verify it compiles**

```sh
cargo build -p stash-player-ui
```

- [ ] **Step 5: Commit**

```sh
git add crates/stash-player-ui/src/pages/library.rs
git commit -m "feat(ui): add library delete confirmation and cache invalidation"
```

---

### Task 8: macOS — AppState, SceneView, InfoPopover

**Files:**
- Modify: `apps/macos/StashPlayer/AppState.swift`
- Modify: `apps/macos/StashPlayer/Scene/SceneView.swift`
- Modify: `apps/macos/StashPlayer/Scene/InfoPopover.swift`

**Interfaces:**
- Consumes: `StashPlayer.destroyScene(id:)` from Task 2
- Produces: `AppState.destroyScene(id:) -> Bool`
- Produces: `InfoPopover.onDelete` closure prop + destructive button
- Produces: `SceneView` alert + delete handler + post-delete navigation

- [ ] **Step 1: Add destroyScene to AppState**

After `resetO` method in `AppState.swift`, add:

```swift
    func destroyScene(id: String) -> Bool {
        guard let player = stashPlayer else { return false }
        return player.destroyScene(id: id)
    }
```

- [ ] **Step 2: Add onDelete closure to InfoPopover**

Add a new `onDelete` property:

```swift
    let onDelete: () -> Void
```

Add a destructive button below the "Open in Stash" button:

```swift
            Button(role: .destructive) {
                onDelete()
            } label: {
                Label("Delete Scene", systemImage: "trash")
            }
            .buttonStyle(.bordered)
            .controlSize(.small)
```

Update all call sites that construct `InfoPopover` to pass `onDelete: {}`.

- [ ] **Step 3: Add delete state and alert to SceneView**

Add state variable:

```swift
    @State private var showDeleteConfirmation = false
```

Add alert modifier to the main view (alongside other `.alert` modifiers):

```swift
        .alert("Delete Scene", isPresented: $showDeleteConfirmation) {
            Button("Cancel", role: .cancel) { }
            Button("Delete", role: .destructive) {
                let ok = app.destroyScene(id: scene.id)
                if ok {
                    navigateAfterDelete()
                }
            }
        } message: {
            Text("Permanently delete \"\(scene.displayTitle)\"? This cannot be undone.")
        }
```

Pass `onDelete: { showDeleteConfirmation = true }` to `InfoPopover`.

- [ ] **Step 4: Add navigateAfterDelete method to SceneView**

Add a helper that navigates to the next neighbor (using the existing `navigate(by:)` pattern) or pops back to library:

```swift
    @MainActor
    private func navigateAfterDelete() async {
        // Total is one less after deletion.
        if total > 0 { total -= 1 }

        if total > 0 && Int64(index) < total {
            // Navigate to scene now at this index (the next scene shifted into this slot).
            await navigate(by: 0)
        } else if index > 0 && Int64(index - 1) < total {
            // At the end — go to previous scene.
            index -= 1
            await navigate(by: 0)
        } else {
            // No scenes left — pop to library.
            navigationPath.removeLast()
        }
    }
```

Note: `navigate(by: 0)` re-fetches the scene at the current index, which after deletion is the next scene (since everything shifted left). For the "at the end" case, we decrement `index` first so `navigate(by: 0)` fetches the new last scene.

- [ ] **Step 5: Verify it compiles in Xcode**

```sh
# Outside nix develop shell:
env -i PATH=/usr/bin:/bin DEVELOPER_DIR=/Applications/Xcode.app/Contents/Developer \
  xcodebuild -project apps/macos/StashPlayer.xcodeproj \
  -scheme StashPlayer -derivedDataPath build-aux/macos-derived build 2>&1 | tail -20
```

- [ ] **Step 6: Commit**

```sh
git add apps/macos/StashPlayer/AppState.swift apps/macos/StashPlayer/Scene/SceneView.swift apps/macos/StashPlayer/Scene/InfoPopover.swift
git commit -m "feat(macos): add scene delete button and confirmation"
```

---

### Task 9: Final integration check — build, clippy, run tests

**Files:**
- None (verification only)

- [ ] **Step 1: Run full test suite**

```sh
cargo test -p stash-api -p stash-player-core
```

Expected: all tests pass, including the new `destroy_scene_returns_true_and_sends_id_variable`.

- [ ] **Step 2: Run clippy**

```sh
cargo clippy --workspace --all-targets -- -D warnings
```

Expected: no warnings. If new warnings appear, fix them before committing.

- [ ] **Step 3: Build the full workspace**

```sh
cargo build --workspace
```

Expected: compiles cleanly.

- [ ] **Step 4: Commit any final cleanup**

```sh
git add -u
git commit -m "chore: clippy and final cleanup for scene deletion"
```
