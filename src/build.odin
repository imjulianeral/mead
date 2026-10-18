package mead

import "core:fmt"
import "core:os"
import "core:slice"
import "core:strings"

Toolchain :: struct {
	odin:    string,
	root:    string,
	version: string,
}

find_toolchain :: proc() -> Toolchain {
	name := get_env("MEAD_ODIN")
	if name == "" {
		name = "odin"
	}
	path, found := find_executable(name)
	if !found {
		die("cannot find the Odin compiler `%s` on PATH (set MEAD_ODIN to its location)", name)
	}
	tc := Toolchain{odin = absolute(path)}
	res := run_capture({tc.odin, "version"})
	if !res.ok {
		die("`%s version` failed: %s", tc.odin, strings.trim_space(res.stderr))
	}
	tc.version = strings.trim_space(res.stdout)
	res = run_capture({tc.odin, "root"})
	if !res.ok {
		die("`%s root` failed: %s", tc.odin, strings.trim_space(res.stderr))
	}
	tc.root = strings.trim_space(res.stdout)
	return tc
}

/*
A digest of the compiler binary, its base/core/vendor collections, and the
native linker. `odin version` alone cannot distinguish every compiler build.
The content digest is cached under a key made of file metadata, so it is only
recomputed when some toolchain file changes.
*/
@(private = "file")
fingerprint_memo: map[string]string

toolchain_fingerprint :: proc(tc: Toolchain) -> string {
	if memo, ok := fingerprint_memo[tc.odin]; ok {
		return memo
	}
	fingerprint := compute_toolchain_fingerprint(tc)
	fingerprint_memo[tc.odin] = fingerprint
	return fingerprint
}

@(private = "file")
compute_toolchain_fingerprint :: proc(tc: Toolchain) -> string {
	collections := []string{"base", "core", "vendor"}
	meta := strings.builder_make()
	files: [dynamic]string
	if fi, err := os.stat(tc.odin, context.allocator); err == nil {
		fmt.sbprintf(&meta, "%s\x00%d\x00%v\n", tc.odin, fi.size, fi.modification_time)
	}
	for c in collections {
		dir := join(tc.root, c)
		for rel in walk_files(dir) {
			path := join(dir, rel)
			fi, err := os.stat(path, context.allocator)
			if err != nil {
				continue
			}
			fmt.sbprintf(&meta, "%s/%s\x00%d\x00%v\n", c, rel, fi.size, fi.modification_time)
			append(&files, path)
		}
	}
	linker := native_linker_version()
	strings.write_string(&meta, linker)
	meta_key := sha256_hex(strings.to_string(meta))
	cache_file := join(cache_root(), "toolchains", meta_key)
	if cached, ok := read_file(cache_file); ok && len(cached) == 64 {
		return cached
	}

	info("fingerprinting the Odin toolchain at %s", tc.root)
	content := strings.builder_make()
	odin_digest, _ := sha256_file_hex(tc.odin)
	fmt.sbprintf(&content, "odin\x00%s\x00%s\n", tc.version, odin_digest)
	for path in files {
		digest, _ := sha256_file_hex(path)
		fmt.sbprintf(&content, "%s\x00%s\n", path[len(tc.root):], digest)
	}
	strings.write_string(&content, linker)
	fingerprint := sha256_hex(strings.to_string(content))
	write_file_atomic(cache_file, fingerprint)
	return fingerprint
}

@(private = "file")
native_linker_version :: proc() -> string {
	when ODIN_OS == .Windows {
		return "msvc"
	} else {
		linker := get_env("ODIN_CLANG_PATH")
		if linker == "" {
			linker = "clang"
		}
		res := run_capture({linker, "--version"})
		return fmt.aprintf("linker\x00%s\x00%s\n", linker, strings.trim_space(res.stdout))
	}
}

output_name :: proc(name: string, kind: Target_Kind) -> string {
	switch kind {
	case .Executable:
		when ODIN_OS == .Windows {
			return strings.concatenate({name, ".exe"})
		} else {
			return name
		}
	case .Static_Library:
		when ODIN_OS == .Windows {
			return strings.concatenate({name, ".lib"})
		} else {
			return strings.concatenate({"lib", name, ".a"})
		}
	case .Shared_Library:
		when ODIN_OS == .Windows {
			return strings.concatenate({name, ".dll"})
		} else when ODIN_OS == .Darwin {
			return strings.concatenate({"lib", name, ".dylib"})
		} else {
			return strings.concatenate({"lib", name, ".so"})
		}
	}
	return name
}

// Assembles an `odin build` command. Mead owns the output path and build mode.
compiler_command :: proc(tc: Toolchain, package_dir: string, out: string, kind: Target_Kind, flags: []string) -> []string {
	cmd: [dynamic]string
	append(&cmd, tc.odin, "build", package_dir, strings.concatenate({"-out:", out}))
	switch kind {
	case .Executable:
	case .Static_Library:
		append(&cmd, "-build-mode:static")
	case .Shared_Library:
		append(&cmd, "-build-mode:shared")
	}
	append(&cmd, ..flags)
	return cmd[:]
}

// Checks that every declared dependency is installed at its locked commit.
installed_view_dependencies :: proc(root: string, m: ^Manifest) -> []View_Dependency {
	lock, has_lock := load_lockfile(root)
	state := load_state(root)
	if len(m.dependencies) > 0 && !has_lock {
		die("dependencies are not installed; run `mead install`")
	}
	out: [dynamic]View_Dependency
	for d in m.dependencies {
		ld := find_locked_dependency(&lock, d.name)
		inst := find_installed_dependency(&state, d.name)
		if ld == nil {
			die("dependency %q is not locked; run `mead install`", d.name)
		}
		if ld.source.git != d.git || !selector_matches(d.selector, ld.source.selector) || ld.requested_path != d.path {
			die("the declaration of %q changed since mead.lock was written; run `mead update %s`", d.name, d.name)
		}
		if inst == nil || inst.commit != ld.source.commit || inst.package_path != ld.package_path || !os.is_directory(join(root, "deps", d.name)) {
			die("dependency %q is not installed at its locked commit; run `mead install`", d.name)
		}
		append(&out, View_Dependency{
			name = d.name,
			package_path = ld.package_path,
			scope_names = ld.dependencies,
			has_manifest = ld.author_manifest,
		})
	}
	return out[:]
}

cmd_build :: proc(args: []string, run_after: bool) {
	target_name := ""
	run_args: []string
	for a, i in args {
		if a == "--" {
			run_args = args[i + 1:]
			break
		}
		if target_name == "" && !strings.has_prefix(a, "-") {
			target_name = a
			continue
		}
		if run_after && target_name != "" {
			run_args = args[i:]
			break
		}
		die("unexpected argument %q", a)
	}

	root := find_project_root()
	m := load_manifest(join(root, MANIFEST_FILE))
	if len(m.targets) == 0 {
		die("meade.kdl declares no targets")
	}
	target: ^Target
	if target_name == "" {
		if len(m.targets) > 1 {
			names: [dynamic]string
			for t in m.targets {
				append(&names, t.name)
			}
			die("choose a target: %s", strings.join(names[:], ", "))
		}
		target = &m.targets[0]
	} else {
		target = find_target(&m, target_name)
		if target == nil {
			die("no target named %q in meade.kdl", target_name)
		}
	}
	if run_after && target.kind != .Executable {
		die("target %q is a %s, not an executable", target.name, TARGET_KIND_NAMES[target.kind])
	}

	project_lock := lock_acquire(join(root, ".mead", "project.lock"))
	deps := installed_view_dependencies(root, &m)
	tc := find_toolchain()
	view := create_build_view(root, join(root, ".mead", "build", target.name), deps)
	package_dir := join(view.root, target.path)
	if !os.is_directory(package_dir) {
		die("target %q: package directory %s does not exist", target.name, join(root, target.path))
	}
	bin_dir := join(root, ".mead", "bin")
	make_dirs(bin_dir)
	out := join(bin_dir, output_name(target.name, target.kind))
	info("building %s", target.name)
	res := run_capture(compiler_command(tc, package_dir, out, target.kind, target.flags[:]), cwd = view.root)
	if len(res.stdout) > 0 {
		fmt.print(map_diagnostics(&view, res.stdout))
	}
	if len(res.stderr) > 0 {
		fmt.eprint(map_diagnostics(&view, res.stderr))
	}
	lock_release(project_lock)
	if !res.ok {
		die("build of %s failed", target.name)
	}
	info("built %s", out)
	if run_after {
		cmd: [dynamic]string
		append(&cmd, out)
		append(&cmd, ..run_args)
		os.exit(run_inherit(cmd[:]))
	}
}

sorted_keys :: proc(m: map[string]string) -> []string {
	keys: [dynamic]string
	for k in m {
		append(&keys, k)
	}
	slice.sort(keys[:])
	return keys[:]
}
