#!/usr/bin/env bash
# End-to-end tests for `mead upgrade`, the update notice, and scripts/install.sh,
# against a local server that mimics the GitHub releases API and downloads.
# Requires odin (or MEAD_ODIN), python3, and script(1) for the notice tests.
# Usage: tests/release.sh [path-to-mead]
set -uo pipefail

here=$(cd "$(dirname "$0")" && pwd)
repo_root=$(cd "$here/.." && pwd)
mead=$(realpath "${1:-$repo_root/build/mead}")
odin=${MEAD_ODIN:-odin}
work=$(mktemp -d "${TMPDIR:-/tmp}/mead-release.XXXXXX")
server_pid=""
cleanup() {
	[ -n "$server_pid" ] && kill "$server_pid" 2>/dev/null
	chmod -R u+w "$work" 2>/dev/null
	rm -rf "$work"
}
trap cleanup EXIT
export MEAD_CACHE_DIR="$work/cache"
unset GITHUB_TOKEN GH_TOKEN MEAD_RELEASE_REPO MEAD_NO_UPDATE_CHECK CI

passed=0
failed=0
pass() { passed=$((passed + 1)); echo "ok   $1"; }
fail() { failed=$((failed + 1)); echo "FAIL $1"; [ -n "${2:-}" ] && echo "$2" | sed 's/^/     /'; }

# expect <name> <expected exit: 0|fail> <substring or ""> <command...>
expect() {
	local name=$1 want=$2 needle=$3
	shift 3
	local out code
	out=$("$@" 2>&1)
	code=$?
	if [ "$want" = 0 ] && [ $code -ne 0 ]; then fail "$name" "exit $code: $out"; return; fi
	if [ "$want" = fail ] && [ $code -eq 0 ]; then fail "$name" "unexpected success: $out"; return; fi
	if [ -n "$needle" ] && [[ "$out" != *"$needle"* ]]; then fail "$name" "missing '$needle' in: $out"; return; fi
	pass "$name"
}

# expect_not <name> <substring> <command...>: succeeds and does not print the substring.
expect_not() {
	local name=$1 needle=$2
	shift 2
	local out
	if ! out=$("$@" 2>&1); then fail "$name" "failed: $out"; return; fi
	if [[ "$out" == *"$needle"* ]]; then fail "$name" "unexpected '$needle' in: $out"; return; fi
	pass "$name"
}

# Matches release_asset_name in src/upgrade.odin and DIST_NAME in the Makefile.
asset="mead-$(uname -s | sed 's/Linux/linux/;s/Darwin/macos/')-$(uname -m | sed 's/x86_64/amd64/;s/aarch64/arm64/')"
current=$("$mead" --version | cut -d ' ' -f 2)

# A newer mead, built from this source with a stamped version.
echo "building a v9.9.9 mead for the fake release server..."
mkdir -p "$work/build"
"$odin" build "$repo_root/src" -out:"$work/build/$asset" -define:MEAD_VERSION=9.9.9 >/dev/null || { echo "cannot build the test release"; exit 1; }

port=$(python3 -c 'import socket; s = socket.socket(); s.bind(("127.0.0.1", 0)); print(s.getsockname()[1])')
web="$work/web"
base="http://127.0.0.1:$port"

# release <tag> <binary-or-""> <sums: good|bad|none>
# Publishes a release in the API layout (api/releases/...) and the download
# layout that install.sh uses (releases/download/<tag>/...).
release() {
	local tag=$1 binary=$2 sums=$3
	local dl="$web/releases/download/$tag"
	mkdir -p "$dl" "$web/api/releases/tags"
	local assets=()
	if [ -n "$binary" ]; then
		cp "$binary" "$dl/$asset"
		assets+=("{\"name\": \"$asset\", \"browser_download_url\": \"$base/releases/download/$tag/$asset\", \"digest\": \"\"}")
	fi
	case $sums in
		good) (cd "$dl" && if [ -n "$binary" ]; then sha256sum "$asset"; fi > SHA256SUMS) ;;
		bad) echo "$(printf '0%.0s' $(seq 64))  $asset" > "$dl/SHA256SUMS" ;;
	esac
	if [ "$sums" != none ]; then
		assets+=("{\"name\": \"SHA256SUMS\", \"browser_download_url\": \"$base/releases/download/$tag/SHA256SUMS\", \"digest\": \"\"}")
	fi
	local joined
	joined=$(IFS=,; echo "${assets[*]}")
	echo "{\"id\": 1, \"tag_name\": \"$tag\", \"name\": \"$tag\", \"draft\": false, \"prerelease\": false, \"assets\": [$joined]}" \
		> "$web/api/releases/tags/$tag"
}

release v9.9.9 "$work/build/$asset" good
cp "$web/api/releases/tags/v9.9.9" "$web/api/releases/latest"
mkdir -p "$web/releases/latest"
ln -s ../download/v9.9.9 "$web/releases/latest/download"
release v9.9.7 "$work/build/$asset" bad
release v9.9.6 "$work/build/$asset" good # binary reports 9.9.9, not 9.9.6
release v9.9.5 "" good
release v9.9.4 "$work/build/$asset" none

python3 -m http.server "$port" --bind 127.0.0.1 --directory "$web" >/dev/null 2>&1 &
server_pid=$!
for _ in $(seq 50); do curl -fs "$base/api/releases/latest" >/dev/null && break; sleep 0.1; done

export MEAD_RELEASE_API="$base/api"
installed="$work/bin/mead"
fresh() { mkdir -p "$work/bin"; chmod u+w "$work/bin"; cp "$mead" "$installed"; rm -rf "$MEAD_CACHE_DIR"; }
version_of() { "$installed" --version; }

# mead upgrade
fresh
expect "upgrade --check reports a newer release" 0 "mead 9.9.9 is available (you have $current)" "$installed" upgrade --check
expect "check does not change the binary" 0 "mead $current" version_of
expect "a build without a release repository cannot upgrade" fail "does not know where its releases are published" env -u MEAD_RELEASE_API "$installed" upgrade
expect "a checksum mismatch is refused" fail "does not match SHA256SUMS" "$installed" upgrade --version 9.9.7
expect "a refused download leaves the binary unchanged" 0 "mead $current" version_of
expect "a binary that reports the wrong version is refused" fail 'reports "mead 9.9.9" instead of "mead 9.9.6"' "$installed" upgrade --version v9.9.6
expect "a release without this platform's build is refused" fail "has no build for this platform ($asset)" "$installed" upgrade --version 9.9.5
expect "a release without SHA256SUMS is refused" fail "has no SHA256SUMS file" "$installed" upgrade --version 9.9.4
expect "an unknown version is reported" fail 'mead has no release tagged "v1.2.3"' "$installed" upgrade --version 1.2.3
if [ "$(id -u)" != 0 ]; then
	chmod a-w "$work/bin"
	expect "an unwritable install directory is reported" fail "mead is installed where you cannot write" "$installed" upgrade
	chmod u+w "$work/bin"
fi
expect "no staging files are left behind" 0 "" sh -c "! ls -A '$work/bin' | grep -q mead-upgrade"
expect "upgrade installs the latest release" 0 "upgraded $installed: $current -> 9.9.9" "$installed" upgrade
expect "the upgraded binary reports the new version" 0 "mead 9.9.9" version_of
expect "upgrade is a no-op when up to date" 0 "mead 9.9.9 is up to date" "$installed" upgrade
expect "reinstalling the same version needs --force" 0 "pass --force to reinstall" "$installed" upgrade --version 9.9.9
expect "--force reinstalls" 0 "upgraded" "$installed" upgrade --version 9.9.9 --force
expect "upgrade rejects unknown arguments" fail 'unknown argument "--now" for upgrade' "$installed" upgrade --now

# The update notice. script(1) gives mead a terminal on stderr.
notice="is available (you have $current). Run \`mead upgrade\` to update."
tty_run() { (cd "$work/notice" && rm -f meade.kdl && script -qec "$*" /dev/null); }
if command -v script >/dev/null 2>&1; then
	mkdir -p "$work/notice"
	fresh
	expect "a terminal session shows the notice" 0 "mead 9.9.9 $notice" tty_run "$installed" init
	expect_not "the notice appears at most once a day" "is available" tty_run "$installed" init
	fresh
	expect_not "the notice is silent without a terminal" "is available" sh -c "cd '$work/notice' && rm -f meade.kdl && '$installed' init"
	expect_not "MEAD_NO_UPDATE_CHECK disables the notice" "is available" tty_run env MEAD_NO_UPDATE_CHECK=1 "$installed" init
	expect_not "CI disables the notice" "is available" tty_run env CI=true "$installed" init
	expect_not "-q disables the notice" "is available" tty_run "$installed" -q init
	fresh
	start=$(date +%s)
	expect_not "an unreachable release server does not break commands" "is available" tty_run env MEAD_RELEASE_API=http://127.0.0.1:9/api "$installed" init
	elapsed=$(( $(date +%s) - start ))
	if [ "$elapsed" -le 5 ]; then pass "the update check gives up quickly (${elapsed}s)"; else fail "the update check gives up quickly" "took ${elapsed}s"; fi
else
	echo "skip notice tests: script(1) is not installed"
fi

# scripts/install.sh
inst="$work/install"
expect "install.sh installs the latest release" 0 "installed mead 9.9.9 to $inst/bin/mead" \
	env MEAD_INSTALL="$inst" MEAD_DOWNLOAD_BASE="$base/releases" sh "$repo_root/scripts/install.sh"
expect "the installed binary runs" 0 "mead 9.9.9" "$inst/bin/mead" --version
expect "install.sh explains how to add mead to PATH" 0 "is not on your PATH" \
	env MEAD_INSTALL="$inst" MEAD_DOWNLOAD_BASE="$base/releases" PATH="/usr/bin:/bin" sh "$repo_root/scripts/install.sh"
expect "install.sh installs a chosen version" 0 "downloading $asset v9.9.9 from $base/releases/download/v9.9.9" \
	env MEAD_INSTALL="$work/install-pinned" MEAD_DOWNLOAD_BASE="$base/releases" sh "$repo_root/scripts/install.sh" v9.9.9
expect "install.sh refuses a checksum mismatch" fail "checksum mismatch" \
	env MEAD_INSTALL="$work/install-bad" MEAD_DOWNLOAD_BASE="$base/releases" MEAD_VERSION=9.9.7 sh "$repo_root/scripts/install.sh"
expect "a refused install writes nothing" 0 "" test ! -e "$work/install-bad/bin/mead"
expect "install.sh reports a missing release" fail "cannot download" \
	env MEAD_INSTALL="$work/install-missing" MEAD_DOWNLOAD_BASE="$base/releases" sh "$repo_root/scripts/install.sh" 1.2.3
expect "an unrendered install.sh needs a repository" fail "was not built by a release" \
	env MEAD_INSTALL="$work/install-raw" sh "$repo_root/scripts/install.sh"

sed 's|@RELEASE_REPO@|acme/mead|' "$repo_root/scripts/install.sh" > "$work/rendered.sh"
expect "the release build fills in the repository" 0 'MEAD_REPO="${MEAD_REPO:-acme/mead}"' cat "$work/rendered.sh"
expect "the rendered script keeps its placeholder check" 0 '*@*)' cat "$work/rendered.sh"

echo
echo "$passed passed, $failed failed"
[ "$failed" -eq 0 ]
