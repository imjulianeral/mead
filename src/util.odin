package mead

import "core:crypto/hash"
import "core:encoding/hex"
import "core:fmt"
import "core:os"
import "core:slice"
import "core:strings"
import "core:time"

// Global output switches set by command-line flags.
g_verbose := false
g_quiet := false

die :: proc(format: string, args: ..any) -> ! {
	fmt.eprintf("mead: error: ")
	fmt.eprintfln(format, ..args)
	os.exit(1)
}

warn :: proc(format: string, args: ..any) {
	fmt.eprintf("mead: warning: ")
	fmt.eprintfln(format, ..args)
}

info :: proc(format: string, args: ..any) {
	if !g_quiet {
		fmt.eprintfln(format, ..args)
	}
}

debug :: proc(format: string, args: ..any) {
	if g_verbose {
		fmt.eprintf("mead: ")
		fmt.eprintfln(format, ..args)
	}
}

join :: proc(elems: ..string) -> string {
	p, _ := os.join_path(elems, context.allocator)
	return p
}

// Makes a path absolute without requiring it to exist.
absolute :: proc(path: string) -> string {
	if os.is_absolute_path(path) {
		p, _ := os.clean_path(path, context.allocator)
		return p
	}
	cwd, err := os.get_working_directory(context.allocator)
	if err != nil {
		die("cannot determine the working directory")
	}
	p, _ := os.clean_path(join(cwd, path), context.allocator)
	return p
}

// Reports whether child equals parent or lies inside it. Both must be clean absolute paths.
path_within :: proc(parent, child: string) -> bool {
	if child == parent {
		return true
	}
	p := parent
	if !strings.has_suffix(p, "/") {
		p = strings.concatenate({p, "/"})
	}
	return strings.has_prefix(child, p)
}

// Returns a forward-slash relative path from base to target. Both must be absolute.
relative_path :: proc(base, target: string) -> string {
	rel, err := os.get_relative_path(base, target, context.allocator)
	if err != nil {
		die("cannot compute a relative path from %q to %q", base, target)
	}
	rel, _ = strings.replace_all(rel, "\\", "/")
	return rel
}

read_file :: proc(path: string) -> (string, bool) {
	data, err := os.read_entire_file(path, context.allocator)
	if err != nil {
		return "", false
	}
	return string(data), true
}

// Writes through a temporary file and renames it over the destination.
write_file_atomic :: proc(path: string, data: string) {
	dir := os.dir(path)
	if dir != "" && !os.exists(dir) {
		if err := os.make_directory_all(dir); err != nil {
			die("cannot create %q: %s", dir, os.error_string(err))
		}
	}
	tmp := fmt.aprintf("%s.tmp-%d", path, os.get_pid())
	if err := os.write_entire_file(tmp, data); err != nil {
		die("cannot write %q: %s", tmp, os.error_string(err))
	}
	if err := os.rename(tmp, path); err != nil {
		os.remove(tmp)
		die("cannot replace %q: %s", path, os.error_string(err))
	}
}

make_dirs :: proc(path: string) {
	if err := os.make_directory_all(path); err != nil && !os.is_directory(path) {
		die("cannot create directory %q: %s", path, os.error_string(err))
	}
}

remove_tree :: proc(path: string) {
	if !os.exists(path) && !is_symlink(path) {
		return
	}
	if err := os.remove_all(path); err != nil {
		die("cannot remove %q: %s", path, os.error_string(err))
	}
}

is_symlink :: proc(path: string) -> bool {
	fi, err := os.stat_do_not_follow_links(path, context.allocator)
	return err == nil && fi.type == .Symlink
}

sha256_hex :: proc(data: string) -> string {
	digest := hash.hash_string(.SHA256, data)
	return string(hex.encode(digest))
}

sha256_file_hex :: proc(path: string) -> (string, bool) {
	digest, err := hash.hash_file_by_name(.SHA256, path)
	if err != nil {
		return "", false
	}
	return string(hex.encode(digest)), true
}

Copy_Filter :: #type proc(rel: string, is_dir: bool) -> bool

// Copies a directory tree as independent files. Symlinks stay symlinks, so a
// copied tree never shares writable storage with its source.
copy_tree :: proc(dst, src: string, filter: Copy_Filter = nil) {
	copy_tree_rel(dst, src, "", filter)
}

@(private = "file")
copy_tree_rel :: proc(dst_root, src_root, rel: string, filter: Copy_Filter) {
	src_dir := rel == "" ? src_root : join(src_root, rel)
	dst_dir := rel == "" ? dst_root : join(dst_root, rel)
	make_dirs(dst_dir)
	infos, err := os.read_all_directory_by_path(src_dir, context.allocator)
	if err != nil {
		die("cannot read directory %q: %s", src_dir, os.error_string(err))
	}
	for fi in infos {
		child_rel := rel == "" ? fi.name : join(rel, fi.name)
		src_path := join(src_root, child_rel)
		dst_path := join(dst_root, child_rel)
		lfi, lerr := os.stat_do_not_follow_links(src_path, context.allocator)
		if lerr != nil {
			die("cannot stat %q: %s", src_path, os.error_string(lerr))
		}
		is_dir := lfi.type == .Directory
		if filter != nil && !filter(child_rel, is_dir) {
			continue
		}
		#partial switch lfi.type {
		case .Directory:
			copy_tree_rel(dst_root, src_root, child_rel, filter)
		case .Symlink:
			target, rerr := os.read_link(src_path, context.allocator)
			if rerr != nil {
				die("cannot read link %q: %s", src_path, os.error_string(rerr))
			}
			if serr := os.symlink(target, dst_path); serr != nil {
				die("cannot create link %q: %s", dst_path, os.error_string(serr))
			}
		case .Regular:
			if cerr := os.copy_file(dst_path, src_path); cerr != nil {
				die("cannot copy %q: %s", src_path, os.error_string(cerr))
			}
		}
	}
}

// Lists regular files below root as forward-slash relative paths, in sorted order.
walk_files :: proc(root: string, ext := "") -> [dynamic]string {
	out: [dynamic]string
	walk_rel(root, "", ext, &out)
	slice.sort(out[:])
	return out
}

@(private = "file")
walk_rel :: proc(root, rel, ext: string, out: ^[dynamic]string) {
	dir := rel == "" ? root : join(root, rel)
	infos, err := os.read_all_directory_by_path(dir, context.allocator)
	if err != nil {
		return
	}
	for fi in infos {
		child := rel == "" ? fi.name : strings.concatenate({rel, "/", fi.name})
		lfi, lerr := os.stat_do_not_follow_links(join(root, child), context.allocator)
		if lerr != nil {
			continue
		}
		#partial switch lfi.type {
		case .Directory:
			walk_rel(root, child, ext, out)
		case .Regular, .Symlink:
			// Symlinks count when they resolve to regular files. Linked directories are not followed.
			if lfi.type == .Symlink && !os.is_file(join(root, child)) {
				continue
			}
			if ext == "" || strings.has_suffix(fi.name, ext) {
				append(out, child)
			}
		}
	}
}

// Subprocesses

Run_Result :: struct {
	ok:        bool,
	exit_code: int,
	stdout:    string,
	stderr:    string,
}

// Runs a command with separate arguments and captures its output. No shell is involved.
run_capture :: proc(command: []string, cwd := "", env: []string = nil) -> Run_Result {
	debug("run: %s", strings.join(command, " "))
	desc := os.Process_Desc{command = command, working_dir = cwd, env = env}
	state, stdout, stderr, err := os.process_exec(desc, context.allocator)
	if err != nil {
		return Run_Result{ok = false, exit_code = -1, stderr = fmt.aprintf("cannot run %s: %s", command[0], os.error_string(err))}
	}
	return Run_Result{
		ok = state.exited && state.exit_code == 0 && state.success,
		exit_code = state.exit_code,
		stdout = string(stdout),
		stderr = string(stderr),
	}
}

// Runs a command attached to the current terminal and returns its exit code.
run_inherit :: proc(command: []string, cwd := "", env: []string = nil, stdout: ^os.File = nil) -> int {
	debug("run: %s", strings.join(command, " "))
	desc := os.Process_Desc{
		command = command,
		working_dir = cwd,
		env = env,
		stdin = os.stdin,
		stdout = stdout != nil ? stdout : os.stdout,
		stderr = os.stderr,
	}
	process, err := os.process_start(desc)
	if err != nil {
		die("cannot run %s: %s", command[0], os.error_string(err))
	}
	state, werr := os.process_wait(process)
	if werr != nil {
		die("cannot wait for %s: %s", command[0], os.error_string(werr))
	}
	if !state.exited {
		return 1
	}
	return state.exit_code
}

// Returns the current environment with the given KEY=VALUE entries added or replaced.
env_with :: proc(overrides: ..string) -> []string {
	base, _ := os.environ(context.allocator)
	out: [dynamic]string
	outer: for entry in base {
		for o in overrides {
			key := o[:strings.index_byte(o, '=') + 1]
			if strings.has_prefix(entry, key) {
				continue outer
			}
		}
		append(&out, entry)
	}
	append(&out, ..overrides)
	return out[:]
}

get_env :: proc(key: string) -> string {
	v, _ := os.lookup_env(key, context.allocator)
	return v
}

// Finds an executable on PATH.
find_executable :: proc(name: string) -> (string, bool) {
	if strings.contains_rune(name, '/') {
		return name, os.is_file(name)
	}
	for dir in strings.split(get_env("PATH"), ":") {
		if dir == "" {
			continue
		}
		candidate := join(dir, name)
		if os.is_file(candidate) {
			return candidate, true
		}
	}
	return "", false
}

// A unique scratch directory name component.
unique_suffix :: proc() -> string {
	return fmt.aprintf("%d-%d", os.get_pid(), time.tick_now()._nsec)
}

is_hex :: proc(s: string) -> bool {
	for c in s {
		switch c {
		case '0' ..= '9', 'a' ..= 'f', 'A' ..= 'F':
		case:
			return false
		}
	}
	return len(s) > 0
}

short_commit :: proc(commit: string) -> string {
	return len(commit) > 12 ? commit[:12] : commit
}
