/*
mead: a package manager for Odin that installs dependencies directly from their
authors' Git repositories. See docs/design.md.
*/
package mead

import "core:fmt"
import "core:os"

// Release builds stamp the version from the Git tag with -define:MEAD_VERSION=<version>.
MEAD_VERSION :: #config(MEAD_VERSION, "0.1.0")

USAGE :: `mead - direct-from-Git packages for Odin

Usage: mead [-v | -q] <command> [arguments]

Commands:
  init [name]                     Create a minimal meade.kdl
  versions <git-url>              List releases, tags, and branches of an origin
  add <git-url> --as <name> (--tag T | --branch B | --rev C | --release T) [--path P]
                                  Record a dependency selection
  add <git-url> --tool --as <name> (--tag T | ...) [--target T]
                                  Record a source-built project tool
  install [--locked] [--offline]  Install locked or newly resolved selections under deps/
  update [name...]                Resolve selections again and update mead.lock
  build [target]                  Build a target with dependency names resolved
  run [target] [-- args...]       Build and run an executable target
  exec <tool> [-- args...]        Run an installed project tool
  tree                            Show dependency origins and locked revisions
  env                             Show dependency bindings and tool locations
  upgrade [--check] [--version V] [--force]
                                  Update mead itself to the latest release

Options:
  -v, --verbose   Show subprocess commands
  -q, --quiet     Show only errors
  -h, --help      Show this help
  --version       Show the mead version

Environment:
  MEAD_CACHE_DIR  Shared fetch and artifact cache (default: $XDG_CACHE_HOME/mead)
  MEAD_ODIN       Odin compiler to use (default: odin on PATH)
  GITHUB_TOKEN    Optional token for GitHub release discovery
  MEAD_NO_UPDATE_CHECK  Set to skip the daily new-version notice
`

main :: proc() {
	args := os.args[1:]
	for len(args) > 0 {
		switch args[0] {
		case "-v", "--verbose":
			g_verbose = true
		case "-q", "--quiet":
			g_quiet = true
		case "-h", "--help", "help":
			fmt.print(USAGE)
			return
		case "--version":
			fmt.printfln("mead %s", MEAD_VERSION)
			return
		case:
			if len(args[0]) > 0 && args[0][0] == '-' {
				die("unknown option %q (see `mead --help`)", args[0])
			}
			maybe_notify_update(args[0])
			dispatch(args[0], args[1:])
			return
		}
		args = args[1:]
	}
	fmt.print(USAGE)
	os.exit(2)
}

dispatch :: proc(command: string, args: []string) {
	switch command {
	case "init":     cmd_init(args)
	case "versions": cmd_versions(args)
	case "add":      cmd_add(args)
	case "install":  cmd_install(args)
	case "update":   cmd_update(args)
	case "build":    cmd_build(args, false)
	case "run":      cmd_build(args, true)
	case "exec":     cmd_exec(args)
	case "tree":     cmd_tree(args)
	case "env":      cmd_env(args)
	case "upgrade":  cmd_upgrade(args)
	case:
		die("unknown command %q (see `mead --help`)", command)
	}
}
