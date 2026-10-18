#!/usr/bin/env bash
# Creates local author repositories and a consumer project for mead's end-to-end tests.
# Usage: fixtures.sh <directory>
set -euo pipefail

root=$1
mkdir -p "$root"
cd "$root"

git_init() {
	git init -q -b main "$1"
	git -C "$1" config user.email test@example.invalid
	git -C "$1" config user.name "mead test"
	git -C "$1" config commit.gpgsign false
	git -C "$1" config tag.gpgsign false
}

commit() {
	git -C "$1" add -A
	git -C "$1" commit -q -m "$2"
}

# A library with an author manifest and a nested source package.
git_init geometry
mkdir -p geometry/src/geometry
cat > geometry/meade.kdl <<'KDL'
// Author manifest for the test geometry library.
schema 1
package "geometry" version="1.0.0" path="src/geometry"
KDL
cat > geometry/src/geometry/geometry.odin <<'ODIN'
package geometry

Vec2 :: struct {
	x, y: f32,
}

add :: proc(a, b: Vec2) -> Vec2 {
	return {a.x + b.x, a.y + b.y}
}

VERSION :: "1.0.0"
ODIN
commit geometry "geometry 1.0.0"
git -C geometry tag -a v1.0.0 -m "v1.0.0"
sed -i 's/VERSION :: "1.0.0"/VERSION :: "1.1.0"/' geometry/src/geometry/geometry.odin
commit geometry "geometry 1.1.0"
git -C geometry tag -a v1.1.0 -m "v1.1.0"
git -C geometry tag v2.0.0-beta.1

# A library without an author manifest. Its package is the repository root.
git_init colors
cat > colors/colors.odin <<'ODIN'
package colors

Color :: enum { Red, Green, Blue }

name :: proc(c: Color) -> string {
	switch c {
	case .Red:   return "red"
	case .Green: return "green"
	case .Blue:  return "blue"
	}
	return "?"
}
ODIN
commit colors "colors"
git -C colors tag first

# A tool with an executable target.
git_init assetgen
mkdir -p assetgen/cmd/assetgen
cat > assetgen/meade.kdl <<'KDL'
schema 1
package "assetgen" version="0.1.0"
targets {
    target "assetgen" kind="executable" path="cmd/assetgen" {
        flags "-o:minimal"
    }
}
KDL
cat > assetgen/cmd/assetgen/main.odin <<'ODIN'
package main

import "core:fmt"
import "core:os"

main :: proc() {
	fmt.printfln("assetgen 0.1.0 args=%v", os.args[1:])
}
ODIN
commit assetgen "assetgen 0.1.0"
git -C assetgen tag v0.1.0
sed -i 's/assetgen 0.1.0 args/assetgen 0.2.0 args/' assetgen/cmd/assetgen/main.odin
commit assetgen "assetgen 0.2.0"
git -C assetgen tag v0.2.0

# The consumer project.
mkdir -p project/src/shapes project/assets
cat > project/meade.kdl <<KDL
// Consumer project used by the end-to-end tests.
schema 1

package "orchard" version="0.1.0"

dependencies {
    dependency "geometry_pkg" git="file://$root/geometry" tag="v1.0.0"
    dependency "colors" git="file://$root/colors" branch="main" // no author manifest
}

tools {
    tool "assetgen" git="file://$root/assetgen" tag="v0.1.0" distribution="build" target="assetgen"
}

targets {
    target "app" kind="executable" path="src" {
        flags "-o:minimal"
    }
}
KDL
cat > project/assets/greeting.txt <<'TXT'
hello from an asset
TXT
cat > project/src/main.odin <<'ODIN'
package main

import "core:fmt"
import geo "geometry_pkg"
import "colors"
import "shapes"

GREETING :: #load("../assets/greeting.txt", string)

main :: proc() {
	v := geo.add({1, 2}, {3, 4})
	// shapes returns a geometry type, so both packages must share one package identity.
	w: geo.Vec2 = shapes.unit()
	fmt.printfln("%v %v %s %s %s", v, w, colors.name(.Green), geo.VERSION, GREETING[:len(GREETING)-1])
}
ODIN
cat > project/src/shapes/shapes.odin <<'ODIN'
package shapes

import g "geometry_pkg"

unit :: proc() -> g.Vec2 {
	return {1, 1}
}
ODIN
