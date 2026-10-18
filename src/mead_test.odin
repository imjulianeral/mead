package mead

import "core:strings"
import "core:testing"

@(test)
semver_orders_numerically :: proc(t: ^testing.T) {
	a, aok := parse_semver("1.9.0")
	b, bok := parse_semver("v1.10.0")
	testing.expect(t, aok && bok)
	testing.expect(t, semver_less(a, b))
	testing.expect(t, !semver_less(b, a))

	pre, _ := parse_semver("1.10.0-beta.2")
	pre11, _ := parse_semver("1.10.0-beta.11")
	testing.expect(t, semver_less(pre, b), "a prerelease sorts before its release")
	testing.expect(t, semver_less(pre, pre11), "numeric prerelease identifiers compare numerically")

	_, ok := parse_semver("1.2")
	testing.expect(t, !ok)
	_, ok = parse_semver("01.2.3")
	testing.expect(t, !ok, "leading zeros are invalid")
	_, ok = parse_semver("dev-2026-09")
	testing.expect(t, !ok)
}

@(test)
relative_paths_stay_inside :: proc(t: ^testing.T) {
	clean, err := validate_rel_path("./src//geometry/")
	testing.expect_value(t, clean, "src/geometry")
	testing.expect_value(t, err, "")
	clean, err = validate_rel_path("src/../lib")
	testing.expect_value(t, clean, "lib")
	_, err = validate_rel_path("src/../../x")
	testing.expect(t, err != "")
	_, err = validate_rel_path("/etc")
	testing.expect(t, err != "")
	clean, _ = validate_rel_path(".")
	testing.expect_value(t, clean, ".")
}

@(test)
dependency_names_are_identifiers :: proc(t: ^testing.T) {
	testing.expect_value(t, validate_dependency_name("example_pkg"), "")
	testing.expect(t, validate_dependency_name("shared:foo") != "")
	testing.expect(t, validate_dependency_name("foo/bar") != "")
	testing.expect(t, validate_dependency_name("foo-v2") != "")
	testing.expect(t, validate_dependency_name("1foo") != "")
	testing.expect(t, validate_dependency_name("proc") != "")
	testing.expect(t, validate_dependency_name("COM1") != "")
}

@(test)
git_origins :: proc(t: ^testing.T) {
	testing.expect_value(t, validate_git_url("https://github.com/a/b.git"), "")
	testing.expect_value(t, validate_git_url("ssh://git@host/a/b.git"), "")
	testing.expect_value(t, validate_git_url("git@github.com:a/b.git"), "")
	testing.expect(t, validate_git_url("https://token@github.com/a/b.git") != "")
	testing.expect(t, validate_git_url("http://github.com/a/b.git") != "")
	testing.expect(t, validate_git_url("--upload-pack=x") != "")

	gh, ok := parse_github_url("git@github.com:odin-lang/Odin.git")
	testing.expect(t, ok)
	testing.expect_value(t, gh.owner, "odin-lang")
	testing.expect_value(t, gh.repo, "Odin")
	_, ok = parse_github_url("https://gitlab.com/a/b")
	testing.expect(t, !ok)
}

@(test)
diagnostics_map_to_original_files :: proc(t: ^testing.T) {
	view := Build_View{root = "/p/.mead/build/app/project", original = "/p"}
	edits: [dynamic]Import_Edit
	// `import g "geometry_pkg"` became `import g "../../deps/geometry_pkg/src/geometry"`.
	append(&edits, Import_Edit{line = 3, column = 10, old_len = 14, new_len = 41})
	view.edits["/p/.mead/build/app/project/src/shapes/shapes.odin"] = edits
	out := map_diagnostics(&view, "/p/.mead/build/app/project/src/shapes/shapes.odin(3:60) Error: x\n/p/.mead/build/app/project/src/main.odin(1:1) Error: y\n")
	testing.expect_value(t, out, "/p/src/shapes/shapes.odin(3:33) Error: x\n/p/src/main.odin(1:1) Error: y\n")
}

@(test)
manifest_insertion_keeps_text :: proc(t: ^testing.T) {
	src := "schema 1\n// keep me\ndependencies {\n    dependency \"a\" git=\"https://x.invalid/a\" tag=\"1\" // trailing\n}\n"
	m, err := parse_manifest(src, "meade.kdl")
	testing.expect_value(t, err, "")
	line := format_declaration("dependency", "b", "https://x.invalid/b", Selector{.Tag, "2"}, nil)
	out := insert_into_block(m, "dependencies", line)
	testing.expect_value(t, out, "schema 1\n// keep me\ndependencies {\n    dependency \"a\" git=\"https://x.invalid/a\" tag=\"1\" // trailing\n    dependency \"b\" git=\"https://x.invalid/b\" tag=\"2\"\n}\n")

	m2, _ := parse_manifest("schema 1\n", "meade.kdl")
	out = insert_into_block(m2, "tools", "tool \"t\" git=\"https://x.invalid/t\" tag=\"1\"")
	_, err = parse_manifest(out, "meade.kdl")
	testing.expect_value(t, err, "")

	m3, _ := parse_manifest("schema 1\ndependencies {}\n", "meade.kdl")
	out = insert_into_block(m3, "dependencies", line)
	m4, err4 := parse_manifest(out, "meade.kdl")
	testing.expect_value(t, err4, "")
	testing.expect_value(t, len(m4.dependencies), 1)
}

@(test)
release_checksums :: proc(t: ^testing.T) {
	digest := "3f9c1a7b2e40d5c6a8b9e0f1d2c3b4a5968778695a4b3c2d1e0f9a8b7c6d5e4f"
	sums := strings.concatenate({digest, "  mead-linux-amd64\n", strings.to_upper(digest), " *mead-macos-arm64\n"})
	got, found := sums_lookup(sums, "mead-linux-amd64")
	testing.expect(t, found)
	testing.expect_value(t, got, digest)
	got, found = sums_lookup(sums, "mead-macos-arm64")
	testing.expect(t, found, "binary-mode entries count")
	testing.expect_value(t, got, digest)
	_, found = sums_lookup(sums, "mead-linux")
	testing.expect(t, !found, "names match exactly")
	_, found = sums_lookup("abc123  mead-linux-amd64\n", "mead-linux-amd64")
	testing.expect(t, !found, "a digest must be 64 hex characters")
}

@(test)
release_versions :: proc(t: ^testing.T) {
	testing.expect(t, is_newer_release("v999.0.0"))
	testing.expect(t, !is_newer_release(strings.concatenate({"v", MEAD_VERSION})))
	testing.expect(t, !is_newer_release("v0.0.1"))
	testing.expect(t, !is_newer_release("nightly"), "non-SemVer tags never count as newer")
	testing.expect(t, !is_newer_release(""))
	testing.expect(t, strings.has_prefix(release_asset_name(), "mead-"))
}
