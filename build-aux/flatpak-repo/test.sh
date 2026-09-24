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
	fpr=$(GNUPGHOME=$1 gpg --list-keys --with-colons | awk -F: '/^fpr/ {print $10; exit}')
	GNUPGHOME=$1 gpg --export "$fpr" >"$2"
	echo "$fpr"
}

export GNUPGHOME=$work/gnupg
# shellcheck disable=SC2034
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
