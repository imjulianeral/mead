# Mead implementation status

Mead 0.1.0 implements design milestones 1 through 3 on Linux.
It is written in Odin and builds with the stock compiler (tested with `dev-2026-09`).
The [design](design.md) remains the reference for proposed behavior.
This document records what exists, what the first experiments found, and where the implementation differs from the design.

## Implemented

| Milestone | Status | Evidence |
| --- | --- | --- |
| 1. Manifest and discovery | Done | A KDL 2.0.0 reader passes all 338 upstream test cases. Schema validation rejects duplicate properties and selectors. `mead versions` lists GitHub releases across pages, version tags in SemVer order, other tags, branches, and prereleases. |
| 2. Locked source builds | Done | Bare imports build from root and nested packages. Shared types keep one package identity. `#load` assets work. Original and installed sources remain unchanged. A moved branch or tag keeps the locked commit. |
| 3. Source-built tools | Done | Two projects use different tool revisions. A failed build preserves the installed tool and the lockfile. A different compiler binary changes the artifact key. |
| 4. Dependency graphs | Not started | Author-declared dependencies are reported, not ignored. See below. |
| 5. Release assets and ranges | Not started | `distribution="asset"` is rejected with an explanation. SemVer ordering exists for discovery output. |
| 6. Compiled libraries | Not started | Project targets can use the `static-library` and `shared-library` kinds. Binding contracts do not exist. |
| Editor integration | Not started | Plain OLS cannot resolve bare names. |

`make test` runs the unit tests, the KDL conformance suite, `tests/e2e.sh`, and `tests/release.sh`.
The end-to-end script creates local author repositories and checks 61 acceptance cases.
The release script serves fake GitHub releases from a local server and checks `mead upgrade`, the daily update notice, and `scripts/install.sh` in 35 cases.

Distribution is outside the design milestones.
Pushing a `v*` tag runs `.github/workflows/release.yml`, which publishes Linux amd64 and arm64 binaries, a rendered `install.sh`, and one `SHA256SUMS` as a GitHub release.
`mead upgrade` and `install.sh` verify every download against `SHA256SUMS` and run the new binary before they replace anything.

## Source layout

| Path | Contents |
| --- | --- |
| `kdl/` | The KDL 2.0.0 parser. It keeps every property event in source order, plus byte offsets for manifest edits. |
| `src/manifest.odin` | The `schema 1` reader, validation rules, declaration hash, and comment-preserving insertion. |
| `src/lockfile.odin` | `mead.lock` and `.mead/state.json`. |
| `src/git.odin` | `git ls-remote`, the shared bare-repository cache, and commit export. |
| `src/http.odin` | A minimal libcurl binding and the GitHub releases client. |
| `src/install.odin` | Resolution, staging, tool builds, and atomic publication. |
| `src/adapter.odin` | The build copy, import rewriting, and diagnostic mapping. |
| `src/build.odin` | Toolchain discovery and fingerprints, and `build`/`run`. |
| `src/commands.odin` | `init`, `add`, `versions`, `update`, `exec`, `tree`, and `env`. |
| `src/upgrade.odin` | `upgrade` and the daily update notice. |
| `scripts/install.sh` | The install script. `make dist` fills in the release repository. |

## Compiler adapter findings

The design required an Odin experiment before support claims.
These results come from `dev-2026-09`.

- **Unaliased imports take the last path component as their name.**
  `import "widgets"` rewritten to `"../deps/widgets/src"` would bind the name `src`.
  The adapter therefore writes `import widgets "../deps/widgets/src"` when the developer gave no alias.
- **Odin rejects `import` inside `when` blocks.**
  The compiler reports "Cannot use 'import' within a 'when' statement".
  Conditional imports exist only through file suffixes and `#+build` tags.
  The adapter rewrites every `.odin` file and lets the compiler select files for the target.
- **Package identity holds.**
  Every importer of a dependency name resolves to one directory in the build copy.
  A type returned from one project package is assignable in another.
- **Relative assets work.**
  The build copy keeps the project's layout, so `#load("../assets/x.txt")` resolves.
- **Source-location constants expose generated paths.**
  `#file` and `#location()` report `.mead/build/<target>/project/...`.
  Line numbers match the original files.
  Columns differ only on lines whose import literal was rewritten.
- **Diagnostics map back to original files.**
  Mead rewrites `path(line:column)` in compiler output to the original path and shifts columns past a rewritten import.
  The quoted source line under a diagnostic still shows the generated import text.

The adapter tokenizes with `core:odin/tokenizer`.
It changes only the string literal after `import` (never after `foreign import`), and only when the value exactly equals a declared name.
A dependency name that also names a local package directory beside the importing file is an ambiguity error.

## Behavior details and differences from the design

- **Local `file://` origins are accepted** in addition to HTTPS and SSH.
  They support offline mirrors and the test suite.
- **`rev` requires a full 40- or 64-character commit ID.**
  An abbreviated ID cannot be resolved remotely or locked exactly.
- **`deps` is a reserved dependency name.**
  The build copy has a `deps/` directory at its root, so a dependency named `deps` would always be ambiguous there.
- **A tool's `target` defaults to the tool name.**
  `distribution` defaults to `build`.
- **`mead add` resolves the selection before it edits `meade.kdl`.**
  It inserts the new declaration as text, which leaves comments and formatting unchanged.
  It does not write the lockfile. The next `mead install` resolves and locks the new entry.
- **`mead install` resolves new declarations and reuses locked ones.**
  It stops when a declaration differs from its locked entry and names the `mead update` command to run.
  `--locked` additionally requires the whole declaration hash to match.
- **`mead update` without names re-resolves every selection.**
  A `rev` selection resolves to the same commit.
- **The fetch cache is shallow.**
  Mead fetches the locked commit with `--depth=1`, then falls back to the locked ref.
  A commit that the origin no longer serves fails with its full ID.
- **Submodules are not fetched.** Mead warns when a dependency has `.gitmodules`.

### Transitive dependencies

Recursive graphs are milestone 4.
Until then, mead reads each dependency's author manifest.
If it declares dependencies that the project does not declare, installation fails and prints declarations to copy.
When the project declares them, the dependency's own bare imports resolve in its author's scope to the project's installations.
A dependency without an author manifest uses the project's names, unless a local package with the same name exists beside the importing file.
Tool repositories that declare dependencies are rejected.

### Toolchain fingerprint

Tool artifact keys include a digest of the `odin` binary, every file under `base/`, `core/`, and `vendor/`, and `clang --version` (or `ODIN_CLANG_PATH`).
The digest is cached under a key made of those files' sizes and modification times.
The key also includes the target OS and architecture, origin, object format, commit, target name and path, and flags.

## Files mead writes

| Path | Committed | Contents |
| --- | --- | --- |
| `mead.lock` | Yes | JSON with the declaration hash, origins, selectors, refs, object formats, commits, release IDs, package paths, and author target definitions. |
| `deps/<name>/` | No | The complete tree of the locked commit, without `.git`. |
| `deps/.tools/<name>/source/`, `bin/` | No | Tool source and its built executable. |
| `.mead/state.json` | No | Absolute install paths and tool artifact keys. |
| `.mead/build/` | No | Generated build copies. |
| `.mead/bin/` | No | Project build outputs. |
| `$MEAD_CACHE_DIR` | No | Shallow bare repositories, GitHub responses with ETags, tool artifacts, toolchain digests, and `update-check.json`. |

Installation stages into `.mead/tmp/` and publishes with directory renames only after every fetch and build succeeds.
Shared cache entries use `flock` locks and publish through temporary directories.

## Not yet implemented

- Recursive dependency graphs, root overrides, and conflict reports (milestone 4).
- Release-asset tools, digest-verified downloads, and version ranges (milestone 5).
- Compiled-library contracts and bindings (milestone 6).
- Editor integration for bare names.
- An export command for air-gapped delivery.
- Windows and macOS support. Mead type-checks for both with `odin check`, but neither has been run or validated. On Windows, the package-path containment check does not resolve symlinks.
