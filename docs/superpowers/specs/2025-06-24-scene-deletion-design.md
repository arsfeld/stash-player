# Scene Deletion Design

2025-06-24

## Summary

Add the ability to permanently delete a scene from Stash from within the
player app. Two entry points:

1. **Delete button** on the scene detail page (Linux GTK + macOS)
2. **Right-click context menu** on library cards (Linux GTK)

Both require confirmation via a dialog (the operation is irreversible in
Stash). After deletion, navigate to the next neighbor; if none remain, pop
back to the library. The library grid immediately removes the deleted scene
so no ghost card lingers.

## API layer (`stash-api/src/lib.rs`)

Add the `sceneDestroy` GraphQL mutation, mirroring the existing
`increment_o`/`reset_o` pattern exactly.

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

New public method on `Client`:

```rust
/// Permanently delete a scene by id. Returns `true` on success.
pub async fn destroy_scene(&self, id: &str) -> Result<bool>
```

No new types to re-export — returns `bool`.

Add an integration test in `crates/stash-api/tests/` with a wiremock
fixture for the `sceneDestroy` mutation (following the pattern of existing
mutation tests).

## FFI layer (`stash-player-ffi/src/lib.rs`)

Sync wrapper on `StashPlayer`, identical shape to `increment_o`/`reset_o`:

```rust
pub fn destroy_scene(&self, id: String) -> Result<bool, FfiError> {
    let client = self.client()?;
    Ok(rt().block_on(client.destroy_scene(&id))?)
}
```

## Linux GTK app (`stash-player-ui`)

### Scene page (`pages/scene.rs`)

**New message variants:**

```rust
// SceneMsg (input):
Destroy,  // user confirmed deletion

// SceneCmd (command output):
Destroyed {
    scene_id: String,
    result: Result<bool, String>,
},

// SceneOutput (bubble up to app):
SceneDeleted { scene_id: String },
```

**Delete button:** A "Danger Zone" section at the bottom of the loaded
stack, below the file `PreferencesGroup`. Contains a heading label and a
`destructive-action` styled button labeled "Delete Scene". Visible only
when the scene is loaded.

**Confirmation:** On `SceneMsg::Destroy`, present an `AdwMessageDialog`:
- Heading: "Delete Scene"
- Body: "Permanently delete \"{title}\"? This cannot be undone."
- Response "cancel" → dismiss
- Response "delete" → spawn `SceneCmd::Destroyed` via `oneshot_command`

**Post-delete navigation:** In `update_cmd_with_view` for
`SceneCmd::Destroyed`:
- On success: emit `SceneOutput::SceneDeleted { scene_id }`, then navigate
  to the next neighbor. If no neighbor exists, pop back to library via
  `root.activate_action("navigation.pop", …)`.
- On failure: show an `AdwToast` with the error message.

### App routing (`app.rs`)

New field on `AppModel`:
```rust
current_scene_id: Option<String>,
```
Set on `AppMsg::OpenScene`, cleared on `AppMsg::NavPopped` (when scene
controller is dropped).

New `AppMsg` variant:
```rust
SceneDeleted { scene_id: String },
```

`SceneOutput::SceneDeleted` forwards to `AppMsg::SceneDeleted` in the
`forward()` closure. Handler: sends `LibraryMsg::RemoveScene(scene_id)` to
the library controller.

### Library page (`pages/library.rs`)

#### Right-click context menu

**Per-card popover:** In `append_cell`, each `FlowBoxChild` gets:
- A `gtk::Popover` containing a single `destructive-action` "Delete Scene"
  button. The button's `connect_clicked` captures the `scene_id` and sender
  and dispatches `LibraryMsg::DeleteRequested(scene_id)`.
- A `gtk::GestureClick` with `set_button(3)` (right mouse button) that
  calls `popover.popup()` on press.

**Confirmation:** `LibraryMsg::DeleteRequested(id)` handler shows an
`AdwMessageDialog` identical to the scene page's. On confirm, spawns an
async command calling `client.destroy_scene(&id)`, returning
`LibraryCmd::Destroyed { scene_id, result }`.

**New message variants:**
```rust
// LibraryMsg:
DeleteRequested(String),
RemoveScene(String),  // sent by app when scene page deletes

// LibraryCmd:
Destroyed {
    scene_id: String,
    result: Result<bool, String>,
},

// LibraryOutput:
SceneDeleted { scene_id: String },
```

#### Cache invalidation

Two paths feed into cache removal:

**A. Library deletes its own scene** (`LibraryCmd::Destroyed` success):
- Find position in `self.scene_ids`, remove from `Vec`
- Remove cell from `self.cells` HashMap
- Remove `FlowBoxChild` from grid via `widgets.grid.row_at_index()` then
  `widgets.grid.remove()`
- Decrement `self.loaded` and `self.total`
- Emit `LibraryOutput::SceneDeleted { scene_id }`

**B. Scene page deleted the scene** (`LibraryMsg::RemoveScene(id)`):
- Same cache removal logic as above
- No confirmation needed (scene page already confirmed)

#### Scene page pop on deletion

In `app.rs`, `LibraryOutput::SceneDeleted` handler: if
`self.current_scene_id == Some(scene_id)`, pop the scene page off the
navigation stack so the user doesn't stare at a deleted scene.

## macOS app (`apps/macos/`)

### `AppState.swift`

Add method wrapping the FFI call:
```swift
func destroyScene(id: String) -> Bool {
    guard let player = stashPlayer else { return false }
    return player.destroyScene(id: id)
}
```

### `SceneView.swift`

Add `@State private var showDeleteConfirmation = false`.

In `InfoPopover`, add a destructive "Delete Scene" button below "Open in
Stash" via an `onDelete` closure prop.

When tapped, sets `showDeleteConfirmation = true`. The SwiftUI `.alert`
modifier shows the confirmation dialog:
- "Delete Scene" title
- "Permanently delete \"{title}\"? This cannot be undone." message
- Cancel + Delete (destructive role) buttons
- On Delete: call `app.destroyScene(id:)`, then navigate to next neighbor
  (same pattern as prev/next). If none, pop to library.

### Library invalidation (macOS)

The macOS library fetches from the server via `AppState.listScenes` on
appear, so a deleted scene naturally disappears on the next navigation back
to the library. For a seamless experience, after a successful deletion on
the scene page, optionally force a library refresh.

No right-click context menu on macOS library cards in this round.

## Testing

- `stash-api` integration test: wiremock fixture for `sceneDestroy`,
  verify the mutation sends the correct variables and returns `true`.
- UI changes are not tested by policy (relm4 + GStreamer needs end-to-end
  runs).
- Manual QA: delete from scene page (verify nav to next neighbor), delete
  from library right-click (verify card removal), delete the only scene in
  a filter (verify pop to library), delete the currently-open scene from
  library (verify scene page pops).
