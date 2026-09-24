# Flatpak repository for auto-updates

Status: approved design, 2026-09-24.

## Goal

Today each `v*` tag attaches `stash-player.flatpak` (~9.4 MB) to the GitHub
release, and Linux users update by reinstalling it by hand. Publish a signed
OSTree repository instead, so GNOME Software's background updates and plain
`flatpak update` pick up every stable release — the Linux counterpart of the
macOS Sparkle appcast.

Out of scope: Flathub (its offline build would mean vendoring the Flutter SDK
and pub cache), a beta/pre-release channel, in-app update UI, and changing
the ref's branch (it stays `master`, what the bundle already installs).

## 1. Hosting and layout

The repo lives on the existing `gh-pages` branch, served at
`https://arsfeld.github.io/stash-player/`, next to `appcast.xml`:

```
flatpak/
  repo/                                 # OSTree archive-z2 repo, GPG-signed summary + commits
  stash-player.flatpakrepo              # remote definition
  dev.arsfeld.stash-player.flatpakref   # one-click install
```

- `stash-player.flatpakrepo`: `Title=Stash Player`,
  `Url=https://arsfeld.github.io/stash-player/flatpak/repo/`,
  `Homepage=https://github.com/arsfeld/stash-player`, `GPGKey=<base64 public key>`.
- `dev.arsfeld.stash-player.flatpakref`: `Name=dev.arsfeld.stash-player`,
  `Branch=master`, the same `Url`/`GPGKey`/`Title`,
  `SuggestRemoteName=stash-player`, `IsRuntime=false`, and
  `RuntimeRepo=https://dl.flathub.org/repo/flathub.flatpakrepo` so the GNOME 50
  runtime and `codecs-extra` resolve from Flathub.
- Both files are rendered by one script,
  `build-aux/flatpak-repo/render-remote-files.sh` (arguments: public key
  file, output dir), reading the URL/app-id constants from
  `build-aux/flatpak-repo/common.sh`, so they have a single source of truth.
- `index.html` on `gh-pages` (today a one-line pointer to the appcast)
  becomes versioned at `build-aux/flatpak-repo/index.html` — the install
  command, a link to the `.flatpakref`, and the appcast link — and the
  publish job copies it into `gh-pages` on every publish.

## 2. Signing

A dedicated GPG key (ed25519, no passphrase, signing-only, used for nothing
else).

- Private key, ASCII-armored: repo secret `FLATPAK_GPG_PRIVATE_KEY`.
- Public key: committed at `build-aux/flatpak-repo/stash-player.gpg`
  (binary export), consumed by the render script, the verification step,
  and the bundle re-export.
- Generating the key and adding the secret is a one-time step; the
  implementation plan lists the exact commands.

## 3. CI

The `build` job is unchanged. (The `flatpak-builder` action's
`repository-url` input only sets where the *runtime* comes from, not the
app's origin, so the bundle's origin is set by re-exporting it — step 6.)

### Publishing script

`build-aux/flatpak-repo/publish.sh BUNDLE SITE_DIR KEY_ID PUBKEY OUT_BUNDLE`
(needs `GNUPGHOME` holding `KEY_ID`) does all repo work, so CI and the local
test run the same code:

1. If `SITE_DIR/flatpak/repo` doesn't exist, `ostree init
   --mode=archive-z2` it.
2. Import the bundle into a fresh *staging* repo
   (`flatpak build-import-bundle --no-update-summary`), then
   `flatpak build-commit-from --src-repo=staging --gpg-sign=KEY_ID` into the
   real repo. A bundle's commit has no parent, so importing it directly
   would replace the previous version outright; `build-commit-from` makes a
   new signed commit whose parent is the current head, which is what gives
   rollback history and incremental deltas.
3. `flatpak build-update-repo --gpg-sign=KEY_ID --generate-static-deltas
   --prune --prune-depth=2 --title="Stash Player"` — keeps the current
   commit plus two prior (rollback via `flatpak update --commit=`), with a
   delta from the previous commit.
4. Render the `.flatpakrepo` / `.flatpakref` into `SITE_DIR/flatpak/`.
5. Verify (`build-aux/flatpak-repo/verify.sh SITE_DIR/flatpak`), before
   anything is pushed:
   - `ostree fsck` on the repo;
   - in a scratch installation (`FLATPAK_USER_DIR` in a temp dir), add a
     remote from a copy of the rendered `.flatpakrepo` whose `Url=` is
     rewritten to `file://` the local repo — so the rendered `GPGKey` is
     what gets trusted — then `flatpak remote-info --show-commit` for
     `dev.arsfeld.stash-player` must equal the repo's head commit.
     A wrong or missing key fails here (summary signature check).
6. `flatpak build-bundle --repo-url=<repo url> --runtime-repo=<Flathub
   .flatpakrepo> --gpg-keys=PUBKEY` re-exports the bundle to `OUT_BUNDLE`.
   Installing it registers our repo as the app's origin, so bundle users
   also get updates.

### New `publish-repo` job in `flatpak.yml`

- `needs: [build, release]`; runs only for stable tags:
  `startsWith(github.ref, 'refs/tags/v') && !contains(github.ref, '-')`.
- Container `ghcr.io/flathub-infra/flatpak-github-actions:gnome-50`
  (`--privileged`), for `flatpak` and `ostree`.
- `permissions: contents: write`.
- `concurrency: { group: appcast-publish, cancel-in-progress: false }` — the
  same group as `macos.yml`'s `appcast` job. Concurrency groups are
  repo-wide, so the two never write `gh-pages` at once.

Steps: download the bundle artifact; check out `gh-pages` (depth 1) into
`gh-pages/`; copy `build-aux/flatpak-repo/index.html` over its `index.html`; import `FLATPAK_GPG_PRIVATE_KEY` into a temporary `GNUPGHOME`
(fail if empty); run `publish.sh`; then publish `gh-pages` as a single
orphan commit, so repo objects never accumulate in git history
(`git checkout --orphan next`, `git add -A` — carrying `appcast.xml`,
`index.html`, `.nojekyll`, `flatpak/` — commit `flatpak: $GITHUB_REF_NAME`,
`git push --force origin next:gh-pages`); finally re-upload the
re-exported `stash-player.flatpak` to the release, overwriting the one the
`release` job attached.

The macOS `appcast` job needs no change: it checks out `gh-pages` fresh and
fast-forwards on top of whatever is there, and the shared concurrency group
orders it relative to the force-push.

Size: the bundle is ~9.4 MB, so three commits plus deltas stay around
20–40 MB — far under Pages' 1 GB limit.

## 4. Failure handling

- Missing or invalid signing secret → the job fails before touching
  anything; the release keeps the bundle the `release` job attached.
- Any verification failure (step 5) → nothing is pushed; Pages keeps
  serving the last good repo.
- Push failure → job fails; rerunning it is safe — it starts from the live
  `gh-pages` again, at worst adding one more commit with identical content.

## 5. Migration and docs

- Existing bundle installs (≤ 1.2.0) have no remote. They reinstall once — from
  the new bundle or the `.flatpakref` — noted in the next release's notes
  and the README.
- Root `README.md` "Install → Linux (Flatpak)": lead with the `.flatpakref`
  install; updates arrive via GNOME Software / `flatpak update`; the bundle
  remains as an alternative that also subscribes to updates.
- `apps/flutter/README.md` "Releasing": the `publish-repo` job and the
  `FLATPAK_GPG_PRIVATE_KEY` secret.
- `CLAUDE.md` Flatpak notes: the repo location, the signing secret, and the
  shared `appcast-publish` concurrency group with its force-push.

## 6. Testing

- `build-aux/flatpak-repo/test.sh` (run via `just flatpak-repo-test`)
  exercises `publish.sh` end to end with a throwaway key against the real
  v1.1.0 and v1.2.0 release bundles: the rendered files' fields, the
  parent chain, the incremental delta, pruning to three commits, the
  re-exported bundle, and that verification rejects a repo signed by a
  different key.
- CI runs `test.sh` in the same gnome-50 container on every push/PR
  (bundles fetched by public release URL, so no token is needed) — which
  also proves the container has the tools the publish job relies on.
- In CI, `verify.sh` (step 5) gates every publish.
- Manual acceptance, once: after the first publishing release, install from
  the `.flatpakref` on a clean user installation; after the next tag,
  confirm `flatpak update` and GNOME Software offer the new version.
