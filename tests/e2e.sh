#!/usr/bin/env bash
# End-to-end tests for mead with local Git origins. Requires git and odin.
# Usage: tests/e2e.sh [path-to-mead]
set -uo pipefail

here=$(cd "$(dirname "$0")" && pwd)
mead=$(realpath "${1:-$here/../build/mead}")
work=$(mktemp -d "${TMPDIR:-/tmp}/mead-e2e.XXXXXX")
trap 'rm -rf "$work"' EXIT
export MEAD_CACHE_DIR="$work/cache"
unset GITHUB_TOKEN GH_TOKEN

"$here/fixtures.sh" "$work" >/dev/null
project="$work/project"
passed=0
failed=0

pass() { passed=$((passed + 1)); echo "ok   $1"; }
fail() { failed=$((failed + 1)); echo "FAIL $1"; [ -n "${2:-}" ] && echo "$2" | sed 's/^/     /'; }

# expect <name> <expected exit: 0|fail> <substring or ""> <command...>
expect() {
	local name=$1 want=$2 needle=$3
	shift 3
	local out code
	out=$("$@" 2>&1)
	code=$?
	if [ "$want" = 0 ] && [ $code -ne 0 ]; then fail "$name" "exit $code: $out"; return; fi
	if [ "$want" = fail ] && [ $code -eq 0 ]; then fail "$name" "unexpected success: $out"; return; fi
	if [ -n "$needle" ] && [[ "$out" != *"$needle"* ]]; then fail "$name" "missing '$needle' in: $out"; return; fi
	pass "$name"
}

m() { (cd "$project" && "$mead" -q "$@"); }
commit_of() { git -C "$work/$1" rev-parse "$2^{commit}"; }

# Milestone 2: locked source builds
expect "install resolves and installs" 0 "" m install
expect "lockfile records the tag commit" 0 "$(commit_of geometry v1.0.0)" cat "$project/mead.lock"
expect "deps keep the full repository layout" 0 "" test -f "$project/deps/geometry_pkg/src/geometry/geometry.odin"
expect "bare imports build from root and nested packages" 0 "Vec2{x = 4, y = 6} Vec2{x = 1, y = 1} green 1.0.0 hello from an asset" m run app
expect "original source keeps bare imports" 0 'import geo "geometry_pkg"' cat "$project/src/main.odin"
expect "installed source is unchanged" 0 "" git -C "$work/geometry" diff --quiet
expect "gitignore-free project still builds with run args" 0 "" m build app

before=$(commit_of colors main)
echo "// moved" >> "$work/colors/colors.odin"
git -C "$work/colors" commit -qam "move main"
expect "a moved branch keeps the locked commit" 0 "$before" cat "$project/mead.lock"
expect "install after a moved branch is a no-op" 0 "" m install
expect "lock still names the old branch commit" 0 "$before" cat "$project/mead.lock"
expect "update moves the branch selection" 0 "" m update colors
expect "lock names the new branch commit" 0 "$(commit_of colors main)" cat "$project/mead.lock"

old_tag=$(commit_of geometry v1.0.0)
git -C "$work/geometry" tag -fa v1.0.0 -m moved "$(commit_of geometry v1.1.0)" >/dev/null
rm -rf "$project/deps/geometry_pkg"
expect "a moved tag cannot alter a locked install" 0 "" m install
expect "reinstalled the locked tag commit" 0 "1.0.0" m run app
expect "lock keeps the original tag commit" 0 "$old_tag" cat "$project/mead.lock"

expect "offline install uses the cache" 0 "" m install --offline
expect "locked install accepts an unchanged manifest" 0 "" m install --locked

cp "$project/meade.kdl" "$work/manifest.bak"
sed -i 's/tag="v1.0.0"/tag="v1.1.0"/' "$project/meade.kdl"
expect "locked install rejects a changed manifest" fail "changed since mead.lock" m install --locked
expect "install stops when the manifest disagrees with the lock" fail "mead update geometry_pkg" m install
expect "update adopts the new selection" 0 "" m update geometry_pkg
expect "build uses the updated dependency" 0 "1.1.0" m run app
cp "$work/manifest.bak" "$project/meade.kdl"
m update geometry_pkg >/dev/null 2>&1

# Bare-import adapter edge cases
mkdir -p "$project/src/colors"
echo "package colors" > "$project/src/colors/local.odin"
expect "a local package with a dependency name is ambiguous" fail "ambiguous" m build app
rm -rf "$project/src/colors"

cp "$project/src/shapes/shapes.odin" "$work/shapes.bak"
printf 'package shapes\n\nimport g "geometry_pkg"; BAD :: g.missing\n\nunit :: proc() -> g.Vec2 {\n\treturn {1, 1}\n}\n' > "$project/src/shapes/shapes.odin"
expect "diagnostics point at the original file" fail "$project/src/shapes/shapes.odin(3:" m build app
out=$(m build app 2>&1)
expect "diagnostic columns map past the rewritten import" 0 "" grep -q "shapes.odin(3:3[0-9])" <<<"$out"
expect "diagnostics never show the generated copy" 0 "" bash -c "! grep -q '.mead/build' <<<'$out'"
cp "$work/shapes.bak" "$project/src/shapes/shapes.odin"

# Milestone 3: source-built tools
expect "exec runs the locked tool" 0 "assetgen 0.1.0 args=[\"x\"]" m exec assetgen -- x
sed -i 's/tag="v0.1.0" distribution/tag="v0.2.0" distribution/' "$project/meade.kdl"
expect "update builds the new tool revision" 0 "" m update assetgen
expect "exec runs the updated tool" 0 "assetgen 0.2.0" m exec assetgen

mkdir -p "$work/project2/src"
sed -e 's/tag="v0.2.0" distribution/tag="v0.1.0" distribution/' -e 's/tag="v0.1.0" distribution/tag="v0.1.0" distribution/' "$project/meade.kdl" > "$work/project2/meade.kdl"
sed -i 's/tag="v0.2.0" distribution/tag="v0.1.0" distribution/' "$work/project2/meade.kdl"
cp -r "$project/src" "$project/assets" "$work/project2/"
expect "a second project installs another tool revision" 0 "reusing cached build" bash -c "cd '$work/project2' && '$mead' install"
expect "the second project runs its own revision" 0 "assetgen 0.1.0" bash -c "cd '$work/project2' && '$mead' exec assetgen"
expect "the first project keeps its revision" 0 "assetgen 0.2.0" m exec assetgen

printf 'package main\nmain :: proc() { this is not odin }\n' > "$work/assetgen/cmd/assetgen/main.odin"
git -C "$work/assetgen" commit -qam broken
git -C "$work/assetgen" tag v0.3.0
cp "$project/mead.lock" "$work/lock.bak"
sed -i 's/tag="v0.2.0" distribution/tag="v0.3.0" distribution/' "$project/meade.kdl"
expect "a failed tool build reports the failure" fail "previously installed tool is unchanged" m update assetgen
expect "a failed tool build preserves the installed tool" 0 "assetgen 0.2.0" bash -c "cd '$project' && '$mead' exec assetgen 2>&1; true"
expect "a failed tool build preserves the lockfile" 0 "" cmp "$project/mead.lock" "$work/lock.bak"
sed -i 's/tag="v0.3.0" distribution/tag="v0.2.0" distribution/' "$project/meade.kdl"

odin_path=$(command -v "${MEAD_ODIN:-odin}")
printf '#!/bin/sh\n# a different compiler build\nexec "%s" "$@"\n' "$odin_path" > "$work/odin-wrapper"
chmod +x "$work/odin-wrapper"
expect "a compiler change invalidates the artifact key" 0 "building tool assetgen" bash -c "cd '$project' && rm -rf deps/.tools && MEAD_ODIN='$work/odin-wrapper' '$mead' install"

# Manifest editing
expect "add records a dependency and keeps comments" 0 "" m add "file://$work/geometry" --as geometry2 --tag v1.1.0
expect "add inserted the declaration" 0 'dependency "geometry2"' cat "$project/meade.kdl"
expect "add preserved comments" 0 "// no author manifest" cat "$project/meade.kdl"
expect "add rejects a missing tag" fail "does not exist" m add "file://$work/geometry" --as geometry3 --tag v9.9.9
expect "install resolves the added dependency" 0 "" m install
expect "removing a declaration removes its installation" 0 "" bash -c "cd '$project' && sed -i '/geometry2/d' meade.kdl && '$mead' -q install && test ! -e deps/geometry2"

# Transitive dependency reporting
mkdir -p "$work/widgets/src"
git -C "$work" init -q -b main widgets
printf 'schema 1\npackage "widgets" path="src"\ndependencies {\n    dependency "colors" git="file://%s/colors" branch="main"\n    dependency "fonts" git="file://%s/fonts" tag="v1"\n}\n' "$work" "$work" > "$work/widgets/meade.kdl"
printf 'package widgets\n\nimport "colors"\n\nfavorite :: proc() -> string { return colors.name(.Blue) }\n' > "$work/widgets/src/widgets.odin"
git -C "$work/widgets" -c user.email=t@e.invalid -c user.name=t add -A
git -C "$work/widgets" -c user.email=t@e.invalid -c user.name=t -c commit.gpgsign=false commit -qm widgets
cp "$project/meade.kdl" "$work/manifest.bak"
sed -i "/^dependencies {/a\\    dependency \"widgets\" git=\"file://$work/widgets\" branch=\"main\"" "$project/meade.kdl"
expect "undeclared transitive dependencies are reported" fail 'dependency "fonts"' m install
sed -i 's|    dependency "fonts".*||' "$work/widgets/meade.kdl"
git -C "$work/widgets" -c user.email=t@e.invalid -c user.name=t -c commit.gpgsign=false commit -qam "drop fonts"
expect "consumer-declared transitive names resolve in the author's scope" 0 "" m install
printf 'package main\n\nimport "core:fmt"\nimport "widgets"\n\nmain :: proc() { fmt.println(widgets.favorite()) }\n' > "$work/main_widgets.odin"
cp "$project/src/main.odin" "$work/main.bak"
cp "$work/main_widgets.odin" "$project/src/main.odin"
expect "a dependency's own bare imports resolve" 0 "blue" m run app
cp "$work/main.bak" "$project/src/main.odin"
cp "$work/manifest.bak" "$project/meade.kdl"

# Manifest validation
mkdir -p "$work/bad"
check_manifest() {
	printf '%b' "$2" > "$work/bad/meade.kdl"
	expect "$1" fail "$3" bash -c "cd '$work/bad' && '$mead' tree"
}
check_manifest "rejects duplicate properties" 'schema 1\ndependencies {\n    dependency "a" git="https://x.invalid/a.git" tag="1" tag="2"\n}\n' 'duplicate property "tag"'
check_manifest "rejects multiple selectors" 'schema 1\ndependencies {\n    dependency "a" git="https://x.invalid/a.git" tag="1" branch="main"\n}\n' "choose exactly one"
check_manifest "rejects a missing selector" 'schema 1\ndependencies {\n    dependency "a" git="https://x.invalid/a.git"\n}\n' "needs one revision selector"
check_manifest "rejects unknown nodes" 'schema 1\nscripts {\n}\n' 'unknown node "scripts"'
check_manifest "rejects unknown properties" 'schema 1\npackage "p" license="MIT"\n' 'unknown property "license"'
check_manifest "rejects unsupported schemas" 'schema 2\n' "unsupported schema version 2"
check_manifest "rejects duplicate names" 'schema 1\ndependencies {\n    dependency "a" git="https://x.invalid/a.git" tag="1"\n    dependency "a" git="https://x.invalid/b.git" tag="1"\n}\n' 'duplicate dependency "a"'
check_manifest "rejects case collisions" 'schema 1\ndependencies {\n    dependency "abc" git="https://x.invalid/a.git" tag="1"\n    dependency "ABC" git="https://x.invalid/b.git" tag="1"\n}\n' "case-insensitive"
check_manifest "rejects path names" 'schema 1\ndependencies {\n    dependency "shared:foo" git="https://x.invalid/a.git" tag="1"\n}\n' "Odin identifier"
check_manifest "rejects escaping paths" 'schema 1\ndependencies {\n    dependency "a" git="https://x.invalid/a.git" tag="1" path="../x"\n}\n' "leaves the repository"
check_manifest "rejects credentials" 'schema 1\ndependencies {\n    dependency "a" git="https://user:pw@x.invalid/a.git" tag="1"\n}\n' "credentials"
check_manifest "rejects unsupported schemes" 'schema 1\ndependencies {\n    dependency "a" git="ftp://x.invalid/a.git" tag="1"\n}\n' "unsupported origin scheme"
check_manifest "rejects invalid target kinds" 'schema 1\ntargets {\n    target "a" kind="plugin" path="src"\n}\n' "invalid kind"
check_manifest "rejects owned compiler flags" 'schema 1\ntargets {\n    target "a" kind="executable" path="src" {\n        flags "-out:x"\n    }\n}\n' "mead controls"
check_manifest "rejects short revs" 'schema 1\ndependencies {\n    dependency "a" git="https://x.invalid/a.git" rev="abc123"\n}\n' "full 40- or 64-character"
check_manifest "reports KDL syntax errors with a location" 'schema 1\npackage "p" version=\n' "meade.kdl:2:"

expect "init creates a manifest" 0 "" bash -c "mkdir -p '$work/fresh/src' && cd '$work/fresh' && '$mead' -q init && grep -q 'target \"fresh\"' meade.kdl && grep -q '/deps/' .gitignore"

echo
echo "$passed passed, $failed failed"
[ $failed -eq 0 ]
