package mead

import "core:fmt"
import "core:os"
import "core:slice"
import "core:strconv"
import "core:strings"

cmd_init :: proc(args: []string) {
	name := ""
	for a in args {
		if strings.has_prefix(a, "-") {
			die("unknown option %q for init", a)
		}
		if name != "" {
			die("init takes at most one argument: the package name")
		}
		name = a
	}
	cwd, _ := os.get_working_directory(context.allocator)
	path := join(cwd, MANIFEST_FILE)
	if os.exists(path) {
		die("%s already exists", path)
	}
	if name == "" {
		name = identifier_from(os.base(cwd))
	}
	b := strings.builder_make()
	fmt.sbprintf(&b, "schema %d\n\npackage %s version=\"0.1.0\"\n", SCHEMA_VERSION, quote(name))
	if os.is_directory(join(cwd, "src")) && validate_dependency_name(name) == "" {
		fmt.sbprintf(&b, "\ntargets {{\n    target %s kind=\"executable\" path=\"src\"\n}}\n", quote(name))
	}
	text := strings.to_string(b)
	if _, err := parse_manifest(text, MANIFEST_FILE); err != "" {
		die("cannot create a valid manifest: %s", err)
	}
	write_file_atomic(path, text)
	ensure_gitignore(cwd)
	info("created %s", path)
}

@(private = "file")
quote :: proc(s: string) -> string {
	return fmt.aprintf("%q", s)
}

// Derives a valid dependency or package name from free text such as a repository name.
identifier_from :: proc(s: string) -> string {
	b := strings.builder_make()
	for c in s {
		switch c {
		case 'a' ..= 'z', 'A' ..= 'Z', '0' ..= '9', '_':
			strings.write_rune(&b, c)
		case '-', '.', ' ':
			strings.write_byte(&b, '_')
		}
	}
	out := strings.to_string(b)
	if out == "" || (out[0] >= '0' && out[0] <= '9') {
		out = strings.concatenate({"pkg_", out})
	}
	return out
}

// mead add <git-url> [--as <name>] (--tag|--branch|--rev|--release) <value> [--path <dir>] [--tool [--target <name>]]
cmd_add :: proc(args: []string) {
	url, alias, path, target := "", "", "", ""
	is_tool := false
	sel: Selector
	set_selector :: proc(sel: ^Selector, kind: Selector_Kind, value: string) {
		if sel.kind != .None {
			die("choose exactly one of --tag, --branch, --rev, or --release")
		}
		sel^ = {kind, value}
	}
	i := 0
	next_value :: proc(args: []string, i: ^int) -> string {
		if i^ + 1 >= len(args) {
			die("%s needs a value", args[i^])
		}
		i^ += 1
		return args[i^]
	}
	for ; i < len(args); i += 1 {
		a := args[i]
		switch a {
		case "--as":      alias = next_value(args, &i)
		case "--tag":     set_selector(&sel, .Tag, next_value(args, &i))
		case "--branch":  set_selector(&sel, .Branch, next_value(args, &i))
		case "--rev":     set_selector(&sel, .Rev, next_value(args, &i))
		case "--release": set_selector(&sel, .Release, next_value(args, &i))
		case "--path":    path = next_value(args, &i)
		case "--target":  target = next_value(args, &i)
		case "--tool":    is_tool = true
		case:
			if strings.has_prefix(a, "-") {
				die("unknown option %q for add", a)
			}
			if url != "" {
				die("add takes one Git URL")
			}
			url = a
		}
	}
	if url == "" {
		die("usage: mead add <git-url> --as <name> (--tag <tag> | --branch <branch> | --rev <commit> | --release <tag>)")
	}
	if sel.kind == .None {
		die("choose a revision with --tag, --branch, --rev, or --release (see `mead versions %s`)", url)
	}
	if verr := validate_git_url(url); verr != "" {
		die("git origin %q: %s", url, verr)
	}
	if alias == "" {
		alias = identifier_from(os.base(strings.trim_suffix(strings.trim_right(url, "/"), ".git")))
		info("using the name %q (choose another with --as)", alias)
	}
	if is_tool && path != "" {
		die("--path applies to dependencies; a tool uses its author's target path")
	}
	if !is_tool && target != "" {
		die("--target applies to tools; add --tool")
	}

	root := find_project_root()
	manifest_file := join(root, MANIFEST_FILE)
	m := load_manifest(manifest_file)
	if is_tool {
		if find_tool(&m, alias) != nil {
			die("tool %q already exists in meade.kdl", alias)
		}
	} else if find_dependency(&m, alias) != nil {
		die("dependency %q already exists in meade.kdl", alias)
	}

	extra: [dynamic]string
	line: string
	if is_tool {
		append(&extra, "distribution", "build")
		if target != "" && target != alias {
			append(&extra, "target", target)
		}
		line = format_declaration("tool", alias, url, sel, extra[:])
	} else {
		if path != "" {
			append(&extra, "path", path)
		}
		line = format_declaration("dependency", alias, url, sel, extra[:])
	}
	text := insert_into_block(m, is_tool ? "tools" : "dependencies", line)
	if _, err := parse_manifest(text, MANIFEST_FILE); err != "" {
		die("%s", err)
	}

	// Check that the selection exists before recording it.
	if sel.kind != .Rev {
		src, err := resolve_selector(url, sel)
		if err != "" {
			die("%s", err)
		}
		info("%s %s %q resolves to %s", alias, SELECTOR_NAMES[sel.kind], sel.value, short_commit(src.commit))
	}
	write_file_atomic(manifest_file, text)
	info("added %s %q to meade.kdl; run `mead install`", is_tool ? "tool" : "dependency", alias)
}

// Semantic versions, for ordering discovery output.

Semver :: struct {
	major, minor, patch: u64,
	pre:                 string,
}

parse_semver :: proc(tag: string) -> (v: Semver, ok: bool) {
	s := strings.trim_prefix(tag, "v")
	if plus := strings.index_byte(s, '+'); plus >= 0 {
		s = s[:plus]
	}
	if dash := strings.index_byte(s, '-'); dash >= 0 {
		v.pre = s[dash + 1:]
		if v.pre == "" {
			return v, false
		}
		s = s[:dash]
	}
	parts := strings.split(s, ".")
	if len(parts) != 3 {
		return v, false
	}
	nums: [3]u64
	for p, i in parts {
		if p == "" || (len(p) > 1 && p[0] == '0') {
			return v, false
		}
		n, nok := strconv.parse_u64_of_base(p, 10)
		if !nok {
			return v, false
		}
		nums[i] = n
	}
	v.major, v.minor, v.patch = nums[0], nums[1], nums[2]
	return v, true
}

semver_less :: proc(a, b: Semver) -> bool {
	if a.major != b.major {return a.major < b.major}
	if a.minor != b.minor {return a.minor < b.minor}
	if a.patch != b.patch {return a.patch < b.patch}
	if a.pre == b.pre {return false}
	if a.pre == "" {return false}
	if b.pre == "" {return true}
	ap := strings.split(a.pre, ".")
	bp := strings.split(b.pre, ".")
	for i in 0 ..< min(len(ap), len(bp)) {
		an, a_num := strconv.parse_u64_of_base(ap[i], 10)
		bn, b_num := strconv.parse_u64_of_base(bp[i], 10)
		switch {
		case a_num && b_num:
			if an != bn {return an < bn}
		case a_num:
			return true
		case b_num:
			return false
		case ap[i] != bp[i]:
			return ap[i] < bp[i]
		}
	}
	return len(ap) < len(bp)
}

cmd_versions :: proc(args: []string) {
	if len(args) != 1 || strings.has_prefix(args[0], "-") {
		die("usage: mead versions <git-url>")
	}
	url := args[0]
	if verr := validate_git_url(url); verr != "" {
		die("git origin %q: %s", url, verr)
	}
	refs, err := git_ls_remote(url)
	if err != "" {
		die("%s", err)
	}
	tag_commits: map[string]string
	Tag :: struct {
		name, ref, commit: string,
		version:           Semver,
		is_version:        bool,
	}
	version_tags, other_tags: [dynamic]Tag
	Branch :: struct {
		name, ref, commit: string,
	}
	branches: [dynamic]Branch
	for r in refs.refs {
		switch {
		case strings.has_prefix(r.name, "refs/tags/"):
			name := r.name[len("refs/tags/"):]
			commit := remote_ref_commit(r)
			tag_commits[name] = commit
			v, is_version := parse_semver(name)
			t := Tag{name, r.name, commit, v, is_version}
			append(is_version ? &version_tags : &other_tags, t)
		case strings.has_prefix(r.name, "refs/heads/"):
			append(&branches, Branch{r.name[len("refs/heads/"):], r.name, r.object})
		}
	}
	slice.sort_by(version_tags[:], proc(a, b: Tag) -> bool {return semver_less(b.version, a.version)})
	slice.sort_by(other_tags[:], proc(a, b: Tag) -> bool {return a.name < b.name})
	slice.sort_by(branches[:], proc(a, b: Branch) -> bool {return a.name < b.name})

	if gh, is_github := parse_github_url(url); is_github {
		releases, rerr := github_releases(gh)
		fmt.println("GitHub releases (select with release=\"<tag>\"):")
		if rerr != "" {
			fmt.printfln("  unavailable: %s", rerr)
		} else if len(releases) == 0 {
			fmt.println("  none")
		}
		for r in releases {
			status := r.draft ? "draft" : (r.prerelease ? "prerelease" : "stable")
			commit := tag_commits[r.tag_name]
			fmt.printfln("  %-24s %-10s id=%d commit=%s%s", r.tag_name, status, r.id, commit != "" ? short_commit(commit) : "(tag not found)", r.name != "" && r.name != r.tag_name ? fmt.aprintf("  %q", r.name) : "")
			for a in r.assets {
				digest := a.digest != "" ? a.digest : "no digest"
				fmt.printfln("      asset %s id=%d %d bytes %s; target metadata: none", a.name, a.id, a.size, digest)
			}
		}
		fmt.println()
	}

	fmt.println("Version tags (select with tag=\"<tag>\"):")
	if len(version_tags) == 0 {
		fmt.println("  none")
	}
	for t in version_tags {
		fmt.printfln("  %-24s %-10s %s  %s", t.name, t.version.pre != "" ? "prerelease" : "stable", short_commit(t.commit), t.ref)
	}
	fmt.println()
	fmt.println("Other tags:")
	if len(other_tags) == 0 {
		fmt.println("  none")
	}
	for t in other_tags {
		fmt.printfln("  %-24s %s  %s", t.name, short_commit(t.commit), t.ref)
	}
	fmt.println()
	fmt.println("Branches (select with branch=\"<name>\"):")
	for b in branches {
		default_mark := b.ref == refs.head ? "  (default)" : ""
		fmt.printfln("  %-24s %s  %s%s", b.name, short_commit(b.commit), b.ref, default_mark)
	}
}

cmd_update :: proc(args: []string) {
	opts := Install_Options{}
	names: [dynamic]string
	for a in args {
		switch a {
		case "--offline":
			die("update resolves selections at their origins and cannot run offline")
		case:
			if strings.has_prefix(a, "-") {
				die("unknown option %q for update", a)
			}
			append(&names, a)
		}
	}
	root := find_project_root()
	m := load_manifest(join(root, MANIFEST_FILE))
	for n in names {
		if find_dependency(&m, n) == nil && find_tool(&m, n) == nil {
			die("meade.kdl declares no dependency or tool named %q", n)
		}
	}
	opts.update = names[:]
	opts.update_all = len(names) == 0
	install(opts)
}

cmd_install :: proc(args: []string) {
	opts := Install_Options{}
	for a in args {
		switch a {
		case "--locked":  opts.locked = true
		case "--offline": opts.offline = true
		case:
			die("unknown argument %q for install", a)
		}
	}
	install(opts)
}

cmd_exec :: proc(args: []string) {
	if len(args) == 0 {
		die("usage: mead exec <tool> -- <arguments>")
	}
	name := args[0]
	rest := args[1:]
	if len(rest) > 0 && rest[0] == "--" {
		rest = rest[1:]
	}
	root := find_project_root()
	m := load_manifest(join(root, MANIFEST_FILE))
	if find_tool(&m, name) == nil {
		die("meade.kdl declares no tool named %q", name)
	}
	state := load_state(root)
	t := find_installed_tool(&state, name)
	exe := join(root, "deps", ".tools", name, "bin", output_name(name, .Executable))
	if t == nil || !os.is_file(exe) {
		die("tool %q is not installed; run `mead install`", name)
	}
	cmd: [dynamic]string
	append(&cmd, exe)
	append(&cmd, ..rest)
	os.exit(run_inherit(cmd[:]))
}

cmd_tree :: proc(args: []string) {
	if len(args) > 0 {
		die("tree takes no arguments")
	}
	root := find_project_root()
	m := load_manifest(join(root, MANIFEST_FILE))
	lock, has_lock := load_lockfile(root)
	title := m.package_name != "" ? m.package_name : os.base(root)
	if m.package_version != "" {
		fmt.printfln("%s %s", title, m.package_version)
	} else {
		fmt.println(title)
	}
	total := len(m.dependencies) + len(m.tools)
	index := 0
	branch :: proc(index, total: int) -> string {
		return index == total - 1 ? "└── " : "├── "
	}
	for d in m.dependencies {
		ld: ^Locked_Dependency
		if has_lock {
			ld = find_locked_dependency(&lock, d.name)
		}
		identity := "not locked"
		pkg := d.path != "" ? d.path : "?"
		if ld != nil {
			identity = short_commit(ld.source.commit)
			pkg = ld.package_path
		}
		fmt.printfln("%s%s  %s  %s=%s -> %s  path=%s", branch(index, total), d.name, d.git, SELECTOR_NAMES[d.selector.kind], d.selector.value, identity, pkg)
		if ld != nil {
			for sub in ld.dependencies {
				fmt.printfln("%s    └── %s (author-declared, provided by the project)", index == total - 1 ? " " : "│", sub)
			}
		}
		index += 1
	}
	for t in m.tools {
		lt: ^Locked_Tool
		if has_lock {
			lt = find_locked_tool(&lock, t.name)
		}
		identity := lt != nil ? short_commit(lt.source.commit) : "not locked"
		fmt.printfln("%stool %s  %s  %s=%s -> %s  target=%s", branch(index, total), t.name, t.git, SELECTOR_NAMES[t.selector.kind], t.selector.value, identity, t.target)
		index += 1
	}
}

cmd_env :: proc(args: []string) {
	if len(args) > 0 {
		die("env takes no arguments")
	}
	root := find_project_root()
	m := load_manifest(join(root, MANIFEST_FILE))
	state := load_state(root)
	fmt.printfln("project  %s", root)
	fmt.printfln("cache    %s", cache_root())
	if path, ok := find_executable(get_env("MEAD_ODIN") != "" ? get_env("MEAD_ODIN") : "odin"); ok {
		fmt.printfln("odin     %s", absolute(path))
	} else {
		fmt.println("odin     not found")
	}
	fmt.println()
	fmt.println("Dependency bindings:")
	if len(m.dependencies) == 0 {
		fmt.println("  none")
	}
	for d in m.dependencies {
		inst := find_installed_dependency(&state, d.name)
		if inst == nil {
			fmt.printfln("  %-16s not installed", d.name)
			continue
		}
		fmt.printfln("  %-16s %s  (%s)", d.name, inst.package_dir, short_commit(inst.commit))
	}
	fmt.println()
	fmt.println("Tools:")
	if len(m.tools) == 0 {
		fmt.println("  none")
	}
	for t in m.tools {
		inst := find_installed_tool(&state, t.name)
		if inst == nil {
			fmt.printfln("  %-16s not installed", t.name)
			continue
		}
		fmt.printfln("  %-16s %s  (%s)", t.name, inst.executable, short_commit(inst.commit))
	}
}
