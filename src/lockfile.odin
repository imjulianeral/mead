package mead

import "core:encoding/json"
import "core:os"
import "core:strings"

LOCK_FILE :: "mead.lock"
LOCK_VERSION :: 1
STATE_FILE :: "state.json"

Locked_Selector :: struct {
	kind:  string `json:"kind"`,
	value: string `json:"value"`,
}

// The exact identity of one Git source.
Locked_Source :: struct {
	git:           string          `json:"git"`,
	selector:      Locked_Selector `json:"selector"`,
	// Fully qualified ref, such as refs/tags/v1.2.3. Empty for a `rev` selector.
	ref:           string          `json:"ref"`,
	object_format: string          `json:"object_format"`,
	commit:        string          `json:"commit"`,
	// The GitHub release ID for a `release` selector, otherwise 0.
	// The GitHub release ID for a `release` selector, otherwise 0.
	release_id:    i64             `json:"release_id"`,
}

Locked_Dependency :: struct {
	name:            string   `json:"name"`,
	source:          Locked_Source `json:"source"`,
	// The consumer's path override, or empty.
	requested_path:  string   `json:"requested_path"`,
	// The package directory inside the checkout that the bare name resolves to.
	package_path:    string   `json:"package_path"`,
	author_manifest: bool     `json:"author_manifest"`,
	// Bare names that the author's manifest declares as its own dependencies.
	dependencies:    []string `json:"dependencies"`,
}

Locked_Target :: struct {
	name:  string   `json:"name"`,
	kind:  string   `json:"kind"`,
	path:  string   `json:"path"`,
	flags: []string `json:"flags"`,
}

Locked_Tool :: struct {
	name:         string        `json:"name"`,
	source:       Locked_Source `json:"source"`,
	distribution: string        `json:"distribution"`,
	// The author's target definition at the locked commit.
	target:       Locked_Target `json:"target"`,
}

Lockfile :: struct {
	version:       int                 `json:"version"`,
	manifest_hash: string              `json:"manifest_hash"`,
	dependencies:  []Locked_Dependency `json:"dependencies"`,
	tools:         []Locked_Tool       `json:"tools"`,
}

// Machine-specific installation state. It lives under .mead/ and is never committed.
Installed_Dependency :: struct {
	name:         string `json:"name"`,
	commit:       string `json:"commit"`,
	install_dir:  string `json:"install_dir"`,
	package_dir:  string `json:"package_dir"`,
	package_path: string `json:"package_path"`,
}

Installed_Tool :: struct {
	name:         string `json:"name"`,
	commit:       string `json:"commit"`,
	artifact_key: string `json:"artifact_key"`,
	executable:   string `json:"executable"`,
}

State :: struct {
	version:      int                    `json:"version"`,
	project_root: string                 `json:"project_root"`,
	dependencies: []Installed_Dependency `json:"dependencies"`,
	tools:        []Installed_Tool       `json:"tools"`,
}

selector_to_locked :: proc(s: Selector) -> Locked_Selector {
	return {SELECTOR_NAMES[s.kind], s.value}
}

selector_matches :: proc(s: Selector, l: Locked_Selector) -> bool {
	return SELECTOR_NAMES[s.kind] == l.kind && s.value == l.value
}

load_lockfile :: proc(root: string) -> (lock: Lockfile, found: bool) {
	path := join(root, LOCK_FILE)
	data, ok := read_file(path)
	if !ok {
		return {}, false
	}
	if err := json.unmarshal_string(data, &lock); err != nil {
		die("%s is not a valid mead lockfile: %v", path, err)
	}
	if lock.version != LOCK_VERSION {
		die("%s has unsupported lockfile version %d (this mead writes version %d)", path, lock.version, LOCK_VERSION)
	}
	// Locked values reach git as arguments, so they must have their exact shapes.
	for d in lock.dependencies {
		validate_locked_source(path, d.name, d.source)
	}
	for t in lock.tools {
		validate_locked_source(path, t.name, t.source)
	}
	return lock, true
}

@(private = "file")
validate_locked_source :: proc(path, name: string, src: Locked_Source) {
	if !is_hex(src.commit) || (len(src.commit) != 40 && len(src.commit) != 64) {
		die("%s: %q has an invalid commit ID %q", path, name, src.commit)
	}
	if src.ref != "" && (!strings.has_prefix(src.ref, "refs/") || validate_ref_name(src.ref) != "") {
		die("%s: %q has an invalid ref %q", path, name, src.ref)
	}
	if verr := validate_git_url(src.git); verr != "" {
		die("%s: %q has an invalid origin: %s", path, name, verr)
	}
}

write_lockfile :: proc(root: string, lock: Lockfile) {
	path := join(root, LOCK_FILE)
	text := to_json(lock)
	if old, ok := read_file(path); ok && old == text {
		return
	}
	write_file_atomic(path, text)
}

state_path :: proc(root: string) -> string {
	return join(root, ".mead", STATE_FILE)
}

load_state :: proc(root: string) -> State {
	data, ok := read_file(state_path(root))
	state: State
	if !ok {
		return state
	}
	if err := json.unmarshal_string(data, &state); err != nil {
		warn("ignoring unreadable %s", state_path(root))
		return {}
	}
	return state
}

write_state :: proc(root: string, state: State) {
	s := state
	s.version = 1
	s.project_root = root
	write_file_atomic(state_path(root), to_json(s))
}

to_json :: proc(v: any) -> string {
	opts := json.Marshal_Options{pretty = true, use_spaces = true, spaces = 2}
	data, err := json.marshal(v, opts)
	if err != nil {
		die("cannot encode JSON: %v", err)
	}
	return strings.concatenate({collapse_empty_arrays(string(data)), "\n"})
}

// The pretty printer spreads empty arrays over several lines.
@(private = "file")
collapse_empty_arrays :: proc(s: string) -> string {
	b := strings.builder_make()
	in_string := false
	i := 0
	for i < len(s) {
		if in_string {
			if s[i] == '\\' && i + 1 < len(s) {
				strings.write_string(&b, s[i:i + 2])
				i += 2
				continue
			}
			in_string = s[i] != '"'
		} else if s[i] == '"' {
			in_string = true
		} else if s[i] == '[' {
			j := i + 1
			for j < len(s) && (s[j] == ' ' || s[j] == '\n' || s[j] == '\t' || s[j] == '\r') {
				j += 1
			}
			if j < len(s) && s[j] == ']' {
				strings.write_string(&b, "[]")
				i = j + 1
				continue
			}
		}
		strings.write_byte(&b, s[i])
		i += 1
	}
	return strings.to_string(b)
}

find_locked_dependency :: proc(lock: ^Lockfile, name: string) -> ^Locked_Dependency {
	for &d in lock.dependencies {
		if d.name == name {
			return &d
		}
	}
	return nil
}

find_locked_tool :: proc(lock: ^Lockfile, name: string) -> ^Locked_Tool {
	for &t in lock.tools {
		if t.name == name {
			return &t
		}
	}
	return nil
}

find_installed_dependency :: proc(state: ^State, name: string) -> ^Installed_Dependency {
	for &d in state.dependencies {
		if d.name == name {
			return &d
		}
	}
	return nil
}

find_installed_tool :: proc(state: ^State, name: string) -> ^Installed_Tool {
	for &t in state.tools {
		if t.name == name {
			return &t
		}
	}
	return nil
}

// Ensures the ignore rules that keep installed and generated files out of commits.
ensure_gitignore :: proc(root: string) {
	path := join(root, ".gitignore")
	existing, _ := read_file(path)
	lines := strings.split_lines(existing)
	has :: proc(lines: []string, entry: string) -> bool {
		for l in lines {
			if strings.trim_space(l) == entry {
				return true
			}
		}
		return false
	}
	b := strings.builder_make()
	strings.write_string(&b, existing)
	if len(existing) > 0 && !strings.has_suffix(existing, "\n") {
		strings.write_byte(&b, '\n')
	}
	changed := false
	for entry in ([]string{"/deps/", "/.mead/"}) {
		if !has(lines, entry) {
			strings.write_string(&b, entry)
			strings.write_byte(&b, '\n')
			changed = true
		}
	}
	if changed {
		if err := os.write_entire_file(path, strings.to_string(b)); err != nil {
			warn("cannot update %s: %s", path, os.error_string(err))
		}
	}
}
