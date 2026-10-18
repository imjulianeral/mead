package mead

import "core:fmt"
import "core:os"
import "core:strings"

// The shared fetch and artifact cache. It speeds up repeated installs but never
// replaces the project's own deps/ directory.
cache_root :: proc() -> string {
	if dir := get_env("MEAD_CACHE_DIR"); dir != "" {
		return absolute(dir)
	}
	when ODIN_OS == .Darwin {
		return join(get_env("HOME"), "Library", "Caches", "mead")
	} else when ODIN_OS == .Windows {
		return join(get_env("LOCALAPPDATA"), "mead", "cache")
	} else {
		if xdg := get_env("XDG_CACHE_HOME"); xdg != "" {
			return join(xdg, "mead")
		}
		return join(get_env("HOME"), ".cache", "mead")
	}
}

Remote_Ref :: struct {
	name:   string,
	// The object the ref names. For an annotated tag, this is the tag object.
	object: string,
	// The commit an annotated tag points to, if the server reported it.
	peeled: string,
}

Remote_Refs :: struct {
	refs: [dynamic]Remote_Ref,
	// The branch that the remote HEAD names, such as refs/heads/main.
	head: string,
}

remote_ref_commit :: proc(r: Remote_Ref) -> string {
	return r.peeled != "" ? r.peeled : r.object
}

git_ls_remote :: proc(url: string) -> (out: Remote_Refs, err: string) {
	res := run_capture({"git", "ls-remote", "--symref", url})
	if !res.ok {
		return out, fmt.aprintf("cannot list refs of %s:\n%s", url, strings.trim_space(res.stderr))
	}
	index: map[string]int
	for line in strings.split_lines(res.stdout) {
		if line == "" {
			continue
		}
		tab := strings.index_byte(line, '\t')
		if tab < 0 {
			continue
		}
		left, name := line[:tab], line[tab + 1:]
		if strings.has_prefix(left, "ref: ") {
			if name == "HEAD" {
				out.head = left[len("ref: "):]
			}
			continue
		}
		if strings.has_suffix(name, "^{}") {
			base := name[:len(name) - 3]
			if i, ok := index[base]; ok {
				out.refs[i].peeled = left
			}
			continue
		}
		index[name] = len(out.refs)
		append(&out.refs, Remote_Ref{name = name, object = left})
	}
	return out, ""
}

find_remote_ref :: proc(refs: Remote_Refs, name: string) -> (Remote_Ref, bool) {
	for r in refs.refs {
		if r.name == name {
			return r, true
		}
	}
	return {}, false
}

object_format_for :: proc(commit: string) -> string {
	return len(commit) == 64 ? "sha256" : "sha1"
}

// Resolves a selector against the origin without fetching sources.
resolve_selector :: proc(url: string, sel: Selector) -> (src: Locked_Source, err: string) {
	src.git = url
	src.selector = selector_to_locked(sel)
	switch sel.kind {
	case .None:
		return src, "no selector"
	case .Rev:
		src.commit = sel.value
		src.object_format = object_format_for(sel.value)
		return src, ""
	case .Release:
		gh, is_github := parse_github_url(url)
		if !is_github {
			return src, fmt.aprintf("`release=%q` needs a GitHub origin; use `tag=%q` for other hosts", sel.value, sel.value)
		}
		release, rerr := github_release_by_tag(gh, sel.value)
		if rerr != "" {
			return src, rerr
		}
		if release.draft {
			return src, fmt.aprintf("release %q of %s is a draft", sel.value, url)
		}
		src.release_id = release.id
	case .Tag, .Branch:
	}
	refs, lerr := git_ls_remote(url)
	if lerr != "" {
		return src, lerr
	}
	ref_name := sel.kind == .Branch ? strings.concatenate({"refs/heads/", sel.value}) : strings.concatenate({"refs/tags/", sel.value})
	r, found := find_remote_ref(refs, ref_name)
	if !found {
		what := sel.kind == .Branch ? "branch" : "tag"
		return src, fmt.aprintf("%s %q does not exist in %s (see `mead versions %s`)", what, sel.value, url, url)
	}
	src.ref = ref_name
	src.commit = remote_ref_commit(r)
	src.object_format = object_format_for(src.commit)
	return src, ""
}

repo_cache_dir :: proc(url: string) -> string {
	base := os.base(strings.trim_suffix(strings.trim_right(url, "/"), ".git"))
	clean := strings.builder_make()
	for c in base {
		if (c >= 'a' && c <= 'z') || (c >= 'A' && c <= 'Z') || (c >= '0' && c <= '9') || c == '-' || c == '_' || c == '.' {
			strings.write_rune(&clean, c)
		}
	}
	return join(cache_root(), "git", fmt.aprintf("%s-%s.git", strings.to_string(clean), sha256_hex(url)[:16]))
}

@(private = "file")
git_in :: proc(repo: string, args: ..string) -> Run_Result {
	cmd: [dynamic]string
	append(&cmd, "git", "--git-dir", repo)
	append(&cmd, ..args)
	return run_capture(cmd[:])
}

has_commit :: proc(repo: string, commit: string) -> bool {
	if !os.is_directory(repo) {
		return false
	}
	res := git_in(repo, "cat-file", "-t", commit)
	return res.ok && strings.trim_space(res.stdout) == "commit"
}

// Makes the source's commit available in the shared cache and returns the cache repository.
ensure_commit :: proc(src: Locked_Source, offline: bool) -> (repo: string, err: string) {
	repo = repo_cache_dir(src.git)
	lock := lock_acquire(strings.concatenate({repo, ".lock"}))
	defer lock_release(lock)

	if has_commit(repo, src.commit) {
		return repo, ""
	}
	if offline {
		return repo, fmt.aprintf("commit %s of %s is not in the local cache, and --offline forbids network access", src.commit, src.git)
	}
	if !os.is_directory(repo) {
		tmp := strings.concatenate({repo, ".tmp-", unique_suffix()})
		res := run_capture({"git", "init", "--quiet", "--bare", strings.concatenate({"--object-format=", src.object_format}), tmp})
		if !res.ok {
			return repo, fmt.aprintf("cannot create cache repository: %s", strings.trim_space(res.stderr))
		}
		if rerr := os.rename(tmp, repo); rerr != nil {
			remove_tree(tmp)
			if !os.is_directory(repo) {
				return repo, fmt.aprintf("cannot create cache repository %s", repo)
			}
		}
	}

	info("fetching %s %s", src.git, short_commit(src.commit))
	// Fetch the exact commit first, so a moved ref cannot change what arrives.
	// Mead needs only the tree at the locked commit, so fetches are shallow.
	res := git_in(repo, "fetch", "--quiet", "--no-tags", "--depth=1", src.git, src.commit)
	if !res.ok && src.ref != "" {
		debug("fetch by commit failed: %s", strings.trim_space(res.stderr))
		keep := strings.concatenate({"+", src.ref, ":refs/mead/fetched/", strings.trim_prefix(src.ref, "refs/")})
		res = git_in(repo, "fetch", "--quiet", "--no-tags", "--depth=1", src.git, keep)
	}
	if !res.ok && src.ref == "" {
		debug("fetch by commit failed: %s", strings.trim_space(res.stderr))
		res = git_in(repo, "fetch", "--quiet", "--no-tags", src.git, "+refs/heads/*:refs/mead/heads/*", "+refs/tags/*:refs/mead/tags/*")
	}
	if !res.ok {
		return repo, fmt.aprintf("cannot fetch %s:\n%s", src.git, strings.trim_space(res.stderr))
	}
	if !has_commit(repo, src.commit) {
		return repo, fmt.aprintf("commit %s is unavailable from %s (ref %s). The locked identity no longer exists at the origin.", src.commit, src.git, src.ref != "" ? src.ref : "none")
	}
	// Keep fetched commits reachable so cache maintenance cannot prune them.
	git_in(repo, "update-ref", strings.concatenate({"refs/mead/keep/", src.commit}), src.commit)
	return repo, ""
}

repo_object_format :: proc(repo: string) -> string {
	res := git_in(repo, "rev-parse", "--show-object-format")
	if !res.ok {
		return "sha1"
	}
	return strings.trim_space(res.stdout)
}

// Writes the complete tree of a commit into dest, which must not exist yet.
export_commit :: proc(repo: string, commit: string, dest: string) -> string {
	make_dirs(dest)
	index := join(os.dir(dest), strings.concatenate({".index-", unique_suffix()}))
	defer os.remove(index)
	env := env_with(strings.concatenate({"GIT_INDEX_FILE=", index}))
	res := run_capture({"git", "--git-dir", repo, "--work-tree", dest, "read-tree", commit}, env = env)
	if res.ok {
		res = run_capture({"git", "--git-dir", repo, "--work-tree", dest, "checkout-index", "--all", "--force"}, env = env)
	}
	if !res.ok {
		return fmt.aprintf("cannot export commit %s: %s", commit, strings.trim_space(res.stderr))
	}
	return ""
}

// Reads one file from a commit without exporting the tree.
git_show_file :: proc(repo, commit, path: string) -> (string, bool) {
	res := git_in(repo, "show", strings.concatenate({commit, ":", path}))
	if !res.ok {
		return "", false
	}
	return res.stdout, true
}
