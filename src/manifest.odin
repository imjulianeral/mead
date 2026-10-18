package mead

import "core:fmt"
import "core:os"
import "core:strings"

import kdl "../kdl"

MANIFEST_FILE :: "meade.kdl"
SCHEMA_VERSION :: 1

Selector_Kind :: enum {
	None,
	Tag,
	Branch,
	Rev,
	Release,
}

SELECTOR_NAMES := [Selector_Kind]string {
	.None    = "",
	.Tag     = "tag",
	.Branch  = "branch",
	.Rev     = "rev",
	.Release = "release",
}

Selector :: struct {
	kind:  Selector_Kind,
	value: string,
}

Dependency :: struct {
	name:     string,
	git:      string,
	selector: Selector,
	// Empty when the consumer did not override the author's package path.
	path:     string,
}

Tool :: struct {
	name:         string,
	git:          string,
	selector:     Selector,
	distribution: string,
	target:       string,
}

Target_Kind :: enum {
	Executable,
	Static_Library,
	Shared_Library,
}

TARGET_KIND_NAMES := [Target_Kind]string {
	.Executable     = "executable",
	.Static_Library = "static-library",
	.Shared_Library = "shared-library",
}

Target :: struct {
	name:  string,
	kind:  Target_Kind,
	path:  string,
	flags: [dynamic]string,
}

Manifest :: struct {
	file:            string,
	source:          string,
	doc:             kdl.Document,
	schema:          int,
	package_name:    string,
	package_version: string,
	// The default source package path offered to consumers.
	package_path:    string,
	dependencies:    [dynamic]Dependency,
	tools:           [dynamic]Tool,
	targets:         [dynamic]Target,
}

// Loads and validates a manifest, terminating mead on failure.
load_manifest :: proc(path: string) -> Manifest {
	source, ok := read_file(path)
	if !ok {
		die("cannot read %s (run `mead init` to create one)", path)
	}
	m, err := parse_manifest(source, path)
	if err != "" {
		die("%s", err)
	}
	return m
}

@(private = "file")
Reader :: struct {
	file:   string,
	source: string,
	err:    string,
}

@(private = "file")
fail_at :: proc(r: ^Reader, offset: int, format: string, args: ..any) -> bool {
	if r.err == "" {
		line, col := kdl.line_column(r.source, offset)
		r.err = fmt.aprintf("%s:%d:%d: %s", r.file, line, col, fmt.aprintf(format, ..args))
	}
	return false
}

// Parses and validates manifest text. Returns a located error message on failure.
parse_manifest :: proc(source: string, file: string) -> (m: Manifest, err: string) {
	doc, perr, ok := kdl.parse(source)
	if !ok {
		return m, fmt.aprintf("%s:%d:%d: KDL syntax error: %s", file, perr.line, perr.column, perr.msg)
	}
	r := Reader{file = file, source = source}
	m.file = file
	m.source = source
	m.doc = doc
	read_manifest(&r, &m, doc)
	return m, r.err
}

@(private = "file")
read_manifest :: proc(r: ^Reader, m: ^Manifest, doc: kdl.Document) -> bool {
	seen: map[string]int
	for &n in doc.nodes {
		if n.has_type {
			return fail_at(r, n.offset, "type annotations are not part of the mead schema")
		}
		switch n.name {
		case "schema", "package", "dependencies", "tools", "targets":
			if prev, dup := seen[n.name]; dup {
				pl, _ := kdl.line_column(r.source, prev)
				return fail_at(r, n.offset, "duplicate %q node (first declared on line %d)", n.name, pl)
			}
			seen[n.name] = n.offset
		case:
			return fail_at(r, n.offset, "unknown node %q", n.name)
		}
	}
	if _, has := seen["schema"]; !has {
		return fail_at(r, 0, "missing `schema %d` declaration", SCHEMA_VERSION)
	}
	for &n in doc.nodes {
		switch n.name {
		case "schema":
			read_schema(r, m, &n) or_return
		case "package":
			read_package(r, m, &n) or_return
		case "dependencies":
			read_dependencies(r, m, &n) or_return
		case "tools":
			read_tools(r, m, &n) or_return
		case "targets":
			read_targets(r, m, &n) or_return
		}
	}
	return true
}

// Shared node checks

@(private = "file")
check_props :: proc(r: ^Reader, n: ^kdl.Node, allowed: []string) -> bool {
	seen: map[string]bool
	for e in n.entries {
		if !e.is_prop {
			continue
		}
		known := false
		for a in allowed {
			if a == e.name {
				known = true
			}
		}
		if !known {
			return fail_at(r, e.offset, "unknown property %q on %q", e.name, n.name)
		}
		if seen[e.name] {
			return fail_at(r, e.offset, "duplicate property %q on %q", e.name, n.name)
		}
		seen[e.name] = true
		if e.value.has_type {
			return fail_at(r, e.offset, "type annotations are not part of the mead schema")
		}
	}
	return true
}

@(private = "file")
args_of :: proc(n: ^kdl.Node) -> [dynamic]kdl.Entry {
	out: [dynamic]kdl.Entry
	for e in n.entries {
		if !e.is_prop {
			append(&out, e)
		}
	}
	return out
}

@(private = "file")
single_string_arg :: proc(r: ^Reader, n: ^kdl.Node, what: string) -> (value: string, ok: bool) {
	args := args_of(n)
	if len(args) != 1 {
		return "", fail_at(r, n.offset, "%q takes exactly one argument: the %s", n.name, what)
	}
	s, is_str := kdl.entry_string(args[0])
	if !is_str || args[0].value.has_type {
		return "", fail_at(r, args[0].offset, "the %s of %q must be a string", what, n.name)
	}
	return s, true
}

@(private = "file")
prop_string :: proc(r: ^Reader, n: ^kdl.Node, name: string) -> (value: string, found: bool, ok: bool) {
	for e in n.entries {
		if e.is_prop && e.name == name {
			s, is_str := kdl.entry_string(e)
			if !is_str {
				return "", true, fail_at(r, e.offset, "property %q must be a string", name)
			}
			return s, true, true
		}
	}
	return "", false, true
}

@(private = "file")
no_children :: proc(r: ^Reader, n: ^kdl.Node) -> bool {
	if n.has_children {
		return fail_at(r, n.children_open, "%q does not take children", n.name)
	}
	return true
}

@(private = "file")
container :: proc(r: ^Reader, n: ^kdl.Node, child: string) -> bool {
	if len(n.entries) > 0 {
		return fail_at(r, n.entries[0].offset, "%q takes no arguments or properties", n.name)
	}
	for &c in n.children {
		if c.name != child || c.has_type {
			return fail_at(r, c.offset, "unexpected node %q inside %q (expected %q)", c.name, n.name, child)
		}
	}
	return true
}

// Node readers

@(private = "file")
read_schema :: proc(r: ^Reader, m: ^Manifest, n: ^kdl.Node) -> bool {
	check_props(r, n, {}) or_return
	no_children(r, n) or_return
	args := args_of(n)
	if len(args) != 1 || args[0].value.kind != .Integer || !args[0].value.int_ok {
		return fail_at(r, n.offset, "`schema` takes one integer argument")
	}
	m.schema = int(args[0].value.int_val)
	if m.schema != SCHEMA_VERSION {
		return fail_at(r, args[0].offset, "unsupported schema version %d (this mead supports schema %d)", m.schema, SCHEMA_VERSION)
	}
	return true
}

@(private = "file")
read_package :: proc(r: ^Reader, m: ^Manifest, n: ^kdl.Node) -> bool {
	check_props(r, n, {"version", "path"}) or_return
	no_children(r, n) or_return
	m.package_name = single_string_arg(r, n, "package name") or_return
	if m.package_name == "" {
		return fail_at(r, n.offset, "the package name cannot be empty")
	}
	m.package_version, _ = prop_string(r, n, "version") or_return
	path, has_path := prop_string(r, n, "path") or_return
	m.package_path = "."
	if has_path {
		clean, perr := validate_rel_path(path)
		if perr != "" {
			return fail_at(r, n.offset, "package path %q: %s", path, perr)
		}
		m.package_path = clean
	}
	return true
}

@(private = "file")
read_selector :: proc(r: ^Reader, n: ^kdl.Node) -> (sel: Selector, ok: bool) {
	for e in n.entries {
		if !e.is_prop {
			continue
		}
		kind: Selector_Kind
		switch e.name {
		case "tag":     kind = .Tag
		case "branch":  kind = .Branch
		case "rev":     kind = .Rev
		case "release": kind = .Release
		case:           continue
		}
		if sel.kind != .None {
			return sel, fail_at(r, e.offset, "%q has both `%s` and `%s`; choose exactly one of tag, branch, rev, or release", n.name, SELECTOR_NAMES[sel.kind], e.name)
		}
		value, is_str := kdl.entry_string(e)
		if !is_str || value == "" {
			return sel, fail_at(r, e.offset, "`%s` must be a non-empty string", e.name)
		}
		sel = Selector{kind, value}
	}
	if sel.kind == .None {
		return sel, fail_at(r, n.offset, "%q needs one revision selector: tag, branch, rev, or release", n.name)
	}
	if sel.kind == .Rev {
		if !is_hex(sel.value) || (len(sel.value) != 40 && len(sel.value) != 64) {
			return sel, fail_at(r, n.offset, "`rev` must be a full 40- or 64-character commit ID")
		}
		sel.value = strings.to_lower(sel.value)
	}
	if sel.kind == .Branch || sel.kind == .Tag || sel.kind == .Release {
		if verr := validate_ref_name(sel.value); verr != "" {
			return sel, fail_at(r, n.offset, "invalid %s %q: %s", SELECTOR_NAMES[sel.kind], sel.value, verr)
		}
	}
	return sel, true
}

@(private = "file")
read_git :: proc(r: ^Reader, n: ^kdl.Node) -> (value: string, ok: bool) {
	url, found := prop_string(r, n, "git") or_return
	if !found {
		return "", fail_at(r, n.offset, "%q needs a `git` origin", n.name)
	}
	if verr := validate_git_url(url); verr != "" {
		return "", fail_at(r, n.offset, "git origin %q: %s", url, verr)
	}
	return url, true
}

@(private = "file")
check_name_collision :: proc(r: ^Reader, n: ^kdl.Node, name: string, seen: ^map[string]string, scope: string) -> bool {
	// Case-insensitive filesystems would merge names that differ only in case.
	folded := strings.to_lower(name)
	if prev, dup := seen[folded]; dup {
		if prev == name {
			return fail_at(r, n.offset, "duplicate %s %q", scope, name)
		}
		return fail_at(r, n.offset, "%s %q collides with %q on case-insensitive filesystems", scope, name, prev)
	}
	seen[folded] = name
	return true
}

@(private = "file")
read_dependencies :: proc(r: ^Reader, m: ^Manifest, n: ^kdl.Node) -> bool {
	container(r, n, "dependency") or_return
	seen: map[string]string
	for &c in n.children {
		check_props(r, &c, {"git", "tag", "branch", "rev", "release", "path"}) or_return
		no_children(r, &c) or_return
		d: Dependency
		d.name = single_string_arg(r, &c, "dependency name") or_return
		if nerr := validate_dependency_name(d.name); nerr != "" {
			return fail_at(r, c.offset, "dependency name %q: %s", d.name, nerr)
		}
		check_name_collision(r, &c, d.name, &seen, "dependency") or_return
		d.git = read_git(r, &c) or_return
		d.selector = read_selector(r, &c) or_return
		path, has_path := prop_string(r, &c, "path") or_return
		if has_path {
			clean, perr := validate_rel_path(path)
			if perr != "" {
				return fail_at(r, c.offset, "dependency path %q: %s", path, perr)
			}
			d.path = clean
		}
		append(&m.dependencies, d)
	}
	return true
}

@(private = "file")
read_tools :: proc(r: ^Reader, m: ^Manifest, n: ^kdl.Node) -> bool {
	container(r, n, "tool") or_return
	seen: map[string]string
	for &c in n.children {
		check_props(r, &c, {"git", "tag", "branch", "rev", "release", "distribution", "target"}) or_return
		no_children(r, &c) or_return
		t: Tool
		t.name = single_string_arg(r, &c, "tool name") or_return
		if nerr := validate_dependency_name(t.name); nerr != "" {
			return fail_at(r, c.offset, "tool name %q: %s", t.name, nerr)
		}
		check_name_collision(r, &c, t.name, &seen, "tool") or_return
		t.git = read_git(r, &c) or_return
		t.selector = read_selector(r, &c) or_return
		dist, has_dist := prop_string(r, &c, "distribution") or_return
		t.distribution = has_dist ? dist : "build"
		switch t.distribution {
		case "build":
		case "asset":
			return fail_at(r, c.offset, "tool %q: `distribution=\"asset\"` needs release asset contracts, which this mead does not support yet; use \"build\"", t.name)
		case:
			return fail_at(r, c.offset, "tool %q: distribution must be \"build\" or \"asset\"", t.name)
		}
		target, has_target := prop_string(r, &c, "target") or_return
		t.target = has_target ? target : t.name
		if t.target == "" {
			return fail_at(r, c.offset, "tool %q: target cannot be empty", t.name)
		}
		append(&m.tools, t)
	}
	return true
}

@(private = "file")
read_targets :: proc(r: ^Reader, m: ^Manifest, n: ^kdl.Node) -> bool {
	container(r, n, "target") or_return
	seen: map[string]string
	for &c in n.children {
		check_props(r, &c, {"kind", "path"}) or_return
		t: Target
		t.name = single_string_arg(r, &c, "target name") or_return
		if nerr := validate_dependency_name(t.name); nerr != "" {
			return fail_at(r, c.offset, "target name %q: %s", t.name, nerr)
		}
		check_name_collision(r, &c, t.name, &seen, "target") or_return
		kind, has_kind := prop_string(r, &c, "kind") or_return
		if !has_kind {
			return fail_at(r, c.offset, "target %q needs a `kind`", t.name)
		}
		kind_ok := false
		for name, k in TARGET_KIND_NAMES {
			if name == kind {
				t.kind = k
				kind_ok = true
			}
		}
		if !kind_ok {
			return fail_at(r, c.offset, "target %q has invalid kind %q (expected executable, static-library, or shared-library)", t.name, kind)
		}
		path, has_path := prop_string(r, &c, "path") or_return
		if !has_path {
			return fail_at(r, c.offset, "target %q needs a `path`", t.name)
		}
		clean, perr := validate_rel_path(path)
		if perr != "" {
			return fail_at(r, c.offset, "target path %q: %s", path, perr)
		}
		t.path = clean
		seen_flags := false
		for &f in c.children {
			if f.name != "flags" || f.has_type {
				return fail_at(r, f.offset, "unexpected node %q inside target %q (expected \"flags\")", f.name, t.name)
			}
			if seen_flags {
				return fail_at(r, f.offset, "target %q has more than one `flags` node", t.name)
			}
			seen_flags = true
			check_props(r, &f, {}) or_return
			no_children(r, &f) or_return
			for e in f.entries {
				s, is_str := kdl.entry_string(e)
				if !is_str || e.value.has_type {
					return fail_at(r, e.offset, "compiler flags must be strings")
				}
				if ferr := validate_flag(s); ferr != "" {
					return fail_at(r, e.offset, "flag %q: %s", s, ferr)
				}
				append(&t.flags, s)
			}
		}
		append(&m.targets, t)
	}
	return true
}

// Field validation

ODIN_KEYWORDS := []string {
	"asm", "auto_cast", "bit_field", "bit_set", "break", "case", "cast", "context", "continue",
	"defer", "distinct", "do", "dynamic", "else", "enum", "fallthrough", "for", "foreign", "if",
	"import", "in", "map", "matrix", "not_in", "or_break", "or_continue", "or_else", "or_return",
	"package", "proc", "return", "struct", "switch", "transmute", "typeid", "union", "using",
	"when", "where",
}

// A dependency name is one portable directory component and a valid Odin identifier.
validate_dependency_name :: proc(name: string) -> string {
	if name == "" {
		return "a name cannot be empty"
	}
	for c, i in name {
		ok := c == '_' || (c >= 'a' && c <= 'z') || (c >= 'A' && c <= 'Z') || (i > 0 && c >= '0' && c <= '9')
		if !ok {
			return "a name must be an Odin identifier: ASCII letters, digits, and underscores, not starting with a digit; import prefixes, path separators, and version suffixes are not allowed"
		}
	}
	for k in ODIN_KEYWORDS {
		if name == k {
			return "a name cannot be an Odin keyword"
		}
	}
	lower := strings.to_lower(name)
	switch lower {
	case "con", "prn", "aux", "nul", "deps":
		return "this name is reserved"
	}
	if len(lower) == 4 && (strings.has_prefix(lower, "com") || strings.has_prefix(lower, "lpt")) && lower[3] >= '0' && lower[3] <= '9' {
		return "this name is reserved on Windows"
	}
	return ""
}

// Normalizes a repository-relative path and rejects paths that leave the repository.
validate_rel_path :: proc(path: string) -> (clean: string, err: string) {
	if path == "" {
		return "", "a path cannot be empty"
	}
	if strings.contains_rune(path, '\\') {
		return "", "use forward slashes"
	}
	if strings.has_prefix(path, "/") || (len(path) > 1 && path[1] == ':') {
		return "", "the path must be relative to the repository"
	}
	parts: [dynamic]string
	for part in strings.split(path, "/") {
		switch part {
		case "", ".":
			continue
		case "..":
			if len(parts) == 0 {
				return "", "the path leaves the repository"
			}
			pop(&parts)
		case:
			append(&parts, part)
		}
	}
	if len(parts) == 0 {
		return ".", ""
	}
	return strings.join(parts[:], "/"), ""
}

// Mead owns output, collection, target-platform, and build-mode arguments.
validate_flag :: proc(flag: string) -> string {
	if !strings.has_prefix(flag, "-") {
		return "compiler flags must start with '-'"
	}
	owned := []string{"-out:", "-collection:", "-target:", "-build-mode:", "-subtarget:", "-target-features:", "-microarch:"}
	for prefix in owned {
		if strings.has_prefix(flag, prefix) {
			return "mead controls this compiler argument"
		}
	}
	switch flag {
	case "-file", "-no-entry-point":
		return "mead controls this compiler argument"
	}
	return ""
}

validate_ref_name :: proc(name: string) -> string {
	if strings.has_prefix(name, "-") {
		return "a ref name cannot start with '-'"
	}
	for c in name {
		if c <= ' ' || c == 0x7F || c == '~' || c == '^' || c == ':' || c == '?' || c == '*' || c == '[' || c == '\\' {
			return "the name contains a character that Git does not allow in refs"
		}
	}
	if strings.contains(name, "..") || strings.contains(name, "@{") || strings.has_suffix(name, ".lock") || strings.has_suffix(name, "/") {
		return "the name is not a valid Git ref"
	}
	return ""
}

// Initially mead supports HTTPS and SSH origins. Local file origins exist for
// offline mirrors and tests. Credentials never belong in an origin.
validate_git_url :: proc(url: string) -> string {
	if url == "" {
		return "the origin cannot be empty"
	}
	if strings.has_prefix(url, "-") {
		return "the origin cannot start with '-'"
	}
	for c in url {
		if c <= ' ' || c == 0x7F {
			return "the origin cannot contain spaces or control characters"
		}
	}
	switch {
	case strings.has_prefix(url, "https://"):
		rest := url[len("https://"):]
		authority := rest
		if slash := strings.index_byte(rest, '/'); slash >= 0 {
			authority = rest[:slash]
		}
		if strings.contains_rune(authority, '@') {
			return "credentials do not belong in the manifest; use a Git credential helper"
		}
		if authority == "" {
			return "the origin has no host"
		}
		return ""
	case strings.has_prefix(url, "ssh://"):
		rest := url[len("ssh://"):]
		authority := rest
		if slash := strings.index_byte(rest, '/'); slash >= 0 {
			authority = rest[:slash]
		}
		if at := strings.index_byte(authority, '@'); at >= 0 && strings.contains_rune(authority[:at], ':') {
			return "credentials do not belong in the manifest; use SSH keys or an agent"
		}
		return ""
	case strings.has_prefix(url, "file://"):
		return ""
	case strings.contains(url, "://"):
		return "unsupported origin scheme; use https://, ssh://, or user@host:path"
	}
	// scp-like SSH syntax: user@host:path
	colon := strings.index_byte(url, ':')
	at := strings.index_byte(url, '@')
	if colon > 0 && at > 0 && at < colon && !strings.contains_rune(url[:at], ':') {
		return ""
	}
	return "unsupported origin; use https://, ssh://, or user@host:path"
}

// The canonical declaration text that the lockfile hash covers.
declaration_text :: proc(m: Manifest) -> string {
	b := strings.builder_make()
	for d in m.dependencies {
		fmt.sbprintf(&b, "dependency\x00%s\x00%s\x00%s\x00%s\x00%s\n", d.name, d.git, SELECTOR_NAMES[d.selector.kind], d.selector.value, d.path)
	}
	for t in m.tools {
		fmt.sbprintf(&b, "tool\x00%s\x00%s\x00%s\x00%s\x00%s\x00%s\n", t.name, t.git, SELECTOR_NAMES[t.selector.kind], t.selector.value, t.distribution, t.target)
	}
	for t in m.targets {
		fmt.sbprintf(&b, "target\x00%s\x00%s\x00%s", t.name, TARGET_KIND_NAMES[t.kind], t.path)
		for f in t.flags {
			fmt.sbprintf(&b, "\x00%s", f)
		}
		strings.write_byte(&b, '\n')
	}
	return strings.to_string(b)
}

manifest_hash :: proc(m: Manifest) -> string {
	return strings.concatenate({"sha256:", sha256_hex(declaration_text(m))})
}

find_dependency :: proc(m: ^Manifest, name: string) -> ^Dependency {
	for &d in m.dependencies {
		if d.name == name {
			return &d
		}
	}
	return nil
}

find_tool :: proc(m: ^Manifest, name: string) -> ^Tool {
	for &t in m.tools {
		if t.name == name {
			return &t
		}
	}
	return nil
}

find_target :: proc(m: ^Manifest, name: string) -> ^Target {
	for &t in m.targets {
		if t.name == name {
			return &t
		}
	}
	return nil
}

// Locates the project root by searching upward for meade.kdl.
find_project_root :: proc() -> string {
	cwd, err := os.get_working_directory(context.allocator)
	if err != nil {
		die("cannot determine the working directory")
	}
	dir := cwd
	for {
		if os.is_file(join(dir, MANIFEST_FILE)) {
			return dir
		}
		parent := os.dir(dir)
		if parent == dir || parent == "" {
			break
		}
		dir = parent
	}
	die("no %s found in %s or its parent directories (run `mead init`)", MANIFEST_FILE, cwd)
}

// Manifest editing. Mead inserts new text and leaves the rest of the file,
// including comments, byte-for-byte unchanged.

// Formats a dependency or tool declaration line.
format_declaration :: proc(node_name, name, git: string, sel: Selector, extra: []string) -> string {
	b := strings.builder_make()
	fmt.sbprintf(&b, "%s %s git=%s %s=%s", node_name, kdl.quote_string(name), kdl.quote_string(git), SELECTOR_NAMES[sel.kind], kdl.quote_string(sel.value))
	for i := 0; i + 1 < len(extra); i += 2 {
		fmt.sbprintf(&b, " %s=%s", extra[i], kdl.quote_string(extra[i + 1]))
	}
	return strings.to_string(b)
}

// Returns new manifest text with `line` added inside the named top-level block.
insert_into_block :: proc(m: Manifest, block: string, line: string) -> string {
	src := m.source
	for n in m.doc.nodes {
		if n.name != block {
			continue
		}
		if !n.has_children {
			return strings.concatenate({src[:n.end], " {\n    ", line, "\n}", src[n.end:]})
		}
		indent := "    "
		if len(n.children) > 0 {
			indent = line_indent(src, n.children[0].offset)
		} else {
			indent = strings.concatenate({line_indent(src, n.offset), "    "})
		}
		close := n.children_close
		line_start := close
		for line_start > 0 && src[line_start - 1] != '\n' {
			line_start -= 1
		}
		if strings.trim_space(src[line_start:close]) == "" {
			return strings.concatenate({src[:line_start], indent, line, "\n", src[line_start:]})
		}
		return strings.concatenate({src[:close], "\n", indent, line, "\n", line_indent(src, n.offset), src[close:]})
	}
	sep := strings.has_suffix(src, "\n") ? "\n" : "\n\n"
	return strings.concatenate({src, sep, block, " {\n    ", line, "\n}\n"})
}

@(private = "file")
line_indent :: proc(src: string, offset: int) -> string {
	start := offset
	for start > 0 && src[start - 1] != '\n' {
		start -= 1
	}
	end := start
	for end < len(src) && (src[end] == ' ' || src[end] == '\t') {
		end += 1
	}
	return src[start:end]
}
