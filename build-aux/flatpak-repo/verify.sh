#!/usr/bin/env bash
# Checks a published flatpak/ directory the way a client would: the repo is
# intact, and a scratch installation that trusts only the rendered
# .flatpakrepo's GPGKey sees the repo's head commit for the app.
# Usage: verify.sh FLATPAK_DIR
set -euo pipefail

here=$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)
# shellcheck source=common.sh disable=SC1091
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
