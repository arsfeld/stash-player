#!/usr/bin/env bash
# Adds BUNDLE as the next signed commit of the Flatpak repo at
# SITE_DIR/flatpak/repo, refreshes its summary, deltas and pruning, renders
# the remote files next to it, verifies the result, and re-exports the bundle
# to OUT_BUNDLE with the repo as its origin (so bundle installs update too).
# Usage: publish.sh BUNDLE SITE_DIR KEY_ID PUBKEY OUT_BUNDLE
# GNUPGHOME must hold KEY_ID's secret key.
set -euo pipefail

here=$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)
# shellcheck source=common.sh disable=SC1091
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

[[ -d $repo ]] || { mkdir -p "$repo"; ostree init --mode=archive-z2 --repo="$repo"; }

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
