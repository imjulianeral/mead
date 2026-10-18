# Mead research

Mead can combine direct Git dependencies, explicit version selection, and clean project repositories.
The selected manifest format is KDL v2, with the exact filename `meade.kdl`.
Dependencies install under the project's `deps/` directory.
Developer source imports each dependency through its bare manifest name.
Compiled libraries require an explicit binary interface and Odin bindings.

These recommendations describe a design, not implemented behavior.
Research date: September 30, 2026.

## Direct author distribution

Pkgit's current documentation describes builds and installations directly from Git repositories.
It supports repository URLs, tag selections, and author-provided build descriptions.
Its former GitHub repository points to a new home on symlinx.net.
[Current pkgit documentation](https://git.symlinx.net/pkgit/about/), [former repository](https://github.com/dacctal/pkgit).

For mead, the useful principle is that the author controls the source and package metadata.
The consumer controls the repository URL and revision selection.
A mead registry must not become a requirement for either side.
GitHub remains a supported host, alongside other Git hosts and private repositories.

The proposed author contract is a `meade.kdl` file inside the repository.
Existing source libraries can also work without this file.
The consumer supplies the source package path and any dependency information that the source requires.

## Manifest formats

The table combines documented format features with an assessment of their fit for mead.
The assessment column records the selected format and the alternatives.

| Format | Relevant properties | Assessment for mead |
| --- | --- | --- |
| KDL v2 | Nodes combine arguments, properties, and child nodes. An Odin tokenizer, parser, and emitter exists. | Selected for `meade.kdl`. Each dependency has a name and explicit source properties. |
| TOML | Comments, named tables, arrays, and explicit scalar types. The current specification is 1.1.0. | A viable alternative. The project uses KDL for its manifest. |
| JSON | Odin includes `core:encoding/json`. JSON has broad tooling, but standard JSON has no comments. | Retained for the generated lockfile. |
| YAML | The specification includes indentation, tags, aliases, and multiple scalar styles. | Avoid for the first implementation. Its additional syntax gives this manifest little benefit. |
| CUE | Types, values, constraints, and data validation share one language. | Useful for complex configuration systems. Its evaluator exceeds the needs of this manifest. |
| Pkl | Programmable configuration with types and validation. | Better suited to configuration generation than mead's direct manifest reader. |
| Dhall | Typed, programmable configuration with imports. | Useful for reusable configuration. Evaluation and imports add a separate language layer. |

Sources: [TOML 1.1](https://toml.io/en/v1.1.0), [Odin JSON](https://pkg.odin-lang.org/core/encoding/json/),
[JSON specification](https://www.rfc-editor.org/rfc/rfc8259), [KDL v2 specification](https://kdl.dev/spec/),
[YAML specification](https://yaml.org/spec/1.2.2/), [CUE introduction](https://cuelang.org/docs/introduction/),
[Pkl introduction](https://pkl-lang.org/main/current/introduction/index.html), [Dhall](https://dhall-lang.org/).

KDL supplies a readable data format without a configuration evaluator.
Its dependency nodes can name direct Git origins, revisions, and package paths.
The format does not supply package identity, version resolution, or reproducibility automatically.
Mead must define those rules in its own schema.

The proposed reader targets KDL 2.0.0.
Mead documents that format version separately from its own `schema 1` declaration.
[KDL v2 specification](https://kdl.dev/spec/).

### Odin parser availability

Odin's current `core/encoding` directory includes JSON but no TOML or KDL parser.
[Core encoding source](https://github.com/odin-lang/Odin/tree/master/core/encoding).

`odin-engine/ode_kdl` offers an Odin implementation of KDL v2.
Its README reports validation against 319 upstream conformance cases.
This research did not independently run those tests.
It is the candidate parser for mead, subject to a compiler and conformance audit.
[KDL implementation](https://github.com/odin-engine/ode_kdl).

The implementation gate is a conformance audit with malformed manifests and duplicate selectors.
Mead also needs schema validation after parsing.
KDL permits repeated properties with the last value taking precedence.
Mead's stricter schema rejects repeated properties and dependency names to keep selections unambiguous.
Its reader must inspect original property events before any normalization that discards duplicates.
[KDL property rules](https://kdl.dev/spec/).

## Bare imports and the deps directory

The requested developer syntax is:

```odin
import example "example_pkg"
```

`example` is the local Odin identifier.
`example_pkg` is the dependency name in `meade.kdl`.
Mead installs its full repository under `deps/example_pkg/`.
The manifest's `path` selects the package directory inside that repository.

Stock Odin resolves an import without a collection prefix relative to the source file's directory.
Its collection mechanism uses an explicit prefix such as `shared:`.
The inspected compiler exposes no bare-import dependency search path.
Changing the working directory does not change the source file's import base directory.
[Import resolution source](https://github.com/odin-lang/Odin/blob/be869ce072704649eb64c139dfb74977c2bab857/src/parser.cpp#L6786),
[compiler collections](https://github.com/odin-lang/Odin/wiki/Compiler-Flags).

The proposed adapter builds a temporary copy under `.mead/build/`.
It replaces declared dependency import literals with relative package paths only in that copy.
Developer source and installed source remain unchanged.
The adapter uses Odin's parser or tokenizer to identify imports accurately.
It preserves local imports, asset paths, aliases, and unrelated string literals.
[Odin tooling parser](https://pkg.odin-lang.org/core/odin/parser/).

This approach is a design inference from the compiler's path rules, not a verified compiler feature.
An Odin experiment must establish package identity, asset handling, conditional imports, and diagnostic mapping before implementation claims.
Plain `odin build` on the original source does not gain mead's name resolution.
Editor integration also needs a mead-aware import resolver or a synchronized build view.
An `ols.json` collection entry alone cannot support the requested bare syntax.

Directory links beside each importing package are another possible adapter.
They introduce extra paths in source directories and need platform-specific identity validation.
The selected design uses the temporary build copy.

## GitHub releases and Git revisions

A GitHub release contains publication metadata and can contain downloadable assets.
A Git tag can exist without a GitHub release.
Mead must expose these as distinct selections.
[Release API](https://docs.github.com/en/rest/releases/releases).

The proposed discovery command combines these sources:

| Selection | Discovery source | Locked identity |
| --- | --- | --- |
| GitHub release | `GET /repos/{owner}/{repo}/releases` | Release ID, tag, resolved commit, and any selected asset digest |
| Git tag | `git ls-remote --tags` | Fully qualified tag ref and resolved commit |
| Git branch | `git ls-remote` branch refs | Fully qualified branch ref and current commit |
| Commit | Git fetch and object inspection | Exact commit ID and Git object format |
| Semantic version | Parsed version tags or release tags | Selected candidate and exact commit |

Git returns remote refs and object IDs without a full checkout.
Annotated tags can include a peeled object ID.
Mead must resolve the selected object to a commit before it accepts a source dependency.
[Git remote references](https://git-scm.com/docs/git-ls-remote).

GitHub also provides [tag endpoints](https://docs.github.com/en/rest/repos/repos#list-repository-tags)
and [branch endpoints](https://docs.github.com/en/rest/branches/branches).
Generic Git discovery keeps those choices available on other hosts.

Semantic version ordering uses numeric components and prerelease rules.
An arbitrary tag remains selectable even if it does not follow SemVer.
Version ranges are a separate mead policy. SemVer does not specify a range language.
[Semantic Versioning specification](https://semver.org/).

Mead must list all release pages and keep prereleases visible with clear labels.
GitHub's `latest` designation is not a substitute for a developer's selection or a SemVer comparison.
The API supports an author-controlled `make_latest` field.
[Release API](https://docs.github.com/en/rest/releases/releases),
[pagination](https://docs.github.com/en/rest/using-the-rest-api/using-pagination-in-the-rest-api).

GitHub generally permits 60 unauthenticated REST requests per hour per originating IP.
Authenticated requests generally receive 5,000 requests per hour.
The proposed client caches discovery responses and accepts a token through the environment.
Public source installations must remain possible without a token.
[GitHub rate limits](https://docs.github.com/en/rest/using-the-rest-api/rate-limits-for-the-rest-api).

## What binary installation can mean in Odin

Odin packages are directories of source files.
Collections map import prefixes to paths.
Mead's bare-name adapter must respect this source model.
[Odin package overview](https://odin-lang.org/docs/overview/).

| Package kind | Can mead install a binary? | What the project still needs |
| --- | --- | --- |
| Command-line tool | Yes. Build an executable or select an author's release asset. | The executable and any runtime libraries or data files it requires. |
| Ordinary Odin library | A binary cannot replace its source import automatically. | Installed source and mead's import resolver. Compile-time declarations and polymorphic procedures require source. |
| Library with an explicit binary interface | Yes. Build or download a static or shared library. | Odin bindings, matching types and calling conventions, and required runtime support. |

This distinction is an inference from Odin's import, polymorphism, export, and foreign-library mechanisms.
It is the central constraint on mead's binary model.
[Language overview](https://odin-lang.org/docs/overview/), [foreign-library documentation](https://odin-lang.org/news/binding-to-c/).

The compiler documents executable, static-library, shared-library, and object build modes.
Its current linker source includes static archive creation with `ar` on the Unix path and `lib.exe` on the Windows path.
Older claims that static-library builds only work on Windows do not describe this current source.
This research inspected the source but did not compile a test package.
[Compiler flags](https://github.com/odin-lang/Odin/wiki/Compiler-Flags),
[linker source snapshot](https://github.com/odin-lang/Odin/blob/be869ce072704649eb64c139dfb74977c2bab857/src/linker.cpp).

For a tool, the build can resemble:

```sh
odin build ./cmd/assetgen -out:./dist/assetgen -o:speed
```

For a library that already exports an appropriate interface, the build can resemble:

```sh
odin build ./abi -build-mode:static -no-entry-point -out:./dist/geometry.a
```

These commands illustrate Odin build modes. The example paths do not exist in this repository.
Platform-specific filenames and compiler support require validation on the target platform.

An author can expose functions with `@(export)` and a C-compatible calling convention.
The consumer declares them through `foreign import` and a `foreign` block.
An executable does not serve as an imported library.
Mead must not promise automatic bindings for arbitrary Odin packages.
[Exports and calling conventions](https://odin-lang.org/docs/overview/),
[foreign-library documentation](https://odin-lang.org/news/binding-to-c/).

Prebuilt assets also require an explicit target match.
Operating system and CPU architecture alone can be insufficient.
The design must account for runtime libraries, libc requirements, CPU features, and the package's ABI.
An asset name alone cannot establish compatibility.

GitHub exposes asset IDs, download URLs, and a digest field in release-asset metadata.
Mead records a SHA-256 digest for every downloaded asset and verifies it on later installations.
A digest pins bytes. It does not independently prove authorship.
[Release assets API](https://docs.github.com/en/rest/releases/assets).

## Recommended first implementation

The first implementation can use an Odin CLI with Git as a subprocess and HTTPS through libcurl bindings.
This keeps mead's own application code in Odin without a new Git or TLS implementation.
[Odin process source](https://github.com/odin-lang/Odin/blob/master/core/os/process.odin),
[Odin curl bindings](https://pkg.odin-lang.org/vendor/curl/).

Mead first needs KDL manifests, exact selections, a lockfile, local installations under `deps/`, and the bare-import adapter.
Source-built tools are the next useful binary feature.
Release assets and compiled libraries follow after the project defines their target and binding contracts.

An ignored `deps/` directory keeps dependency sources out of committed project history.
An optional shared fetch cache can reduce repeated downloads across projects.
Neither feature eliminates source storage on the developer's machine or all dependency compilation.

Odin's FAQ states that the language does not officially support a package manager.
Mead therefore remains an independent tool built around existing compiler features.
[Odin FAQ](https://odin-lang.org/docs/faq/).
