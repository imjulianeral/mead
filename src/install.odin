package mead

import "core:fmt"
import "core:os"
import "core:strings"

Install_Options :: struct {
	locked:     bool,
	offline:    bool,
	// Names whose selections are resolved again.
	update:     []string,
	update_all: bool,
}

@(private = "file")
Planned_Dependency :: struct {
	decl:     Dependency,
	source:   Locked_Source,
	previous: ^Locked_Dependency,
	resolved: bool,
	staged:   string,
	locked:   Locked_Dependency,
}

@(private = "file")
Planned_Tool :: struct {
	decl:          Tool,
	source:        Locked_Source,
	previous:      ^Locked_Tool,
	resolved:      bool,
	staged_source: string,
	staged_bin:    string,
	artifact_key:  string,
	executable:    string,
	locked:        Locked_Tool,
}

@(private = "file")
wants_update :: proc(opts: Install_Options, name: string) -> bool {
	if opts.update_all {
		return true
	}
	for n in opts.update {
		if n == name {
			return true
		}
	}
	return false
}

@(private = "file")
report_resolution :: proc(name: string, previous: ^Locked_Source, src: Locked_Source) {
	ref := src.ref != "" ? src.ref : "exact commit"
	if previous == nil {
		info("resolved %s: %s %s -> %s", name, src.selector.kind, src.selector.value, short_commit(src.commit))
	} else if previous.commit == src.commit {
		info("%s is unchanged at %s (%s)", name, short_commit(src.commit), ref)
	} else {
		info("updated %s: %s -> %s (%s)", name, short_commit(previous.commit), short_commit(src.commit), ref)
	}
}

install :: proc(opts: Install_Options) {
	root := find_project_root()
	m := load_manifest(join(root, MANIFEST_FILE))
	lock, has_lock := load_lockfile(root)
	hash := manifest_hash(m)
	if opts.locked {
		if !has_lock {
			die("--locked needs an existing mead.lock")
		}
		if lock.manifest_hash != hash {
			die("meade.kdl changed since mead.lock was written; run `mead install` without --locked, or `mead update <name>`")
		}
	}

	project_lock := lock_acquire(join(root, ".mead", "project.lock"))
	defer lock_release(project_lock)
	tmp_root := join(root, ".mead", "tmp")
	remove_tree(tmp_root)
	staging := join(tmp_root, unique_suffix())
	make_dirs(staging)
	state := load_state(root)

	// Resolve selections. Locked identities are reused unless an update asks otherwise.
	deps: [dynamic]Planned_Dependency
	for d in m.dependencies {
		p := Planned_Dependency{decl = d}
		if has_lock {
			p.previous = find_locked_dependency(&lock, d.name)
		}
		if p.previous != nil && !wants_update(opts, d.name) {
			prev := p.previous
			if prev.source.git != d.git || !selector_matches(d.selector, prev.source.selector) || prev.requested_path != d.path {
				die("the declaration of %q in meade.kdl differs from mead.lock; run `mead update %s` to resolve it again", d.name, d.name)
			}
			p.source = prev.source
		} else {
			if opts.offline {
				die("%q is not locked, and --offline forbids resolving it", d.name)
			}
			src, err := resolve_selector(d.git, d.selector)
			if err != "" {
				die("%s: %s", d.name, err)
			}
			p.source = src
			p.resolved = true
			report_resolution(d.name, p.previous != nil ? &p.previous.source : nil, src)
		}
		append(&deps, p)
	}
	tools: [dynamic]Planned_Tool
	for t in m.tools {
		p := Planned_Tool{decl = t}
		if has_lock {
			p.previous = find_locked_tool(&lock, t.name)
		}
		if p.previous != nil && !wants_update(opts, t.name) {
			prev := p.previous
			if prev.source.git != t.git || !selector_matches(t.selector, prev.source.selector) || prev.distribution != t.distribution || prev.target.name != t.target {
				die("the declaration of tool %q in meade.kdl differs from mead.lock; run `mead update %s` to resolve it again", t.name, t.name)
			}
			p.source = prev.source
		} else {
			if opts.offline {
				die("tool %q is not locked, and --offline forbids resolving it", t.name)
			}
			src, err := resolve_selector(t.git, t.selector)
			if err != "" {
				die("tool %s: %s", t.name, err)
			}
			p.source = src
			p.resolved = true
			report_resolution(t.name, p.previous != nil ? &p.previous.source : nil, src)
		}
		append(&tools, p)
	}

	// Fetch and stage dependency sources.
	for &p in deps {
		prepare_dependency(root, staging, &m, &p, &state, opts.offline)
	}
	tc: Toolchain
	if len(tools) > 0 {
		tc = find_toolchain()
	}
	for &p in tools {
		prepare_tool(root, staging, tc, &p, &state, opts.offline)
	}

	// Every fetch and build succeeded. Publish the staged results.
	new_state := State{}
	for &p in deps {
		dest := join(root, "deps", p.decl.name)
		if p.staged != "" {
			replace_dir(dest, p.staged, staging)
		}
		append_elem(&new_state.dependencies, Installed_Dependency{
			name = p.decl.name,
			commit = p.source.commit,
			install_dir = dest,
			package_dir = join(dest, p.locked.package_path),
			package_path = p.locked.package_path,
		})
	}
	for &p in tools {
		dest := join(root, "deps", ".tools", p.decl.name)
		if p.staged_source != "" {
			replace_dir(join(dest, "source"), p.staged_source, staging)
		}
		if p.staged_bin != "" {
			replace_dir(join(dest, "bin"), p.staged_bin, staging)
		}
		append_elem(&new_state.tools, Installed_Tool{
			name = p.decl.name,
			commit = p.source.commit,
			artifact_key = p.artifact_key,
			executable = join(dest, "bin", p.executable),
		})
	}
	// Remove installations that the manifest no longer declares.
	for old in state.dependencies {
		if find_dependency(&m, old.name) == nil {
			info("removing %s", old.name)
			remove_tree(join(root, "deps", old.name))
		}
	}
	for old in state.tools {
		if find_tool(&m, old.name) == nil {
			info("removing tool %s", old.name)
			remove_tree(join(root, "deps", ".tools", old.name))
		}
	}

	new_lock := Lockfile{version = LOCK_VERSION, manifest_hash = hash}
	for p in deps {
		append_elem(&new_lock.dependencies, p.locked)
	}
	for p in tools {
		append_elem(&new_lock.tools, p.locked)
	}
	write_lockfile(root, new_lock)
	write_state(root, new_state)
	remove_tree(tmp_root)
	info("installed %d %s and %d %s", len(deps), len(deps) == 1 ? "dependency" : "dependencies", len(tools), len(tools) == 1 ? "tool" : "tools")
}

@(private = "file")
append_elem :: proc(s: ^[]$T, v: T) {
	d := make([dynamic]T, len(s^), len(s^) + 1)
	copy(d[:], s^)
	append(&d, v)
	s^ = d[:]
}

// Swaps a staged directory into place. The previous content is removed only
// after the new content is in place.
@(private = "file")
replace_dir :: proc(dest: string, staged: string, staging: string) {
	make_dirs(os.dir(dest))
	old := ""
	if os.exists(dest) || is_symlink(dest) {
		old = join(staging, strings.concatenate({"old-", os.base(dest), "-", unique_suffix()}))
		if err := os.rename(dest, old); err != nil {
			die("cannot move %s aside: %s", dest, os.error_string(err))
		}
	}
	if err := os.rename(staged, dest); err != nil {
		if old != "" {
			os.rename(old, dest)
		}
		die("cannot install %s: %s", dest, os.error_string(err))
	}
	if old != "" {
		remove_tree(old)
	}
}

@(private = "file")
read_author_manifest :: proc(dir: string, label: string) -> (m: Manifest, found: bool, err: string) {
	path := join(dir, MANIFEST_FILE)
	if !os.is_file(path) {
		return m, false, ""
	}
	source, _ := read_file(path)
	m, err = parse_manifest(source, fmt.aprintf("%s/%s", label, MANIFEST_FILE))
	return m, true, err
}

@(private = "file")
prepare_dependency :: proc(root, staging: string, m: ^Manifest, p: ^Planned_Dependency, state: ^State, offline: bool) {
	name := p.decl.name
	dest := join(root, "deps", name)
	installed := find_installed_dependency(state, name)
	up_to_date := installed != nil && installed.commit == p.source.commit && os.is_directory(dest)
	dir := dest
	if !up_to_date {
		repo, err := ensure_commit(p.source, offline)
		if err != "" {
			die("%s: %s", name, err)
		}
		p.source.object_format = repo_object_format(repo)
		p.staged = join(staging, "deps", name)
		if eerr := export_commit(repo, p.source.commit, p.staged); eerr != "" {
			die("%s: %s", name, eerr)
		}
		if os.is_file(join(p.staged, ".gitmodules")) {
			warn("%s uses Git submodules, which mead does not fetch", name)
		}
		dir = p.staged
	}

	author, has_author, aerr := read_author_manifest(dir, fmt.aprintf("deps/%s", name))
	if aerr != "" {
		if p.decl.path == "" {
			die("cannot read the author manifest of %q: %s\nSet `path=` on the dependency to choose its package directory yourself.", name, aerr)
		}
		warn("ignoring the invalid author manifest of %q: %s", name, aerr)
		has_author = false
	}
	package_path := "."
	if p.decl.path != "" {
		package_path = p.decl.path
	} else if has_author {
		package_path = author.package_path
	}

	// The package directory must stay inside the checkout after resolving symlinks.
	checkout_real, _ := real_path(dir)
	package_real, exists := real_path(join(dir, package_path))
	if !exists || !os.is_directory(package_real) {
		die("dependency %q has no package directory %q at %s", name, package_path, short_commit(p.source.commit))
	}
	if !path_within(checkout_real, package_real) {
		die("dependency %q: package path %q resolves outside the repository", name, package_path)
	}
	if len(walk_files_shallow(package_real, ".odin")) == 0 {
		warn("dependency %q: %s contains no .odin files", name, package_path)
	}

	// Recursive graphs are a later milestone. Author-declared dependencies must
	// be declared by the consumer under the same names.
	scope_names: [dynamic]string
	if has_author {
		missing: [dynamic]string
		for ad in author.dependencies {
			append(&scope_names, ad.name)
			if find_dependency(m, ad.name) == nil {
				append(&missing, fmt.aprintf("    dependency %q git=%q %s=%q", ad.name, ad.git, SELECTOR_NAMES[ad.selector.kind], ad.selector.value))
			}
		}
		if len(missing) > 0 {
			die("dependency %q declares its own dependencies, and mead does not install dependencies transitively yet.\nDeclare them in meade.kdl under the same names, for example:\n%s", name, strings.join(missing[:], "\n"))
		}
		if len(author.tools) > 0 {
			debug("dependency %q declares tools; mead installs only the project's own tools", name)
		}
	}
	if p.source.object_format == "" {
		p.source.object_format = object_format_for(p.source.commit)
	}
	p.locked = Locked_Dependency{
		name = name,
		source = p.source,
		requested_path = p.decl.path,
		package_path = package_path,
		author_manifest = has_author,
		dependencies = scope_names[:],
	}
}

walk_files_shallow :: proc(dir: string, ext: string) -> [dynamic]string {
	out: [dynamic]string
	infos, err := os.read_all_directory_by_path(dir, context.allocator)
	if err != nil {
		return out
	}
	for fi in infos {
		if strings.has_suffix(fi.name, ext) {
			append(&out, fi.name)
		}
	}
	return out
}

@(private = "file")
prepare_tool :: proc(root, staging: string, tc: Toolchain, p: ^Planned_Tool, state: ^State, offline: bool) {
	name := p.decl.name
	dest := join(root, "deps", ".tools", name)
	installed := find_installed_tool(state, name)
	source_dir := join(dest, "source")
	source_current := installed != nil && installed.commit == p.source.commit && os.is_directory(source_dir)
	if !source_current {
		repo, err := ensure_commit(p.source, offline)
		if err != "" {
			die("tool %s: %s", name, err)
		}
		p.source.object_format = repo_object_format(repo)
		p.staged_source = join(staging, "tools", name, "source")
		if eerr := export_commit(repo, p.source.commit, p.staged_source); eerr != "" {
			die("tool %s: %s", name, eerr)
		}
		source_dir = p.staged_source
	}
	if p.source.object_format == "" {
		p.source.object_format = object_format_for(p.source.commit)
	}

	author, has_author, aerr := read_author_manifest(source_dir, fmt.aprintf("deps/.tools/%s/source", name))
	if aerr != "" {
		die("tool %q: %s", name, aerr)
	}
	if !has_author {
		die("tool %q: the repository has no %s; source-built tools need an author manifest with an executable target", name, MANIFEST_FILE)
	}
	target := find_target(&author, p.decl.target)
	if target == nil {
		die("tool %q: the author's manifest has no target named %q", name, p.decl.target)
	}
	if target.kind != .Executable {
		die("tool %q: target %q is a %s, not an executable", name, target.name, TARGET_KIND_NAMES[target.kind])
	}
	if len(author.dependencies) > 0 {
		die("tool %q: its manifest declares dependencies, and mead does not build tool dependency graphs yet", name)
	}
	package_real, exists := real_path(join(source_dir, target.path))
	source_real, _ := real_path(source_dir)
	if !exists || !path_within(source_real, package_real) {
		die("tool %q: target path %q is missing or leaves the repository", name, target.path)
	}

	locked_target := Locked_Target{name = target.name, kind = TARGET_KIND_NAMES[target.kind], path = target.path, flags = target.flags[:]}
	if p.previous != nil && !p.resolved && p.previous.source.commit == p.source.commit {
		prev := p.previous.target
		if prev.path != locked_target.path || strings.join(prev.flags, "\x00") != strings.join(locked_target.flags, "\x00") {
			die("tool %q: the author's target at the locked commit differs from mead.lock", name)
		}
	}
	p.locked = Locked_Tool{
		name = name,
		source = p.source,
		distribution = p.decl.distribution,
		target = locked_target,
	}

	p.executable = output_name(name, .Executable)
	p.artifact_key = tool_artifact_key(tc, p.source, locked_target)
	if installed != nil && installed.artifact_key == p.artifact_key && source_current && os.is_file(join(dest, "bin", p.executable)) {
		return
	}
	artifact := build_tool_artifact(root, tc, name, source_dir, p.artifact_key, target^)
	p.staged_bin = join(staging, "tools", name, "bin")
	make_dirs(p.staged_bin)
	built := join(artifact, "bin", output_name(target.name, .Executable))
	if err := os.copy_file(join(p.staged_bin, p.executable), built); err != nil {
		die("tool %q: cannot stage %s: %s", name, built, os.error_string(err))
	}
	// Keep any runtime files that the build placed beside the executable.
	for f in walk_files_shallow(join(artifact, "bin"), "") {
		if f != output_name(target.name, .Executable) {
			os.copy_file(join(p.staged_bin, f), join(artifact, "bin", f))
		}
	}
}

// The key covers every input that can change the built executable.
tool_artifact_key :: proc(tc: Toolchain, src: Locked_Source, target: Locked_Target) -> string {
	b := strings.builder_make()
	fmt.sbprintf(&b, "mead-tool-artifact-1\n%s\n%v\n%v\n", toolchain_fingerprint(tc), ODIN_OS, ODIN_ARCH)
	fmt.sbprintf(&b, "%s\n%s\n%s\n%s\n%s\n", src.git, src.object_format, src.commit, target.name, target.path)
	for f in target.flags {
		fmt.sbprintf(&b, "flag\x00%s\n", f)
	}
	strings.write_string(&b, "graph\x00\n")
	return sha256_hex(strings.to_string(b))
}

// Builds a tool into the shared artifact cache, or reuses a cached build.
@(private = "file")
build_tool_artifact :: proc(root: string, tc: Toolchain, name: string, source_dir: string, key: string, target: Target) -> string {
	artifact := join(cache_root(), "artifacts", key)
	lock := lock_acquire(strings.concatenate({artifact, ".lock"}))
	defer lock_release(lock)
	exe := output_name(target.name, .Executable)
	if os.is_file(join(artifact, "bin", exe)) {
		info("reusing cached build of tool %s (%s)", name, key[:12])
		return artifact
	}

	// Build in an isolated working copy so the build cannot modify cached or installed sources.
	work := join(root, ".mead", "build", strings.concatenate({"tool-", name}))
	remove_tree(work)
	copy_tree(work, source_dir)
	tmp := strings.concatenate({artifact, ".tmp-", unique_suffix()})
	make_dirs(join(tmp, "bin"))
	info("building tool %s", name)
	cmd := compiler_command(tc, join(work, target.path), join(tmp, "bin", exe), .Executable, target.flags[:])
	res := run_capture(cmd, cwd = work)
	view := Build_View{root = work, original = source_dir}
	output := strings.concatenate({res.stdout, res.stderr})
	if !res.ok {
		remove_tree(tmp)
		fmt.eprint(map_diagnostics(&view, output))
		die("building tool %q failed; the previously installed tool is unchanged", name)
	}
	if len(output) > 0 {
		fmt.eprint(map_diagnostics(&view, output))
	}
	if err := os.rename(tmp, artifact); err != nil {
		remove_tree(tmp)
		die("cannot publish the build of tool %q: %s", name, os.error_string(err))
	}
	remove_tree(work)
	return artifact
}
