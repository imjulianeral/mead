#!/bin/sh
# Installs mead from its GitHub releases.
#
#   curl -fsSL https://github.com/@RELEASE_REPO@/releases/latest/download/install.sh | sh
#   curl -fsSL https://github.com/@RELEASE_REPO@/releases/latest/download/install.sh | sh -s -- 0.2.0
#
# Environment:
#   MEAD_INSTALL         install root; the binary goes to $MEAD_INSTALL/bin (default: ~/.mead)
#   MEAD_VERSION         version to install, such as 0.2.0 (default: the latest release)
#   MEAD_DOWNLOAD_BASE   base URL of the releases (default: https://github.com/<repo>/releases)
#
# The whole script is a function called on the last line, so a truncated
# download never runs a partial script.

set -eu

MEAD_REPO="${MEAD_REPO:-@RELEASE_REPO@}"

say() { printf '%s\n' "$*" >&2; }
fail() { say "mead install: error: $*"; exit 1; }

need() {
	command -v "$1" >/dev/null 2>&1 || fail "this installer needs '$1'"
}

detect_platform() {
	case "$(uname -s)" in
		Linux) os=linux ;;
		Darwin) os=macos ;;
		*) fail "mead has no builds for $(uname -s); build it from source with 'make'" ;;
	esac
	case "$(uname -m)" in
		x86_64 | amd64) arch=amd64 ;;
		aarch64 | arm64) arch=arm64 ;;
		*) fail "mead has no builds for $(uname -m); build it from source with 'make'" ;;
	esac
	printf 'mead-%s-%s' "$os" "$arch"
}

fetch() { # fetch <url> <file>
	if command -v curl >/dev/null 2>&1; then
		curl --proto '=https,http' --proto-redir '=https' --fail --location --silent --show-error --output "$2" "$1"
	elif command -v wget >/dev/null 2>&1; then
		wget --quiet --output-document="$2" "$1"
	else
		fail "this installer needs curl or wget"
	fi
}

sha256() {
	if command -v sha256sum >/dev/null 2>&1; then
		sha256sum "$1" | cut -d ' ' -f 1
	elif command -v shasum >/dev/null 2>&1; then
		shasum -a 256 "$1" | cut -d ' ' -f 1
	else
		fail "this installer needs sha256sum or shasum to verify the download"
	fi
}

main() {
	need uname
	need mktemp
	version="${1:-${MEAD_VERSION:-}}"
	version="${version#v}"
	root="${MEAD_INSTALL:-$HOME/.mead}"
	bin_dir="$root/bin"

	# An unrendered placeholder still contains '@'; a real owner/repo never does.
	case "$MEAD_REPO" in
		*@*) [ -n "${MEAD_DOWNLOAD_BASE:-}" ] || fail "this copy of install.sh was not built by a release; set MEAD_REPO=owner/repo" ;;
	esac
	base="${MEAD_DOWNLOAD_BASE:-https://github.com/$MEAD_REPO/releases}"
	if [ -n "$version" ]; then
		url="$base/download/v$version"
	else
		url="$base/latest/download"
	fi

	asset=$(detect_platform)
	tmp=$(mktemp -d)
	trap 'rm -rf "$tmp"' EXIT INT TERM

	say "downloading $asset ${version:+v$version }from $url"
	fetch "$url/$asset" "$tmp/$asset" || fail "cannot download $url/$asset"
	fetch "$url/SHA256SUMS" "$tmp/SHA256SUMS" || fail "cannot download $url/SHA256SUMS"

	expected=$(awk -v name="$asset" '{ sub(/^\*/, "", $2) } $2 == name { print $1 }' "$tmp/SHA256SUMS")
	[ -n "$expected" ] || fail "SHA256SUMS does not list $asset"
	actual=$(sha256 "$tmp/$asset")
	[ "$actual" = "$expected" ] || fail "checksum mismatch for $asset (expected $expected, got $actual)"

	chmod 755 "$tmp/$asset"
	if ! reported=$("$tmp/$asset" --version 2>&1); then
		say "$reported"
		fail "the downloaded mead does not run here; it needs git and libcurl (for example: apt install git libcurl4)"
	fi

	mkdir -p "$bin_dir"
	# Rename within the target directory so a running mead is replaced atomically.
	cp "$tmp/$asset" "$bin_dir/.mead-install-$$"
	mv -f "$bin_dir/.mead-install-$$" "$bin_dir/mead"
	say "installed $reported to $bin_dir/mead"

	case ":${PATH}:" in
		*":$bin_dir:"*) say "run 'mead --help' to get started" ;;
		*)
			say ""
			say "$bin_dir is not on your PATH. Add it with:"
			case "$(basename "${SHELL:-sh}")" in
				fish) say "  fish_add_path $bin_dir" ;;
				zsh) say "  echo 'export PATH=\"$bin_dir:\$PATH\"' >> ~/.zshrc" ;;
				bash) say "  echo 'export PATH=\"$bin_dir:\$PATH\"' >> ~/.bashrc" ;;
				*) say "  export PATH=\"$bin_dir:\$PATH\"" ;;
			esac
			;;
	esac
	say "keep it current with 'mead upgrade'"
}

main "$@"
