package mead

import "core:fmt"
import "core:odin/tokenizer"
import "core:os"
import "core:strconv"
import "core:strings"

/*
The compiler adapter. Stock Odin resolves an unprefixed import relative to the
importing file, so mead builds a generated copy of the project and its
dependencies under .mead/build/ and rewrites only import literals that exactly
match declared dependency names. Developer and installed sources stay unchanged.
*/

// One replaced import literal, for mapping compiler diagnostics back.
Import_Edit :: struct {
	line:    int,
	column:  int,
	old_len: int,
	new_len: int,
}

Build_View :: struct {
	// The generated project copy.
	root:         string,
	// The directory the generated copy maps back to.
	original:     string,
	edits:        map[string][dynamic]Import_Edit,
}

// The names visible in one dependency scope, mapped to package directories in the view.
Name_Scope :: struct {
	names:        map[string]string,
	// In a scope without an author manifest, a local package with the same name wins.
	prefer_local: bool,
	// Describes the scope in ambiguity errors.
	owner:        string,
}

View_Dependency :: struct {
	name:         string,
	package_path: string,
	// Bare names that the author's manifest declares, or nil without an author manifest.
	scope_names:  []string,
	has_manifest: bool,
}

@(private = "file")
excluded_top_level := []string{"deps", ".mead", ".git", ".hg", ".jj", ".svn"}

@(private = "file")
project_filter :: proc(rel: string, is_dir: bool) -> bool {
	if strings.contains_rune(rel, '/') {
		return true
	}
	for name in excluded_top_level {
		if rel == name {
			return false
		}
	}
	return true
}

@(private = "file")
vcs_filter :: proc(rel: string, is_dir: bool) -> bool {
	return rel != ".git"
}

// Creates the generated build copy for a project and rewrites dependency imports.
create_build_view :: proc(project_root: string, view_dir: string, deps: []View_Dependency) -> Build_View {
	view := Build_View{root = join(view_dir, "project"), original = project_root}
	remove_tree(view_dir)
	copy_tree(view.root, project_root, project_filter)
	view_deps := join(view.root, "deps")
	for d in deps {
		copy_tree(join(view_deps, d.name), join(project_root, "deps", d.name), vcs_filter)
	}

	root_names: map[string]string
	for d in deps {
		root_names[d.name] = join(view_deps, d.name, d.package_path)
	}
	root_scope := Name_Scope{names = root_names, owner = "the project"}
	for rel in walk_files(view.root, ".odin") {
		if strings.has_prefix(rel, "deps/") {
			continue
		}
		rewrite_file(&view, join(view.root, rel), root_scope)
	}
	for d in deps {
		scope := Name_Scope{owner = fmt.aprintf("dependency %q", d.name)}
		if d.has_manifest {
			for n in d.scope_names {
				if target, ok := root_names[n]; ok {
					scope.names[n] = target
				}
			}
		} else {
			scope.names = root_names
			scope.prefer_local = true
		}
		if len(scope.names) == 0 {
			continue
		}
		dep_root := join(view_deps, d.name)
		for rel in walk_files(dep_root, ".odin") {
			rewrite_file(&view, join(dep_root, rel), scope)
		}
	}
	return view
}

@(private = "file")
silent_error :: proc(pos: tokenizer.Pos, msg: string, args: ..any) {}

// Returns the value of an Odin string literal, or false if it cannot name a dependency.
@(private = "file")
literal_value :: proc(text: string) -> (string, bool) {
	if len(text) < 2 {
		return "", false
	}
	if text[0] == '`' {
		return text[1:len(text) - 1], true
	}
	value, _, ok := strconv.unquote_string(text)
	return value, ok
}

@(private = "file")
rewrite_file :: proc(view: ^Build_View, path: string, scope: Name_Scope) {
	src, ok := read_file(path)
	if !ok {
		die("cannot read %s", path)
	}
	t: tokenizer.Tokenizer
	tokenizer.init(&t, src, path, silent_error)

	Replacement :: struct {
		offset, length: int,
		text:           string,
		line, column:   int,
	}
	replacements: [dynamic]Replacement
	prev: tokenizer.Token_Kind
	for {
		tok := tokenizer.scan(&t)
		if tok.kind == .EOF {
			break
		}
		if tok.kind == .Comment {
			continue
		}
		is_import := tok.kind == .Import && prev != .Foreign
		prev = tok.kind
		if !is_import {
			continue
		}
		lit := tokenizer.scan(&t)
		has_alias := false
		if lit.kind == .Ident {
			has_alias = true
			lit = tokenizer.scan(&t)
		}
		prev = lit.kind
		if lit.kind != .String {
			continue
		}
		value, vok := literal_value(lit.text)
		if !vok {
			continue
		}
		target, is_dep := scope.names[value]
		if !is_dep {
			continue
		}
		file_dir := os.dir(path)
		if os.is_directory(join(file_dir, value)) {
			if scope.prefer_local {
				debug("%s:%d: %q names a local package; leaving it unchanged", path, lit.pos.line, value)
				continue
			}
			die("%s:%d:%d: import %q is ambiguous in %s: it names a declared dependency and the local package %s/%s. Rename the dependency in meade.kdl, or import the local package as \"./%s\".",
				original_path(view, path), lit.pos.line, lit.pos.column, value, scope.owner, os.dir(original_path(view, path)), value, value)
		}
		rel := relative_path(file_dir, target)
		if !strings.has_prefix(rel, ".") {
			rel = strings.concatenate({"./", rel})
		}
		quoted := strings.concatenate({"\"", rel, "\""})
		// Odin names an unaliased import after its last path component, so the
		// generated path needs the dependency name as an explicit alias.
		if !has_alias {
			quoted = strings.concatenate({value, " ", quoted})
		}
		append(&replacements, Replacement{lit.pos.offset, len(lit.text), quoted, lit.pos.line, lit.pos.column})
	}
	if len(replacements) == 0 {
		return
	}
	b := strings.builder_make()
	last := 0
	edits: [dynamic]Import_Edit
	for r in replacements {
		strings.write_string(&b, src[last:r.offset])
		strings.write_string(&b, r.text)
		last = r.offset + r.length
		append(&edits, Import_Edit{r.line, r.column, r.length, len(r.text)})
	}
	strings.write_string(&b, src[last:])
	// Remove first, so a symlinked file never writes through to its target.
	os.remove(path)
	if err := os.write_entire_file(path, strings.to_string(b)); err != nil {
		die("cannot write %s: %s", path, os.error_string(err))
	}
	view.edits[path] = edits
}

original_path :: proc(view: ^Build_View, generated: string) -> string {
	if path_within(view.root, generated) {
		return strings.concatenate({view.original, generated[len(view.root):]})
	}
	return generated
}

// Rewrites generated paths in compiler output to original paths, and shifts
// columns on lines whose import literal changed length.
map_diagnostics :: proc(view: ^Build_View, text: string) -> string {
	b := strings.builder_make()
	rest := text
	for {
		i := strings.index(rest, view.root)
		if i < 0 {
			strings.write_string(&b, rest)
			break
		}
		strings.write_string(&b, rest[:i])
		j := i
		for j < len(rest) && rest[j] != '(' && rest[j] != ':' && rest[j] != '\n' && rest[j] != ' ' && rest[j] != '\'' && rest[j] != '"' {
			j += 1
		}
		generated := rest[i:j]
		strings.write_string(&b, original_path(view, generated))
		rest = rest[j:]
		// Diagnostics use path(line:column).
		edits, has_edits := view.edits[generated]
		if !has_edits || !strings.has_prefix(rest, "(") {
			continue
		}
		close := strings.index_byte(rest, ')')
		if close < 0 {
			continue
		}
		parts := strings.split(rest[1:close], ":")
		if len(parts) != 2 {
			continue
		}
		line, lok := strconv.parse_int(parts[0])
		col, cok := strconv.parse_int(parts[1])
		if !lok || !cok {
			continue
		}
		for e in edits {
			if e.line == line && col >= e.column + e.new_len {
				col -= e.new_len - e.old_len
			} else if e.line == line && col > e.column {
				col = e.column
			}
		}
		fmt.sbprintf(&b, "(%d:%d)", line, col)
		rest = rest[close + 1:]
	}
	return strings.to_string(b)
}
