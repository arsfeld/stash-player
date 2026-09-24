#!/usr/bin/env bash
# End-to-end test of the Flatpak repo scripts, using a throwaway signing key
# and the real v1.1.0 / v1.2.0 release bundles. Needs flatpak, ostree, gpg,
# curl. Run via `just flatpak-repo-test`.
set -euo pipefail

here=$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)
# shellcheck source=common.sh disable=SC1091
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
	fpr=$(GNUPGHOME=$1 gpg --list-keys --with-colons 2>/dev/null | awk -F: '/^fpr/ {print $10; exit}')
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

# Simulates what CI does between releases: commit the published site as a
# gh-pages checkout, then start the next publish from a fresh clone. Git
# doesn't track empty directories, which is exactly what exposes ostree's
# empty refs/remotes, refs/mirrors, tmp/cache, state and extensions going
# missing after the round trip. Git's own chatter is silenced so stdout
# stays limited to `==` lines and PASS. Old clones are left for $work's exit
# trap to clean up, rather than rm -rf'd here — git occasionally has a
# maintenance helper still touching .git/objects right after commit/clone,
# and racing it with rm -rf here caused sporadic "Directory not empty".
round_trip_site() {
	if [[ ! -d $site/.git ]]; then
		git init -q "$site" >/dev/null
	fi
	git -C "$site" -c user.name=t -c user.email=t@example.invalid add -A >/dev/null
	git -C "$site" -c user.name=t -c user.email=t@example.invalid \
		commit -q -m "flatpak: round-trip" >/dev/null
	local clone
	clone=$(mktemp -d "$work/clone-XXXXXX")
	rmdir "$clone"
	git clone -q "$site" "$clone" >/dev/null 2>&1
	site=$clone
	repo=$site/flatpak/repo
}
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

# Round-trip through git before the next publish, the way CI's gh-pages
# checkout does — this is what exposes ostree's empty dirs going missing.
round_trip_site

echo "== second publish chains onto the first, with a delta"
publish v1.2.0
second=$(head_of)
[[ $second != "$first" ]] || fail "head did not move"
[[ $(parent_of "$second") == "$first" ]] || fail "new commit's parent is not the previous head"
ostree static-delta list --repo="$repo" | grep -qxF "$first-$second" ||
	fail "no incremental delta $first-$second"

# Round-trip again so the pruning case also starts from a cloned site.
round_trip_site

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
