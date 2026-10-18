# Mead manifest examples

These files illustrate the proposed mead schema.
They use KDL v2. Mead 0.1.0 validates them, for example with `mead tree`.
The author repositories, version selections, target names, and source layouts are fictitious.

[Consumer project](project/meade.kdl) selects a release, a tag, a branch, and a commit.
It also declares a source-built project tool.
The `example_pkg` dependency uses the [library author's manifest](library/meade.kdl).
The `assetgen` tool uses the [tool author's manifest](tool/meade.kdl).

The geometry repository has this illustrative layout:

```text
geometry/
  meade.kdl
  src/
    geometry/
      geometry.odin
```

The consumer installs this repository under `deps/example_pkg/`.
Its `path="src/geometry"` selects the source package.
Developer source uses:

```odin
import example "example_pkg"
```

Mead resolves the name in a generated build copy.
The developer's import string contains only the dependency name.
Plain Odin does not automatically search `deps/` for this name.
The compiler and editor integration requirements appear in [the design](../docs/design.md#bare-dependency-imports).
An ordinary source library does not need a compiled-library target.

The assetgen repository has this illustrative layout:

```text
assetgen/
  meade.kdl
  cmd/
    assetgen/
      main.odin
```

Mead reads the author's `assetgen` target and builds an executable.
The consumer receives that executable under `deps/.tools/assetgen/bin/`.
These examples do not select prebuilt release assets or compiled libraries.
Those features need the later contracts in [the design](../docs/design.md).
