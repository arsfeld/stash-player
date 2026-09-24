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
- Both files are rendered by one script, `build-aux/flatpak-repo-files.sh`
  (arguments: public key file, output dir), so the URL and key have a single
  source of truth.
- `index.html` on `gh-pages` gains a short install section (the `flatpak
  install` command and a link to the `.flatpakref`). It is a one-time edit
  to the branch; the publish job carries existing files forward (§3).

## 2. Signing

A dedicated GPG key (no passphrase, signing-only, used for nothing else).

- Private key, ASCII-armored: repo secret `FLATPAK_GPG_PRIVATE_KEY`.
- Public key: committed at `build-aux/flatpak-repo.gpg` (binary export),
  consumed by `flatpak-repo-files.sh` and the verification step.
- Generating the key and adding the secret is a manual one-time step for
  the maintainer; the implementation plan lists the exact commands.

## 3. CI

### `build` job change

The `flatpak-builder` step in `.github/workflows/flatpak.yml` gains
`repository-url: https://arsfeld.github.io/stash-player/flatpak/stash-player.flatpakrepo`
and `repository-name: stash-player`. Installing the released bundle then
registers the `stash-player` remote as its origin, so bundle users also get
updates.

### New `publish-repo` job

- `needs: build`; runs only for stable tags:
  `startsWith(github.ref, 'refs/tags/v') && !contains(github.ref, '-')`.
- Container `ghcr.io/flathub-infra/flatpak-github-actions:gnome-50`
  (`--privileged`), for `flatpak` and `ostree`.
- `permissions: contents: write`.
- `concurrency: { group: appcast-publish, cancel-in-progress: false }` — the
  same group as `macos.yml`'s `appcast` job. Concurrency groups are
  repo-wide, so the two never write `gh-pages` at once.

Steps:

1. Download the `stash-player-x86_64.flatpak` artifact; check out
   `gh-pages` (depth 1) into `gh-pages/`.
2. Import `FLATPAK_GPG_PRIVATE_KEY` into a temporary `GNUPGHOME`; fail if
   the secret is empty.
3. If `gh-pages/flatpak/repo` doesn't exist, `ostree init --mode=archive-z2`
   it.
4. `flatpak build-import-bundle --gpg-sign=$KEY --gpg-homedir=$GNUPGHOME
   gh-pages/flatpak/repo stash-player.flatpak`.
5. `flatpak build-update-repo --gpg-sign=$KEY --gpg-homedir=$GNUPGHOME
   --generate-static-deltas --prune --prune-depth=3 --title="Stash Player"
   gh-pages/flatpak/repo` — keeps the current commit plus two prior (rollback
   via `flatpak update --commit=`), with static deltas from those.
6. Render the `.flatpakrepo` / `.flatpakref` via `flatpak-repo-files.sh`.
7. Verify, before anything is pushed:
   - `ostree fsck --repo=gh-pages/flatpak/repo`;
   - in a scratch installation (`FLATPAK_USER_DIR` in a temp dir),
     `flatpak remote-add --user test gh-pages/flatpak/stash-player.flatpakrepo`
     (so the rendered file's `GPGKey` is what gets trusted), then
     `flatpak remote-modify --user --url=file://$PWD/gh-pages/flatpak/repo test`
     to point it at the local copy, then
     `flatpak remote-ls --user test` must list `dev.arsfeld.stash-player`
     and `flatpak remote-info --user test dev.arsfeld.stash-player` must
     report the version being released.
8. Publish as a single orphan commit, so repo objects never accumulate in
   git history: in `gh-pages/`, `git checkout --orphan next`, `git add -A`
   (carries `appcast.xml`, `index.html`, `.nojekyll`, `flatpak/`), commit
   `flatpak: $GITHUB_REF_NAME`, `git push --force origin next:gh-pages`.

The macOS `appcast` job needs no change: it checks out `gh-pages` fresh and
fast-forwards on top of whatever is there, and the shared concurrency group
orders it relative to the force-push. Its existing `pull --rebase` retry
only runs if a push races, which the group prevents.

Size: the bundle is ~9.4 MB, so three commits plus deltas stay well within
tens of MB — far under Pages' 1 GB limit.

## 4. Failure handling

- Missing or invalid signing secret → the job fails at step 2; the release
  and its bundle are unaffected (the `release` job is independent).
- Any verification failure (step 7) → nothing is pushed; Pages keeps
  serving the last good repo.
- Push failure → job fails; rerunning it is safe because steps 3–8 are
  idempotent against the checked-out branch.

## 5. Migration and docs

- Existing 1.1.0 bundle installs have no remote. They reinstall once — from
  the new bundle or the `.flatpakref` — noted in the next release's notes
  and the README.
- `apps/flutter/README.md`: an "Install on Linux" section with the
  `.flatpakref` command and a note that updates arrive via GNOME Software /
  `flatpak update`.
- `CLAUDE.md` Flatpak notes: the repo location, the signing secret, and the
  shared `appcast-publish` concurrency group with its force-push.

## 6. Testing

- Automated: step 7 gates every publish.
- `flatpak-repo-files.sh` is exercised by that same step (the scratch
  remote is added from its output's key).
- Manual acceptance, once: after the first publishing release, install from
  the `.flatpakref` on a clean user installation; after the next tag,
  confirm `flatpak update` and GNOME Software offer the new version.
