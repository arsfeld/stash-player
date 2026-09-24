# Flatpak Repository Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Publish a GPG-signed Flatpak (OSTree) repository on GitHub Pages on every stable release, so installs auto-update via GNOME Software / `flatpak update`.

**Architecture:** Three bash scripts under `build-aux/flatpak-repo/` do all repo work (render remote files, publish a bundle as the next signed commit, verify as a client would); a bash end-to-end test drives them against real release bundles with a throwaway key. A new `publish-repo` job in `.github/workflows/flatpak.yml` runs the publish script against a checkout of `gh-pages`, force-pushes it as one orphan commit, and replaces the release's bundle with a re-export whose origin is the repo.

**Tech Stack:** bash, `flatpak` 1.18 (`build-import-bundle`, `build-commit-from`, `build-update-repo`, `build-bundle`), `ostree`, GnuPG, GitHub Actions, `just`.

**Spec:** `docs/superpowers/specs/2026-09-24-flatpak-repo-design.md`

## Global Constraints

- App id `dev.arsfeld.stash-player`, branch `master`, remote name `stash-player`, title `Stash Player`.
- Repo URL `https://arsfeld.github.io/stash-player/flatpak/repo/`; files live in `gh-pages` under `flatpak/`.
- Runtime repo `https://dl.flathub.org/repo/flathub.flatpakrepo`.
- Stable tags only: `startsWith(github.ref, 'refs/tags/v') && !contains(github.ref, '-')`.
- `--prune-depth=2` (current commit + two prior).
- Signing secret name `FLATPAK_GPG_PRIVATE_KEY`; public key at `build-aux/flatpak-repo/stash-player.gpg`.
- Concurrency group `appcast-publish`, `cancel-in-progress: false` (shared with `macos.yml`'s `appcast` job).
- Work on branch `flatpak-repo` (create it before Task 1: `git checkout -b flatpak-repo`); pushing it happens in Task 4 — confirm with the user first.
- `docs/` is gitignored but tracked: add docs files with `git add -f`.
- Scripts are Linux-only; tools come from `nix shell nixpkgs#ostree nixpkgs#gnupg` locally (`flatpak` is on the host).

## Verified facts (from a spike against the v1.1.0 / v1.2.0 bundles)

- `flatpak build-import-bundle` needs an existing repo (`'repo' is not a valid repository` otherwise).
- A bundle's commit has **no parent**: importing v1.2.0 straight after v1.1.0 drops v1.1.0 on prune and produces no incremental delta. Importing into a staging repo and then `flatpak build-commit-from --src-repo=staging` into the real repo chains the commit onto the current head and yields a `FROM-TO` static delta.
- A scratch remote added with a different public key fails at `flatpak remote-add` with `Can't check signature: public key not found`.
- `ostree static-delta list` prints deltas as `FROMCHECKSUM-TOCHECKSUM` (and from-scratch ones as a bare checksum).
- `flatpak-github-actions`' `repository-url` input only sets `--runtime-repo`/`--install-deps-from`; it cannot set the app's origin — hence the re-export.

## File structure

| File | Responsibility |
|---|---|
| `build-aux/flatpak-repo/common.sh` | Sourced constants (ids, URLs). Single source of truth. |
| `build-aux/flatpak-repo/render-remote-files.sh` | Writes `stash-player.flatpakrepo` + `dev.arsfeld.stash-player.flatpakref` for a given public key. |
| `build-aux/flatpak-repo/verify.sh` | Client-eye check of a published `flatpak/` dir: fsck + signed summary + head commit. |
| `build-aux/flatpak-repo/publish.sh` | Adds a bundle as the next signed commit; update-repo; render; verify; re-export bundle. |
| `build-aux/flatpak-repo/test.sh` | End-to-end test with a throwaway key against real release bundles. |
| `build-aux/flatpak-repo/index.html` | The `gh-pages` landing page (install instructions + appcast link). |
| `build-aux/flatpak-repo/stash-player.gpg` | Public signing key (binary export). |
| `justfile` | `flatpak-repo-test` recipe. |
| `.github/workflows/flatpak.yml` | `repo-scripts` test job + `publish-repo` job. |
| `README.md`, `apps/flutter/README.md`, `CLAUDE.md` | Docs. |

---

### Task 1: Remote files renderer

**Files:**
- Create: `build-aux/flatpak-repo/common.sh`
- Create: `build-aux/flatpak-repo/render-remote-files.sh`
- Create: `build-aux/flatpak-repo/test.sh`
- Modify: `justfile` (new `flatpak` section before `# -------------------------------------------------------------------- rust`)

**Interfaces:**
- Produces: `common.sh` variables `APP_ID`, `BRANCH`, `REMOTE_NAME`, `REPO_TITLE`, `REPO_URL`, `HOMEPAGE`, `RUNTIME_REPO`.
- Produces: `render-remote-files.sh PUBKEY OUT_DIR` → writes `OUT_DIR/stash-player.flatpakrepo` and `OUT_DIR/dev.arsfeld.stash-player.flatpakref`; exit 0.
- Produces: `test.sh` skeleton with `fail`, `$work`, throwaway key `$key` / `$work/pub.gpg`, extended in Task 2.

- [ ] **Step 1: Write the constants file**

`build-aux/flatpak-repo/common.sh`:

```bash
# Shared constants for the Flatpak repo scripts. Sourced, not executed.
# shellcheck shell=bash disable=SC2034

APP_ID=dev.arsfeld.stash-player
BRANCH=master
REMOTE_NAME=stash-player
REPO_TITLE="Stash Player"
REPO_URL=https://arsfeld.github.io/stash-player/flatpak/repo/
HOMEPAGE=https://github.com/arsfeld/stash-player
# The GNOME runtime and codecs-extra come from Flathub.
RUNTIME_REPO=https://dl.flathub.org/repo/flathub.flatpakrepo
```

- [ ] **Step 2: Write the failing test**

`build-aux/flatpak-repo/test.sh` (then `chmod +x`):

```bash
#!/usr/bin/env bash
# End-to-end test of the Flatpak repo scripts, using a throwaway signing key
# and the real v1.1.0 / v1.2.0 release bundles. Needs flatpak, ostree, gpg,
# curl. Run via `just flatpak-repo-test`.
set -euo pipefail

here=$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)
# shellcheck source=common.sh
source "$here/common.sh"

work=$(mktemp -d)
trap 'rm -rf "$work"' EXIT
fail() {
	echo "FAIL: $*" >&2
	exit 1
}

# new_key HOMEDIR OUT_PUBKEY — prints the new key's fingerprint.
new_key() {
	mkdir -m700 "$1"
	GNUPGHOME=$1 gpg --batch --quiet --passphrase '' \
		--quick-gen-key 'Stash Player test key' ed25519 sign never 2>/dev/null
	local fpr
	fpr=$(GNUPGHOME=$1 gpg --list-keys --with-colons | awk -F: '/^fpr/ {print $10; exit}')
	GNUPGHOME=$1 gpg --export "$fpr" >"$2"
	echo "$fpr"
}

export GNUPGHOME=$work/gnupg
key=$(new_key "$GNUPGHOME" "$work/pub.gpg")
key_b64=$(base64 <"$work/pub.gpg" | tr -d '\n')

echo "== render-remote-files"
"$here/render-remote-files.sh" "$work/pub.gpg" "$work/rendered"
repo_file=$work/rendered/$REMOTE_NAME.flatpakrepo
ref_file=$work/rendered/$APP_ID.flatpakref
for line in "[Flatpak Repo]" "Title=$REPO_TITLE" "Url=$REPO_URL" "Homepage=$HOMEPAGE" "GPGKey=$key_b64"; do
	grep -qxF "$line" "$repo_file" || fail "$repo_file lacks: $line"
done
for line in "[Flatpak Ref]" "Name=$APP_ID" "Branch=$BRANCH" "Url=$REPO_URL" "IsRuntime=false" \
	"SuggestRemoteName=$REMOTE_NAME" "RuntimeRepo=$RUNTIME_REPO" "GPGKey=$key_b64"; do
	grep -qxF "$line" "$ref_file" || fail "$ref_file lacks: $line"
done

echo PASS
```

- [ ] **Step 3: Add the just recipe**

In `justfile`, insert before the `# -------------------------------------------------------------------- rust` line:

```just
# ----------------------------------------------------------------- flatpak

# End-to-end test of the Flatpak repo scripts in build-aux/flatpak-repo/
# (throwaway signing key, real release bundles; Linux only).
flatpak-repo-test:
    nix shell nixpkgs#ostree nixpkgs#gnupg --command build-aux/flatpak-repo/test.sh

```

- [ ] **Step 4: Run it to see it fail**

Run: `just flatpak-repo-test`
Expected: FAIL — `render-remote-files.sh: No such file or directory`.

- [ ] **Step 5: Write the renderer**

`build-aux/flatpak-repo/render-remote-files.sh` (then `chmod +x`):

```bash
#!/usr/bin/env bash
# Writes the remote definition (stash-player.flatpakrepo) and the one-click
# install file (dev.arsfeld.stash-player.flatpakref) into OUT_DIR, embedding
# PUBKEY (a binary `gpg --export`) as GPGKey=.
# Usage: render-remote-files.sh PUBKEY OUT_DIR
set -euo pipefail

here=$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)
# shellcheck source=common.sh
source "$here/common.sh"

pubkey=$1
out=$2
key_b64=$(base64 <"$pubkey" | tr -d '\n')
mkdir -p "$out"

cat >"$out/$REMOTE_NAME.flatpakrepo" <<EOF
[Flatpak Repo]
Title=$REPO_TITLE
Url=$REPO_URL
Homepage=$HOMEPAGE
GPGKey=$key_b64
EOF

cat >"$out/$APP_ID.flatpakref" <<EOF
[Flatpak Ref]
Title=$REPO_TITLE
Name=$APP_ID
Branch=$BRANCH
Url=$REPO_URL
Homepage=$HOMEPAGE
IsRuntime=false
SuggestRemoteName=$REMOTE_NAME
RuntimeRepo=$RUNTIME_REPO
GPGKey=$key_b64
EOF
```

- [ ] **Step 6: Run the test to see it pass**

Run: `just flatpak-repo-test`
Expected: `== render-remote-files` then `PASS`.

- [ ] **Step 7: Lint**

Run: `nix shell nixpkgs#shellcheck --command shellcheck -x build-aux/flatpak-repo/*.sh`
Expected: no output.

- [ ] **Step 8: Commit**

```bash
git add build-aux/flatpak-repo/common.sh build-aux/flatpak-repo/render-remote-files.sh build-aux/flatpak-repo/test.sh justfile
git commit -m "build(flatpak): render the repo's .flatpakrepo and .flatpakref"
```

---

### Task 2: Publish and verify scripts

**Files:**
- Create: `build-aux/flatpak-repo/verify.sh`
- Create: `build-aux/flatpak-repo/publish.sh`
- Modify: `build-aux/flatpak-repo/test.sh` (append cases before `echo PASS`)

**Interfaces:**
- Consumes: `common.sh`, `render-remote-files.sh PUBKEY OUT_DIR` (Task 1).
- Produces: `verify.sh FLATPAK_DIR` — `FLATPAK_DIR` contains `repo/` and `stash-player.flatpakrepo`; exit 0 and prints `verify: <ref> at <commit>, signature OK`, nonzero on any failure.
- Produces: `publish.sh BUNDLE SITE_DIR KEY_ID PUBKEY OUT_BUNDLE` — requires `GNUPGHOME` set; creates/updates `SITE_DIR/flatpak/{repo/,stash-player.flatpakrepo,dev.arsfeld.stash-player.flatpakref}` and writes `OUT_BUNDLE`.

- [ ] **Step 1: Write the failing tests**

In `build-aux/flatpak-repo/test.sh`, replace the final `echo PASS` with:

```bash
# Release bundles are cached across runs; they never change once published.
bundles=${XDG_CACHE_HOME:-$HOME/.cache}/stash-player-flatpak-test
mkdir -p "$bundles"
for v in v1.1.0 v1.2.0; do
	[[ -s $bundles/$v.flatpak ]] || curl -fsSL -o "$bundles/$v.flatpak" \
		"https://github.com/arsfeld/stash-player/releases/download/$v/stash-player.flatpak"
done

site=$work/site
repo=$site/flatpak/repo
ref=app/$APP_ID/$(flatpak --default-arch)/$BRANCH
publish() {
	"$here/publish.sh" "$bundles/$1.flatpak" "$site" "$key" "$work/pub.gpg" "$work/out.flatpak" >/dev/null
}
head_of() { ostree rev-parse --repo="$repo" "$ref"; }
parent_of() { ostree log --repo="$repo" "$1" | awk '/^Parent:/ {print $2; exit}'; }

echo "== first publish initialises the repo"
publish v1.1.0
[[ -f $site/flatpak/$REMOTE_NAME.flatpakrepo ]] || fail "no .flatpakrepo in site"
[[ -f $site/flatpak/$APP_ID.flatpakref ]] || fail "no .flatpakref in site"
[[ -s $work/out.flatpak ]] || fail "no re-exported bundle"
first=$(head_of)

echo "== second publish chains onto the first, with a delta"
publish v1.2.0
second=$(head_of)
[[ $second != "$first" ]] || fail "head did not move"
[[ $(parent_of "$second") == "$first" ]] || fail "new commit's parent is not the previous head"
ostree static-delta list --repo="$repo" | grep -qxF "$first-$second" ||
	fail "no incremental delta $first-$second"

echo "== pruning keeps three commits"
publish v1.1.0
publish v1.2.0
commits=$(ostree log --repo="$repo" "$ref" | grep -c '^commit ')
[[ $commits == 3 ]] || fail "expected 3 commits after pruning, found $commits"

echo "== verify passes on the published site"
"$here/verify.sh" "$site/flatpak" >/dev/null || fail "verify rejected a good repo"

echo "== verify rejects a repo whose .flatpakrepo carries another key"
mkdir -p "$work/forged"
ln -s "$repo" "$work/forged/repo"
new_key "$work/other-gnupg" "$work/other.gpg" >/dev/null
"$here/render-remote-files.sh" "$work/other.gpg" "$work/forged"
if "$here/verify.sh" "$work/forged" >/dev/null 2>&1; then
	fail "verify accepted a repo signed by a different key"
fi

echo PASS
```

- [ ] **Step 2: Run to see it fail**

Run: `just flatpak-repo-test`
Expected: render cases pass, then FAIL at `== first publish` — `publish.sh: No such file or directory`.

- [ ] **Step 3: Write `verify.sh`**

`build-aux/flatpak-repo/verify.sh` (then `chmod +x`):

```bash
#!/usr/bin/env bash
# Checks a published flatpak/ directory the way a client would: the repo is
# intact, and a scratch installation that trusts only the rendered
# .flatpakrepo's GPGKey sees the repo's head commit for the app.
# Usage: verify.sh FLATPAK_DIR
set -euo pipefail

here=$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)
# shellcheck source=common.sh
source "$here/common.sh"

dir=$(cd "$1" && pwd)
repo=$dir/repo
ref=app/$APP_ID/$(flatpak --default-arch)/$BRANCH

ostree fsck --repo="$repo" >/dev/null
head=$(ostree rev-parse --repo="$repo" "$ref")

scratch=$(mktemp -d)
trap 'rm -rf "$scratch"' EXIT
# Same file, pointed at the local copy instead of the live site.
sed "s|^Url=.*|Url=file://$repo|" "$dir/$REMOTE_NAME.flatpakrepo" >"$scratch/local.flatpakrepo"

export FLATPAK_USER_DIR=$scratch/installation
mkdir -p "$FLATPAK_USER_DIR"
flatpak remote-add --user --from verify "$scratch/local.flatpakrepo"
published=$(flatpak remote-info --user --show-commit verify "$APP_ID")

if [[ $published != "$head" ]]; then
	echo "verify: remote serves $published, repo head is $head" >&2
	exit 1
fi
echo "verify: $ref at $head, signature OK"
```

- [ ] **Step 4: Write `publish.sh`**

`build-aux/flatpak-repo/publish.sh` (then `chmod +x`):

```bash
#!/usr/bin/env bash
# Adds BUNDLE as the next signed commit of the Flatpak repo at
# SITE_DIR/flatpak/repo, refreshes its summary, deltas and pruning, renders
# the remote files next to it, verifies the result, and re-exports the bundle
# to OUT_BUNDLE with the repo as its origin (so bundle installs update too).
# Usage: publish.sh BUNDLE SITE_DIR KEY_ID PUBKEY OUT_BUNDLE
# GNUPGHOME must hold KEY_ID's secret key.
set -euo pipefail

here=$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)
# shellcheck source=common.sh
source "$here/common.sh"

: "${GNUPGHOME:?GNUPGHOME must point at the keyring holding the signing key}"
bundle=$1
site=$2
key=$3
pubkey=$4
out=$5

repo=$site/flatpak/repo
ref=app/$APP_ID/$(flatpak --default-arch)/$BRANCH
sign=(--gpg-sign="$key" --gpg-homedir="$GNUPGHOME")

[[ -d $repo ]] || ostree init --mode=archive-z2 --repo="$repo"

# A bundle's commit has no parent, so importing it straight into the repo
# would replace the previous version rather than follow it — no rollback, no
# incremental delta. Stage it, then re-commit it on top of the current head.
staging=$(mktemp -d)
trap 'rm -rf "$staging"' EXIT
ostree init --mode=archive-z2 --repo="$staging"
flatpak build-import-bundle --no-update-summary "$staging" "$bundle"
flatpak build-commit-from --src-repo="$staging" --no-update-summary "${sign[@]}" "$repo" "$ref"

flatpak build-update-repo "${sign[@]}" --title="$REPO_TITLE" \
	--generate-static-deltas --prune --prune-depth=2 "$repo"

"$here/render-remote-files.sh" "$pubkey" "$site/flatpak"
"$here/verify.sh" "$site/flatpak"

flatpak build-bundle --repo-url="$REPO_URL" --runtime-repo="$RUNTIME_REPO" \
	--gpg-keys="$pubkey" "$repo" "$out" "$APP_ID" "$BRANCH"
```

- [ ] **Step 5: Run the tests to see them pass**

Run: `just flatpak-repo-test`
Expected: every `==` section prints, then `PASS`. (First run downloads ~19 MB of bundles into `~/.cache/stash-player-flatpak-test`.)

If the pruning case reports a count other than 3, check `flatpak build-update-repo --help` semantics against `ostree log` output before changing `--prune-depth`; the spec requires current + two prior.

- [ ] **Step 6: Lint**

Run: `nix shell nixpkgs#shellcheck --command shellcheck -x build-aux/flatpak-repo/*.sh`
Expected: no output.

- [ ] **Step 7: Commit**

```bash
git add build-aux/flatpak-repo/verify.sh build-aux/flatpak-repo/publish.sh build-aux/flatpak-repo/test.sh
git commit -m "build(flatpak): publish bundles as chained, signed repo commits"
```

---

### Task 3: Signing key

This task creates a real secret on GitHub. **Confirm with the user before Step 3**, and ask where they want the private-key backup (Step 2) — losing it means every user has to re-add the remote.

**Files:**
- Create: `build-aux/flatpak-repo/stash-player.gpg`

**Interfaces:**
- Produces: repo secret `FLATPAK_GPG_PRIVATE_KEY` (ASCII-armored secret key); `build-aux/flatpak-repo/stash-player.gpg` (binary public key) for Task 4's workflow.

- [ ] **Step 1: Generate the key in a throwaway keyring**

```bash
export GNUPGHOME=$(mktemp -d)
nix shell nixpkgs#gnupg --command bash -euc '
  gpg --batch --passphrase "" --quick-gen-key "Stash Player Flatpak repository" ed25519 sign never
  fpr=$(gpg --list-keys --with-colons | awk -F: "/^fpr/ {print \$10; exit}")
  echo "fingerprint: $fpr"
  gpg --export "$fpr" > build-aux/flatpak-repo/stash-player.gpg
  gpg --armor --export-secret-keys "$fpr" > "$GNUPGHOME/private.asc"
'
```

Expected: a `fingerprint:` line; `build-aux/flatpak-repo/stash-player.gpg` exists (a few hundred bytes).

- [ ] **Step 2: Back up the private key**

Copy `$GNUPGHOME/private.asc` to the location the user chose (e.g. their password manager). Do not put it anywhere inside the repo.

- [ ] **Step 3: Store it as the repo secret (after user confirmation)**

```bash
gh secret set FLATPAK_GPG_PRIVATE_KEY -R arsfeld/stash-player < "$GNUPGHOME/private.asc"
gh secret list -R arsfeld/stash-player | grep FLATPAK_GPG_PRIVATE_KEY
```

Expected: the secret is listed.

- [ ] **Step 4: Destroy the local copy**

```bash
rm -rf "$GNUPGHOME"; unset GNUPGHOME
```

- [ ] **Step 5: Commit the public key**

```bash
git add build-aux/flatpak-repo/stash-player.gpg
git commit -m "build(flatpak): add the repo's public signing key"
```

---

### Task 4: CI — test job and publish job

**Files:**
- Create: `build-aux/flatpak-repo/index.html`
- Modify: `.github/workflows/flatpak.yml` (add two jobs after `release`)

**Interfaces:**
- Consumes: `publish.sh BUNDLE SITE_DIR KEY_ID PUBKEY OUT_BUNDLE` (Task 2), `test.sh` (Tasks 1–2), `stash-player.gpg` + secret (Task 3), the `build` job's artifact `stash-player-x86_64.flatpak`.

- [ ] **Step 1: Write the landing page**

`build-aux/flatpak-repo/index.html`:

```html
<!doctype html>
<html lang="en">
<head><meta charset="utf-8"><title>Stash Player</title></head>
<body>
<h1>Stash Player</h1>
<p>Update feeds for <a href="https://github.com/arsfeld/stash-player">Stash Player</a>.</p>
<h2>Linux (Flatpak)</h2>
<p>Install from this repository and updates arrive through GNOME Software or <code>flatpak update</code>:</p>
<pre>flatpak install --user https://arsfeld.github.io/stash-player/flatpak/dev.arsfeld.stash-player.flatpakref</pre>
<p>Or open <a href="./flatpak/dev.arsfeld.stash-player.flatpakref">dev.arsfeld.stash-player.flatpakref</a>.
The repository alone: <a href="./flatpak/stash-player.flatpakrepo">stash-player.flatpakrepo</a>.</p>
<h2>macOS</h2>
<p>The Sparkle feed is <a href="./appcast.xml">appcast.xml</a>.</p>
</body>
</html>
```

- [ ] **Step 2: Add the jobs**

Append to `.github/workflows/flatpak.yml` (after the `release` job, same indentation as `build:` / `release:`):

```yaml
  repo-scripts:
    name: Test Flatpak repo scripts
    runs-on: ubuntu-latest
    # Same image as publish-repo, so a missing tool shows up here first.
    container:
      image: ghcr.io/flathub-infra/flatpak-github-actions:gnome-50
      options: --privileged
    steps:
      - name: Install tools
        run: &install-tools |
          missing=
          for tool in git ostree gpg curl; do command -v "$tool" >/dev/null || missing=1; done
          if [ -n "$missing" ]; then
            if command -v dnf >/dev/null; then dnf -y install git ostree gnupg2 curl
            else apt-get update && apt-get -y install git ostree gnupg curl; fi
          fi

      - name: Checkout
        uses: actions/checkout@v4

      - name: Test
        run: build-aux/flatpak-repo/test.sh

  publish-repo:
    name: Publish Flatpak repository
    needs: [build, release]
    # Stable tags only, like the Sparkle appcast.
    if: startsWith(github.ref, 'refs/tags/v') && !contains(github.ref, '-')
    runs-on: ubuntu-latest
    container:
      image: ghcr.io/flathub-infra/flatpak-github-actions:gnome-50
      options: --privileged
    permissions:
      contents: write
    # Shared with macos.yml's `appcast` job: both rewrite gh-pages, and this
    # one force-pushes it. Concurrency groups are repo-wide, so the two never
    # overlap.
    concurrency:
      group: appcast-publish
      cancel-in-progress: false
    steps:
      - name: Install tools
        run: *install-tools

      - name: Checkout
        uses: actions/checkout@v4
        with:
          path: src

      - name: Checkout gh-pages
        uses: actions/checkout@v4
        with:
          ref: gh-pages
          path: gh-pages
          fetch-depth: 1

      - name: Download bundle artifact
        uses: actions/download-artifact@v4
        with:
          name: stash-player-x86_64.flatpak
          path: bundle

      - name: Import signing key
        env:
          FLATPAK_GPG_PRIVATE_KEY: ${{ secrets.FLATPAK_GPG_PRIVATE_KEY }}
        run: |
          set -euo pipefail
          if [ -z "$FLATPAK_GPG_PRIVATE_KEY" ]; then
            echo "::error::FLATPAK_GPG_PRIVATE_KEY is not set"
            exit 1
          fi
          export GNUPGHOME="$RUNNER_TEMP/gnupg"
          mkdir -m700 "$GNUPGHOME"
          printf '%s\n' "$FLATPAK_GPG_PRIVATE_KEY" | gpg --batch --import
          echo "GNUPGHOME=$GNUPGHOME" >> "$GITHUB_ENV"
          echo "KEY_ID=$(gpg --list-secret-keys --with-colons | awk -F: '/^fpr/ {print $10; exit}')" >> "$GITHUB_ENV"

      - name: Publish repo
        # verify.sh (run by publish.sh) fails the job before anything is
        # pushed if the repo, its signature, or the rendered key is wrong.
        run: |
          set -euo pipefail
          src/build-aux/flatpak-repo/publish.sh \
            bundle/stash-player.flatpak gh-pages "$KEY_ID" \
            src/build-aux/flatpak-repo/stash-player.gpg stash-player.flatpak
          cp src/build-aux/flatpak-repo/index.html gh-pages/index.html

      - name: Push gh-pages
        # One orphan commit per publish, so OSTree objects never pile up in
        # git history. Carries appcast.xml and .nojekyll forward.
        working-directory: gh-pages
        run: |
          set -euo pipefail
          git config --global --add safe.directory "$PWD"
          git config user.name  "github-actions[bot]"
          git config user.email "41898282+github-actions[bot]@users.noreply.github.com"
          git checkout --orphan next
          git add -A
          git commit -q -m "flatpak: ${GITHUB_REF_NAME}"
          git push --force origin next:gh-pages

      - name: Replace release bundle
        # The re-export carries the repo as its origin, so installing the
        # bundle also subscribes to updates.
        uses: softprops/action-gh-release@v2
        with:
          files: stash-player.flatpak
```

If `actionlint` rejects the YAML anchor (`&install-tools` / `*install-tools`; GitHub Actions supports anchors, but older actionlint releases don't), duplicate the `Install tools` script literally in both jobs instead.

- [ ] **Step 3: Lint the workflow**

Run: `nix shell nixpkgs#actionlint --command actionlint .github/workflows/flatpak.yml`
Expected: no output.

- [ ] **Step 4: Commit, push the branch (after user confirmation), and confirm `repo-scripts` passes in CI**

```bash
git add build-aux/flatpak-repo/index.html .github/workflows/flatpak.yml
git commit -m "ci(flatpak): publish a signed Flatpak repository to gh-pages"
git push -u origin HEAD
gh run watch "$(gh run list --branch flatpak-repo --workflow flatpak.yml --limit 1 --json databaseId -q '.[0].databaseId')"
```

Expected: `Test Flatpak repo scripts` succeeds; `Publish Flatpak repository` and `Attach bundle…` are skipped (not a tag). If `Install tools` fails, fix the package names for the image's distro and repeat.

---

### Task 5: Documentation

**Files:**
- Modify: `README.md` ("### Linux (Flatpak)" section, lines ~42–63)
- Modify: `apps/flutter/README.md` ("## Releasing", first bullet)
- Modify: `CLAUDE.md` ("## Flatpak notes", last bullet)

- [ ] **Step 1: Root README install section**

Replace the body of `### Linux (Flatpak)` (from `Download \`stash-player.flatpak\`` through `To update, download the new bundle and run \`flatpak install\` again.`) with:

````markdown
Install from the Stash Player Flatpak repository:

```sh
flatpak install --user https://arsfeld.github.io/stash-player/flatpak/dev.arsfeld.stash-player.flatpakref
flatpak run dev.arsfeld.stash-player
```

Updates then arrive like any other Flatpak — GNOME Software's automatic
updates, or `flatpak update`. The GNOME runtime comes from Flathub, which
the `.flatpakref` adds if it isn't set up already.

Prefer a single file? Each [release](https://github.com/arsfeld/stash-player/releases/latest)
also has `stash-player.flatpak`; installing it with
`flatpak install --user stash-player.flatpak` subscribes to the same
repository, so it updates too.

Installed 1.2.0 or earlier from the bundle? That install has no update
source — run the `flatpak install` command above once to switch it over.
````

- [ ] **Step 2: Flutter README release notes**

In `apps/flutter/README.md`, replace the `flatpak.yml` bullet under `## Releasing` with:

```markdown
- [`flatpak.yml`](../../.github/workflows/flatpak.yml) builds the manifest
  in [`build-aux/dev.arsfeld.stash-player.yml`](../../build-aux/dev.arsfeld.stash-player.yml)
  and attaches `stash-player.flatpak` to the GitHub release. For stable
  tags, its `publish-repo` job then adds the build to the signed Flatpak
  repository on `gh-pages` (`build-aux/flatpak-repo/publish.sh`, signed
  with the `FLATPAK_GPG_PRIVATE_KEY` secret) and replaces the release's
  bundle with a re-export whose origin is that repository, so existing
  installs update. `just flatpak-repo-test` runs the publishing scripts
  locally against real release bundles.
```

- [ ] **Step 3: CLAUDE.md Flatpak notes**

Append to `## Flatpak notes` in `CLAUDE.md`:

```markdown
- Stable tags also publish a GPG-signed OSTree repo to `gh-pages` at `flatpak/repo/` (plus `stash-player.flatpakrepo` / `dev.arsfeld.stash-player.flatpakref`), via `flatpak.yml`'s `publish-repo` job running `build-aux/flatpak-repo/publish.sh`. Each bundle is staged and re-committed with `flatpak build-commit-from`, because a bundle's commit has no parent and importing it directly would drop the previous version and its delta. The job force-pushes `gh-pages` as a single orphan commit and shares the `appcast-publish` concurrency group with `macos.yml`'s `appcast` job. Signing key: secret `FLATPAK_GPG_PRIVATE_KEY`, public half at `build-aux/flatpak-repo/stash-player.gpg`. Test locally with `just flatpak-repo-test`.
```

Also change the existing release-tagging bullet's "attaches `stash-player.flatpak` to the GitHub release" to "attaches `stash-player.flatpak` to the GitHub release (replaced by `publish-repo`'s re-export on stable tags)".

- [ ] **Step 4: Commit and push**

```bash
git add README.md apps/flutter/README.md CLAUDE.md
git commit -m "docs: install and update from the Flatpak repository"
git push
```

---

## After merge (manual acceptance, not a task)

1. Tag the next stable release. Confirm `Publish Flatpak repository` succeeds, `https://arsfeld.github.io/stash-player/flatpak/stash-player.flatpakrepo` serves, and the macOS `appcast` job (same group) still pushes on top of the orphan commit.
2. On a clean user installation: `flatpak install --user <.flatpakref URL>`; `flatpak remotes --user` shows `stash-player`.
3. After the following tag, `flatpak update` (and GNOME Software) offers the new version.
