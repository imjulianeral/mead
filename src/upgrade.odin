package mead

import "core:encoding/json"
import "core:fmt"
import "core:os"
import "core:strings"
import "core:terminal"
import "core:time"

/*
Self-update. Releases are GitHub releases of RELEASE_REPO whose assets are raw
binaries named mead-<os>-<arch>, plus a SHA256SUMS file. Release builds set the
repository with -define:MEAD_RELEASE_REPO=owner/repo; a build without it cannot
update itself unless MEAD_RELEASE_REPO is set in the environment.
*/
RELEASE_REPO :: #config(MEAD_RELEASE_REPO, "")

@(private = "file")
SUMS_ASSET :: "SHA256SUMS"
@(private = "file")
CHECK_FILE :: "update-check.json"
@(private = "file")
CHECK_INTERVAL :: 24 * 60 * 60
// The background check must never make a command feel slow.
@(private = "file")
CHECK_TIMEOUT :: 3

release_repo :: proc() -> string {
	if repo := get_env("MEAD_RELEASE_REPO"); repo != "" {
		return repo
	}
	return RELEASE_REPO
}

// The GitHub API base for releases. MEAD_RELEASE_API points at a compatible mirror.
@(private = "file")
release_api :: proc() -> (base: string, err: string) {
	if api := get_env("MEAD_RELEASE_API"); api != "" {
		return strings.trim_right(api, "/"), ""
	}
	repo := release_repo()
	if repo == "" {
		return "", "this build of mead does not know where its releases are published; reinstall it with the install script, or set MEAD_RELEASE_REPO=owner/repo"
	}
	return fmt.aprintf("https://api.github.com/repos/%s", repo), ""
}

// The release asset for the running platform, such as mead-linux-amd64.
release_asset_name :: proc() -> string {
	when ODIN_OS == .Linux {
		os_name := "linux"
	} else when ODIN_OS == .Darwin {
		os_name := "macos"
	} else when ODIN_OS == .Windows {
		os_name := "windows"
	} else {
		os_name := strings.to_lower(fmt.aprint(ODIN_OS))
	}
	when ODIN_ARCH == .amd64 {
		arch := "amd64"
	} else when ODIN_ARCH == .arm64 {
		arch := "arm64"
	} else {
		arch := strings.to_lower(fmt.aprint(ODIN_ARCH))
	}
	ext := ODIN_OS == .Windows ? ".exe" : ""
	return fmt.aprintf("mead-%s-%s%s", os_name, arch, ext)
}

// Release tags are `v<version>`; a bare version selects the same tag.
@(private = "file")
release_tag :: proc(version: string) -> string {
	if len(version) > 0 && version[0] >= '0' && version[0] <= '9' {
		return strings.concatenate({"v", version})
	}
	return version
}

@(private = "file")
tag_version :: proc(tag: string) -> string {
	return strings.trim_prefix(tag, "v")
}

// Reports whether a release tag names a newer version than this binary.
is_newer_release :: proc(tag: string) -> bool {
	latest, lok := parse_semver(tag)
	current, cok := parse_semver(MEAD_VERSION)
	return lok && cok && semver_less(current, latest)
}

// Fetches the latest stable release, or the release with the given tag.
@(private = "file")
fetch_release :: proc(tag: string, timeout := 0) -> (release: GitHub_Release, err: string) {
	base, berr := release_api()
	if berr != "" {
		return release, berr
	}
	url := tag == "" ? fmt.aprintf("%s/releases/latest", base) : fmt.aprintf("%s/releases/tags/%s", base, tag)
	body, _, status, gerr := github_get(url, timeout)
	if gerr != "" {
		return release, gerr
	}
	if status == 404 {
		if tag == "" {
			return release, fmt.aprintf("no published mead release was found at %s", base)
		}
		return release, fmt.aprintf("mead has no release tagged %q", tag)
	}
	v, perr := json.parse_string(body, parse_integers = true)
	if perr != nil {
		return release, "the release API returned invalid JSON"
	}
	release = release_from_json(v)
	if release.tag_name == "" {
		return release, "the release API returned a release without a tag"
	}
	return release, ""
}

@(private = "file")
find_asset :: proc(release: ^GitHub_Release, name: string) -> ^GitHub_Asset {
	for &a in release.assets {
		if a.name == name {
			return &a
		}
	}
	return nil
}

// Finds the digest for one file in sha256sum output ("<hex>  <name>" or "<hex> *<name>").
sums_lookup :: proc(sums: string, name: string) -> (digest: string, found: bool) {
	for line in strings.split_lines(sums) {
		fields := strings.fields(line)
		if len(fields) != 2 {
			continue
		}
		if strings.trim_prefix(fields[1], "*") == name && len(fields[0]) == 64 && is_hex(fields[0]) {
			return strings.to_lower(fields[0]), true
		}
	}
	return "", false
}

@(private = "file")
download :: proc(url: string, what: string) -> string {
	resp, err := http_get(url, {})
	if err != "" {
		die("cannot download %s: %s", what, err)
	}
	if resp.status != 200 {
		die("cannot download %s: HTTP %d from %s", what, resp.status, url)
	}
	return resp.body
}

// mead upgrade [--check] [--version <version>] [--force]
cmd_upgrade :: proc(args: []string) {
	check, force := false, false
	wanted := ""
	for i := 0; i < len(args); i += 1 {
		switch args[i] {
		case "--check":
			check = true
		case "--force":
			force = true
		case "--version":
			if i + 1 >= len(args) {
				die("--version needs a value, such as 0.2.0")
			}
			i += 1
			wanted = release_tag(args[i])
		case:
			die("unknown argument %q for upgrade", args[i])
		}
	}

	release, err := fetch_release(wanted)
	if err != "" {
		die("%s", err)
	}
	version := tag_version(release.tag_name)
	if _, ok := parse_semver(version); !ok {
		die("release %q is not a semantic version", release.tag_name)
	}
	if wanted == "" {
		record_check(release.tag_name)
	}

	newer := is_newer_release(release.tag_name)
	if check {
		if newer {
			fmt.printfln("mead %s is available (you have %s); run `mead upgrade`", version, MEAD_VERSION)
		} else {
			fmt.printfln("mead %s is up to date (latest release: %s)", MEAD_VERSION, version)
		}
		return
	}
	if wanted == "" && !newer && !force {
		info("mead %s is up to date", MEAD_VERSION)
		return
	}
	if version == MEAD_VERSION && !force {
		info("mead %s is already installed (pass --force to reinstall it)", MEAD_VERSION)
		return
	}

	name := release_asset_name()
	asset := find_asset(&release, name)
	if asset == nil {
		die("release %s has no build for this platform (%s)", release.tag_name, name)
	}
	sums_asset := find_asset(&release, SUMS_ASSET)
	if sums_asset == nil {
		die("release %s has no %s file, so its binaries cannot be verified", release.tag_name, SUMS_ASSET)
	}

	exe, eerr := os.get_executable_path(context.allocator)
	if eerr != nil {
		die("cannot locate the running mead executable: %s", os.error_string(eerr))
	}

	info("downloading %s %s", name, release.tag_name)
	sums := download(sums_asset.url, SUMS_ASSET)
	binary := download(asset.url, name)

	expected, listed := sums_lookup(sums, name)
	if !listed {
		die("%s of release %s does not list %s", SUMS_ASSET, release.tag_name, name)
	}
	actual := sha256_hex(binary)
	if actual != expected {
		die("the downloaded %s does not match %s (expected sha256 %s, got %s); nothing was changed", name, SUMS_ASSET, expected, actual)
	}
	if asset.digest != "" && asset.digest != strings.concatenate({"sha256:", actual}) {
		die("the downloaded %s does not match the digest GitHub reports (%s); nothing was changed", name, asset.digest)
	}
	debug("sha256 %s verified", actual)

	replace_executable(exe, binary, version)
	info("upgraded %s: %s -> %s", exe, MEAD_VERSION, version)
}

// Stages the new binary beside the old one, checks that it runs and reports the
// expected version, then renames it into place.
@(private = "file")
replace_executable :: proc(exe: string, binary: string, version: string) {
	dir := os.dir(exe)
	staged := join(dir, fmt.aprintf(".mead-upgrade-%d", os.get_pid()))
	if err := os.write_entire_file(staged, binary); err != nil {
		die("cannot write to %s: %s\nmead is installed where you cannot write. Rerun with the needed permissions, or reinstall with the install script.", dir, os.error_string(err))
	}
	if err := os.chmod(staged, os.perm_number(0o755)); err != nil {
		os.remove(staged)
		die("cannot make %s executable: %s", staged, os.error_string(err))
	}
	res := run_capture({staged, "--version"})
	reported := strings.trim_space(res.stdout)
	if !res.ok || reported != strings.concatenate({"mead ", version}) {
		os.remove(staged)
		if !res.ok {
			die("the downloaded mead %s does not run on this system: %s", version, strings.trim_space(strings.concatenate({res.stderr, res.stdout})))
		}
		die("the downloaded binary reports %q instead of \"mead %s\"; nothing was changed", reported, version)
	}
	when ODIN_OS == .Windows {
		// Windows cannot replace a running executable, but it can rename one.
		old := strings.concatenate({exe, ".old"})
		os.remove(old)
		if err := os.rename(exe, old); err != nil {
			os.remove(staged)
			die("cannot move %s aside: %s", exe, os.error_string(err))
		}
	}
	if err := os.rename(staged, exe); err != nil {
		os.remove(staged)
		die("cannot replace %s: %s", exe, os.error_string(err))
	}
}

// Update notices

@(private = "file")
Update_Check :: struct {
	checked_at:  i64    `json:"checked_at"`,
	latest:      string `json:"latest"`,
	notified_at: i64    `json:"notified_at"`,
}

@(private = "file")
load_check :: proc() -> Update_Check {
	state: Update_Check
	if data, ok := read_file(join(cache_root(), CHECK_FILE)); ok {
		json.unmarshal_string(data, &state)
	}
	return state
}

@(private = "file")
save_check :: proc(state: Update_Check) {
	write_file_atomic(join(cache_root(), CHECK_FILE), to_json(state))
}

@(private = "file")
record_check :: proc(latest_tag: string) {
	state := load_check()
	state.checked_at = time.time_to_unix(time.now())
	state.latest = latest_tag
	save_check(state)
}

/*
Prints a one-line notice when a newer release exists. It looks at the network
at most once a day, with a short timeout, prints at most once a day, and stays
silent in scripts and CI: only when stderr is a terminal.
*/
maybe_notify_update :: proc(command: string) {
	if command == "upgrade" || g_quiet {
		return
	}
	if get_env("MEAD_NO_UPDATE_CHECK") != "" || get_env("CI") != "" {
		return
	}
	if !terminal.is_terminal(os.stderr) {
		return
	}
	if _, err := release_api(); err != "" {
		return
	}
	now := time.time_to_unix(time.now())
	state := load_check()
	if now - state.checked_at >= CHECK_INTERVAL {
		// Record the attempt even when it fails, so an offline machine does not retry on every command.
		state.checked_at = now
		if release, err := fetch_release("", CHECK_TIMEOUT); err == "" {
			state.latest = release.tag_name
		} else {
			debug("update check failed: %s", err)
		}
		save_check(state)
	}
	if is_newer_release(state.latest) && now - state.notified_at >= CHECK_INTERVAL {
		fmt.eprintfln("mead %s is available (you have %s). Run `mead upgrade` to update.", tag_version(state.latest), MEAD_VERSION)
		state.notified_at = now
		save_check(state)
	}
}
