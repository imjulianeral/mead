# mead

Mead is a package manager for Odin, written in Odin.
Developers select packages directly from their authors' Git repositories.
An installation requires no mead registry, repackaging service, or registry account.

**Status: mead 0.1.0 implements design milestones 1–3 on Linux.**
It reads manifests, discovers versions, locks exact commits, installs sources under `deps/`, builds projects with bare dependency imports, and builds project tools from source.
Recursive dependency graphs, release-asset tools, version ranges, compiled libraries, and editor integration are not implemented yet.
[Implementation status](docs/implementation.md) lists what exists and what the compiler experiments found.

The design uses:

- `meade.kdl` for the project manifest, with KDL v2 syntax.
- `mead.lock` for exact commits and artifact digests, encoded as JSON.
- `deps/` for installed dependency sources, tools, and binary artifacts.
- Bare dependency names in developer source.
- A generated build copy to resolve these names with the stock Odin compiler.
- Explicit bindings for packages that offer compiled libraries.

Developer source uses:

```odin
import example "example_pkg"
```

The dependency name comes from the manifest.
`mead build` resolves it to the installed package under `deps/`.
Odin itself resolves bare imports relative to their source files, so plain `odin build` requires separate integration.

Compilation does not make every Odin library suitable for distribution as a binary.
Ordinary packages still need their source for imports and compile-time features.
The project's `.gitignore` excludes `deps/` and `.mead/` from committed source.

## Installing

```sh
curl -fsSL https://github.com/OWNER/mead/releases/latest/download/install.sh | sh
mead upgrade    # later: replace mead with the latest release
```

The script installs a checksum-verified binary for Linux (x86-64 or ARM64) to `~/.mead/bin`.
`MEAD_INSTALL` changes that location, and `sh -s -- 0.2.0` installs a particular version.
Mead prints a notice at most once a day when a newer release exists; `MEAD_NO_UPDATE_CHECK=1` turns it off.
Pushing a `v*` tag publishes a release through `.github/workflows/release.yml`.

## Building

Mead needs the Odin compiler, Git, and libcurl.

```sh
make            # builds build/mead
make test       # unit tests, the KDL conformance suite, and end-to-end tests
```

`make conformance` clones the upstream KDL test suite into `build/` on first use.

## Usage

```sh
mead init
mead versions https://github.com/example-author/geometry.git
mead add https://github.com/example-author/geometry.git --as example_pkg --release v1.2.3 --path src/geometry
mead add https://github.com/example-author/assetgen.git --tool --as assetgen --tag v0.4.0
mead install
mead run app -- --some-flag
mead exec assetgen -- input/
mead update example_pkg
```

| Command | Result |
| --- | --- |
| `mead init [name]` | Create a minimal `meade.kdl` and add `deps/` and `.mead/` to `.gitignore`. |
| `mead versions <git-url>` | List GitHub releases, version tags, other tags, and branches. |
| `mead add <git-url> --as <name> --tag <tag>` | Check and record a selection. `--branch`, `--rev`, and `--release` are alternatives. `--tool` records a tool. |
| `mead install [--locked] [--offline]` | Install locked selections and resolve new ones. |
| `mead update [name...]` | Resolve selections again and report the old and new commits. |
| `mead build [target]` | Compile a target in a generated copy with resolved imports. |
| `mead run [target] -- <args>` | Build and run an executable target. |
| `mead exec <tool> -- <args>` | Run the project's installed tool. |
| `mead tree` | Show dependency origins and locked revisions. |
| `mead env` | Show dependency bindings, installed paths, and tool locations. |
| `mead upgrade [--check] [--version V]` | Replace mead with the latest release, or a chosen one, after verifying it. |

`MEAD_CACHE_DIR` sets the shared cache, which defaults to `$XDG_CACHE_HOME/mead`.
`MEAD_ODIN` selects the compiler.
`GITHUB_TOKEN` or `GH_TOKEN` raises the GitHub API rate limit and never enters manifests, locks, or logs.

## Documents

[Research](docs/research.md) compares manifest formats and explains Odin's binary options with primary sources.
[Design](docs/design.md) defines selections, cache behavior, commands, and implementation milestones.
[Implementation status](docs/implementation.md) records the built subset, compiler findings, and differences from the design.
[Manifest examples](examples/README.md) show a consumer project and two author manifests.

Research date: September 30, 2026.
