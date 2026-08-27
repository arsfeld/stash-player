# Stash Tunnel: peer-to-peer access without exposing Stash

Design spec — 2026-08-27

## Summary

A Stash plugin plus a client-side proxy that let `stash-player` reach a
home Stash server from anywhere, without port-forwarding, a reverse
proxy, a public DNS record, or a VPN.

A daemon runs alongside Stash and holds an [iroh](https://iroh.computer)
QUIC endpoint. Client devices dial it *by public key*. The client side
re-exposes the connection as a plain HTTP server on `127.0.0.1`, so
every existing consumer — `stash-api`'s reqwest client, GStreamer,
AVPlayer, a browser — sees an ordinary local Stash and needs no
awareness of the transport.

## Requirements

Locked during design:

| Question | Decision |
| --- | --- |
| Who connects | Single owner. Only the user's own devices. No invite/sharing model. |
| Client surface | A loopback HTTP proxy anything can use, shipped both embedded in the apps and as a standalone CLI. |
| Daemon lifecycle | One binary, two launch modes: supervised service (primary) and Stash plugin task (secondary), mutually excluded by a lock file. |
| Distribution | A real public plugin, installable from Stash's plugin manager via a self-hosted index. |
| Client scope at v1 | CLI plus in-process embedding in the Rust apps (GTK + macOS). Flutter points at the CLI. |
| Transport | iroh. |

## Why iroh

iroh reached 1.0 in June 2026 (1.1.0 as of 2026-08-25), so the API-churn
objection that used to count against it no longer holds.

It fits because it needs no account and no rented server, it is
Rust-native and drops into this workspace beside the existing crates,
QUIC gives end-to-end encryption by construction, and its ed25519
identity model *is* the authorization allowlist — so authorization is
inherited rather than bolted on.

Alternatives considered:

- **Tailscale via `tsnet`.** Better-proven NAT traversal and generous
  DERP relays, but it requires a Tailscale account and auth key, which
  is a real wall for a plugin anyone can install. It also drags a Go
  toolchain into a Rust repo and adds little over simply running
  `tailscale up` on the host.
- **Self-hosted rendezvous/relay** (VPS with frp, or SSH `-R`).
  Rejected: it means renting a box, relaying every byte of video through
  it, and operating internet-facing infrastructure — the exact thing
  this feature exists to avoid.

**Known weakness.** When hole-punching fails, iroh falls back to n0's
public relays, which are rate-limited and documented as development and
testing infrastructure. Video over relay will be poor. Mitigations: a
`relayUrl` setting pointing at a self-hosted `iroh-relay`, and surfacing
direct-vs-relayed state in the UI so degradation is visible instead of
mysterious.

## Constraints discovered in Stash

These were verified against `stashapp/stash@develop` and drove several
design decisions.

- **No startup hook.** Every value in `pkg/plugin/hook.TriggerEnum` is a
  data-mutation event (`Scene.Create.Post`, `Tag.Merge.Post`, …). Nothing
  fires when Stash boots, so a plugin daemon cannot self-start on
  restart. This is why the supervised service is the primary launch mode.
- **`exec[0]` resolution.** `Config.getExecCommand` runs
  `exec.LookPath(ret[0])` and, on failure, rewrites it relative to the
  plugin directory. `{pluginDir}` substitution applies to arguments but
  never to `ret[0]`. There is no `.exe` suffix handling.
- **The official Docker image is Alpine**, carrying only
  `ca-certificates`, `vips-tools`, and `ffmpeg`. No Python — so the usual
  Python-launcher pattern is unavailable, and a static musl binary is the
  natural fit.
- **`runPluginOperation(plugin_id: ID!, args: Map): Any`** runs
  immediately, bypasses the job queue, and returns plugin output
  synchronously. This is what makes a live pairing/status panel possible.
- **Plugin settings** are limited to `STRING`, `NUMBER`, and `BOOLEAN`.
- **`ui.javascript` / `ui.css` / `ui.assets`** are injected into the
  Stash web UI under a per-plugin CSP.
- **`external_host` overrides the request-derived base URL.**
  `BaseURLMiddleware` computes `scheme + "://" + r.Host + prefix`, but
  then unconditionally replaces it when `external_host` is configured:

  ```go
  externalHost := config.GetInstance().GetExternalHost()
  if externalHost != "" {
      baseURL = externalHost + prefix
  }
  ```

  Anyone who has put Stash behind a reverse proxy is likely to have this
  set, and every generated URL — `paths.stream` included — would then
  point around the tunnel at an unreachable host. See "URL rebasing"
  below.

## Architecture

### The core decision: never parse HTTP

The client listens on `127.0.0.1:PORT` and maps **each accepted TCP
connection to one QUIC bi-directional stream**, copying bytes in both
directions. No layer in the path understands HTTP.

This is what makes the feature small. Range requests, keep-alive,
chunked encoding, HLS playlists, and seeking all work with no
special-casing. The players and the Flutter Dart client need no changes
at all; `stash-api` needs one small, contained change (below).

Two consequences worth recording:

1. The proxy connects to Stash from `127.0.0.1`, so Stash treats it as a
   local request and its public-access tripwire stays satisfied.
2. Stash normally builds absolute URLs from the request `Host`, so
   `scene.paths.stream` comes back as `http://127.0.0.1:PORT/...` and
   self-consistently routes back through the tunnel — **except when
   `external_host` is configured**, which overrides it.

### URL rebasing

Rewriting URLs inside the proxy would mean parsing HTTP and JSON, which
would forfeit everything the raw-stream design buys. So the fix goes in
the client instead, one layer up.

`stash-api` gains a helper that re-points any absolute URL Stash returns
onto the client's own configured base URL, keeping path and query
intact. `authenticated_url` runs it, so every media URL the app consumes
is rebased before use.

This is worth doing on its own merits: it also fixes the pre-existing
case of a user whose Stash sits behind a reverse proxy with
`external_host` set to a hostname the client cannot resolve. The tunnel
just makes it mandatory.

### Repository layout

```
crates/stash-tunnel/       # lib: identity, ticket, authz, proto, control,
│                          #      server (feature), client (feature)
crates/stash-tunnel-cli/   # bin `stash-tunnel`: serve | connect | ctl | plugin
plugins/stash-tunnel/      # stash-tunnel.yml, launch.sh, ui/*.js, bin/<target>/
```

Two crates rather than one so the GUI apps depend on
`stash-tunnel` with `default-features = false, features = ["client"]`
and never compile the server half. This matches the workspace's existing
narrow-crate split.

### Server state location

State lives in `<stash-config-dir>/stash-tunnel/`. Stash reports the
plugin directory as `<stash-config-dir>/plugins/<name>`, so the config
directory is its grandparent; `STASH_TUNNEL_STATE_DIR` overrides the
result for anyone with a non-standard layout.

**Not** in `{pluginDir}`: Stash's plugin manager rewrites that directory
on upgrade, and losing `identity.key` would silently unpair every device.

```
<state-dir>/identity.key      # ed25519 secret, mode 0600
<state-dir>/authorized.json   # allowlist
<state-dir>/control.sock      # unix control socket
<state-dir>/daemon.lock       # flock, guards the two launch modes
<state-dir>/tunnel.log
```

### Launch modes

`serve` takes an exclusive `flock` on `daemon.lock` and exits cleanly
when it is already held. The Stash task is therefore a safe no-op when a
supervised instance is already running.

### Control plane

The daemon listens on a unix socket. The Stash plugin task is the *same
binary* in `ctl` mode: it connects to the socket, issues `status`,
`mint-ticket`, `list-peers`, or `revoke`, prints JSON to stdout, and
exits. Stash returns that JSON to the web UI through
`runPluginOperation`.

## Wire protocol and security

**ALPN** is `stash-tunnel/1`, so the endpoint answers nothing else.
Both ends hold ed25519 identities; the server's public key is its dial
address.

**Stream opcodes** — one byte, first on every bi-stream:

| Opcode | Name | Payload |
| --- | --- | --- |
| `0x01` | `PROXY` | raw bytes ↔ the Stash TCP socket |
| `0x02` | `PAIR` | postcard `{token, device_label}` → `{ok, server_label, stash_version}` |
| `0x03` | `PING` | health/latency probe, returns status |

**Authorization** is two-tier, since iroh surfaces the remote public key
after the handshake. A key present in `authorized.json` gets full access.
An unknown key may open **only** a `PAIR` stream; any `PROXY` attempt is
refused and the connection closed. The server's EndpointId is not secret
and travels through relays, so knowing it must buy an attacker nothing.

**Pairing** uses a 32-byte CSPRNG token, held in memory only, single-use,
with a 10-minute TTL, compared using `subtle::ConstantTimeEq`, and
invalidated after 5 failed attempts. It can only be minted through the
unix control socket — that is, by someone already authenticated to the
Stash web UI.

The ticket is postcard `{endpoint_id, relay_url, direct_addrs, token}`
rendered as Crockford base32 with a `stashtun1` prefix, chosen because it
is case-insensitive and therefore typeable. The plugin panel also renders
it as a QR code.

**Revocation** stays in scope despite the single-owner model, because it
is how a stolen laptop is handled. `ctl revoke <key>` removes the key
from the allowlist and closes any live connection using it.

### Threat model

- Stash gets no public port, no reverse proxy, and no DNS record — only
  outbound QUIC.
- QUIC/TLS 1.3 means relays carry ciphertext and cannot impersonate
  either end, because dialing is by public key. Relays do see metadata:
  which keys talk to which, and when.
- The Stash API key is still required. The tunnel is a layer on top, so a
  leaked device key alone does not open the library.
- The genuine soft spot is the pairing window, where a live token is a
  bearer credential. TTL, single use, the attempt cap, and visibility
  only inside authenticated Stash are the mitigations.
- The client's loopback listener is reachable by any process on that
  machine. It binds `127.0.0.1` only, and the docs say so rather than
  pretending otherwise.

## The plugin package

### Manifest

```yaml
name: Stash Tunnel
description: >
  Reach this Stash from anywhere over an encrypted peer-to-peer link,
  without exposing it to the internet.
version: 0.1.0
url: https://github.com/arsfeld/stash-player
exec:
  - /bin/sh
  - "{pluginDir}/launch.sh"
interface: raw
ui:
  javascript:
    - ui/stash-tunnel.js
  css:
    - ui/stash-tunnel.css
settings:
  stashUrl:
    displayName: Stash URL
    description: Where the tunnel forwards to. Defaults to http://127.0.0.1:9999.
    type: STRING
  relayUrl:
    displayName: Custom relay URL
    description: Optional self-hosted iroh relay. Blank uses the public relays.
    type: STRING
  allowRelayFallback:
    displayName: Allow relay fallback
    description: >
      Relay when a direct connection cannot be established. Public relays
      are rate-limited, so video will be slow.
    type: BOOLEAN
tasks:
  - name: Start Tunnel
    description: Start the tunnel daemon if it is not already running.
    defaultArgs:
      mode: start
  - name: Stop Tunnel
    description: Stop the tunnel daemon.
    defaultArgs:
      mode: stop
```

Passing the launcher as an *argument* to `/bin/sh` means the script never
needs its own exec bit, which sidesteps the question of whether zip
extraction preserves file modes. `launch.sh` reads `uname -s` / `uname
-m`, selects `bin/linux-amd64/` or `bin/linux-arm64/`, `chmod +x`es the
binary, and `exec`s it with `"$@"`.

The `raw` interface reads `PluginInput` JSON on stdin and writes
`PluginOutput` on stdout. `mode: start` must double-fork, `setsid`,
redirect stdio to the log, and return immediately, or Stash's task queue
blocks — the same shape CommunityScripts' `FileMonitor` uses.

### The Docker caveat

In the official image `stash` is PID 1. If Stash exits the container
dies, taking any detached child with it. **In Docker the plugin-task
launch mode cannot survive a restart; the sidecar container is the only
reliable mode there.** The plugin-task mode is for bare-metal installs.

For the sidecar to still serve the pairing UI, it must share the Stash
config volume so both containers see `<state-dir>/control.sock`. The
docs ship a compose snippet doing exactly that.

### Platform scope at v1

**Linux amd64 and arm64 only** — Docker, unRAID, Synology, and TrueNAS,
which is where Stash servers actually live. Two stripped musl binaries
put the package at roughly 20 MB, shipped as a single zip so the user
never has to pick an architecture.

Windows cannot use the `/bin/sh` launcher at all (no `/bin/sh` on PATH,
no `.exe` suffix handling in `getExecCommand`) and would need its own
package. macOS-hosted Stash likewise. Both are deferred.

`index.yml` is published to the existing `gh-pages` branch by CI on tag.

## Client integration

`stash-player-core::config` grows:

```rust
enum Connection {
    Direct { url: String },
    Tunnel { endpoint_id: String },
}
```

The client secret key goes in the keyring beside the API key, because it
is a credential. The EndpointId is plain config.

On launch in tunnel mode the app starts the in-process proxy on an
ephemeral loopback port and builds `stash_api::Client` against
`http://127.0.0.1:<port>`. Beyond `stash-api`'s URL rebasing, nothing
else in either app changes.

- **GTK** — an Adw connection-mode selector, a ticket entry row, and a
  status row showing Direct / Relayed / Disconnected, following the
  libadwaita-first convention (`AdwPreferencesGroup`, `AdwEntryRow`,
  `AdwBanner` for the relayed/degraded state).
- **macOS** — `stash-player-ffi` gains `tunnel_pair(ticket)`,
  `tunnel_start() -> u16`, `tunnel_stop()`, and `tunnel_status()`, sync
  over the existing global runtime, matching the crate's established
  pattern.
- **Flutter** — no code at v1; it points at the CLI's port.

## Failure handling and observability

- Reconnect with jittered exponential backoff, capped at ~30s.
- While disconnected, the loopback listener still accepts and writes a
  minimal `HTTP/1.1 502 Bad Gateway` with a short body before closing.
  This is a deliberate small layering compromise: a real error beats a
  connection reset.
- Direct-vs-relayed comes off iroh's connection-type watcher into both
  `ctl status` and the app UI.
- The daemon logs to `<state-dir>/tunnel.log` via `tracing-subscriber`,
  matching the repo's `RUST_LOG` convention.

## Testing

Following the repo convention that core crates are tested and GUI crates
are not:

- **Unit** — ticket round-trip, base32 parse tolerance, atomic allowlist
  writes, pairing token TTL / single-use / attempt-cap, opcode framing.
- **Integration (headline, fully hermetic)** — two iroh endpoints in one
  test process with a `wiremock` server standing in for Stash behind the
  server half, driving requests through the client's loopback listener.
  Asserts that a Range request returns the correct byte slice and that a
  multi-MB body streams intact. Uses `wiremock` exactly as `stash-api`'s
  existing suite does.
- **Rejection** — an unpaired key is refused a `PROXY` stream.
- **Revocation** — a live connection dies on revoke.
- **URL rebasing** (`stash-api`, fixture-backed like the existing suite)
  — an absolute URL carrying a foreign `external_host` is re-pointed at
  the configured base URL with path and query preserved, and an
  already-local URL is left alone.
- **CI** — adds both musl targets and smoke-runs the native one.

Workspace clippy ceilings apply as everywhere else (100 lines/fn, no
`#[allow]`), so the accept loop and CLI dispatch are decomposed from the
start rather than after the lint fires.

## Out of scope

- Sharing with other people: invites, per-peer capabilities, read-only
  access.
- Windows- and macOS-hosted Stash servers.
- In-process embedding in the Flutter client.
- Submission to the CommunityScripts plugin index.
- Replacing Stash's own authentication. The API key remains required.
