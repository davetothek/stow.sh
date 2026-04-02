# AGENTS.md — stow.sh

## Project Overview

**stow.sh** is a pure-Bash reimplementation of GNU Stow — a symlink farm manager for dotfiles.
Version: `0.1.0` | License: MIT | Author: David Kristiansen

### Key features beyond GNU Stow

- **Conditional dotfiles** via `##` annotations (e.g. `file##os.linux,shell.bash`)
- **Git-aware filtering** using `.gitignore` rules (including negation patterns)
- **Triple-layer filtering**: git-aware, regex (`-i`), glob (`-I`)
- **Directory folding**: symlink whole directories when possible
- **XDG-aware folding**: fold barriers derived from `XDG_*` environment variables

## Directory Structure

```
stow.sh/
├── bin/
│   └── stow.sh              # CLI entrypoint — sets STOW_ROOT, execs src/main.sh
├── src/
│   ├── main.sh              # Orchestrator — pipeline: parse → scan → filter → fold → stow/unstow
│   ├── args.sh              # CLI argument parsing, path setup, getter functions
│   ├── log.sh               # Logging framework (color, debug levels, stderr output)
│   ├── filter.sh            # Path filtering engine (git / regex / glob)
│   ├── scan.sh              # Package directory scanner (find -type f)
│   ├── fold.sh              # Directory folding + target resolution (annotation + barrier + exclusion aware)
│   ├── stow.sh              # Stow/unstow operations (symlink creation/removal, conflict handling)
│   ├── xdg.sh               # XDG fold barrier detection from environment variables
│   ├── conditions.sh        # Annotation parsing, condition evaluation, plugin loader
│   └── version.sh           # Version constant: STOW_SH_VERSION="0.1.0"
├── conditions.d/             # Built-in condition predicates (loaded as plugins)
│   ├── docker.sh            #   docker — /.dockerenv check
│   ├── exe.sh               #   exe.<name> — executable in $PATH
│   ├── extension.sh         #   extension — always true (preserve file extensions)
│   ├── no.sh                #   no — always false (never deploy)
│   ├── os.sh                #   os.<name> — /etc/os-release match
│   ├── shell.sh             #   shell.<name> — $SHELL basename match
│   ├── wm.sh                #   wm.<name> — alias for exe
│   └── wsl.sh               #   wsl — /proc/version check
├── test/
│   ├── args.bats            # Tests for args.sh (33 tests)
│   ├── conditions.bats      # Tests for conditions, annotations, sanitization, plugins (31 tests)
│   ├── filter.bats          # Tests for filter.sh (14 tests)
│   ├── fold.bats            # Tests for fold.sh: folding, barriers, exclusions (24 tests)
│   ├── integration.bats     # End-to-end tests via bin/stow.sh (32 tests)
│   ├── scan.bats            # Tests for scan.sh (8 tests)
│   ├── stow.bats            # Tests for stow.sh: stow/unstow operations (27 tests)
│   ├── xdg.bats             # Tests for xdg.sh: XDG barrier computation (10 tests)
│   └── fixtures/
│       └── paths.bats       # Fixture: realistic dotfile path list (unused)
├── Makefile                  # install / uninstall / test targets
├── .editorconfig             # shfmt formatting rules (4-space indent)
├── .gitignore                # Ignores SHOULD_BE_IGNORED/
└── SHOULD_BE_IGNORED/        # Test artifact for git-aware filtering validation
    └── test
```

## Architecture

### Execution Flow

```
bin/stow.sh  →  sets STOW_ROOT  →  exec src/main.sh "$@"
                                          │
                  sources: version.sh, log.sh, args.sh, conditions.sh,
                           filter.sh, scan.sh, fold.sh, xdg.sh, stow.sh
                  loads condition plugins (conditions.d/*.sh + user overrides)
                                          │
                                       main()
                                          │
                    ┌─────────────────────┼─────────────────────┐
                    │                     │                     │
             parse_args()          setup_paths()      compute_xdg_barriers()
             (CLI flags)        (source/target dirs)  (XDG_* → fold barriers)
                                                               │
                              for each package: resolve_package()
                                                               │
                                                        scan_package()
                                                        (find -type f)
                                                               │
                                                     filter_candidates()
                                                     (git + regex + glob)
                                                               │
                                                     fold_targets()
                                                     (resolve: fold points + individual files)
                                                               │
                                                      resolved_targets[]
                                                     (final resolved list for symlinking)
                                                               │
                                              stow_package() / unstow_package()
                                              (evaluate conditions, strip ## annotations,
                                               create/remove symlinks, handle conflicts)
```

### XDG-Aware Folding

XDG directories (derived from set `XDG_*` environment variables) act as fold barriers:

- **No hardcoded paths** — barriers are computed purely from environment variables
- **Fold stops at the barrier** — the XDG directory itself cannot be a symlink
- **Children can still fold** — e.g. `.config/nvim/` can be symlinked as a whole
- **Ancestors are protected** — if `.local/share` is a barrier, `.local` also cannot fold
- **On by default** — disable with `--no-xdg`

Checked variables: `XDG_CONFIG_HOME`, `XDG_DATA_HOME`, `XDG_STATE_HOME`,
`XDG_CACHE_HOME`, `XDG_BIN_HOME`, `XDG_RUNTIME_DIR`

Example with `XDG_CONFIG_HOME=/home/user/.config` and target `/home/user`:
- Barrier: `.config`
- `.config/nvim/` → can be a single symlink (child of barrier)
- `.config/` → must be a real directory (barrier itself)

### Condition + Fold Interaction

Annotations (`##`) affect the pipeline at two points:

1. **Fold phase**: any directory with a `##`-annotated descendant is "tainted" and
   cannot be folded. Only clean (annotation-free) subtrees are eligible for folding.
2. **Stow phase**: each annotated file has its conditions evaluated. If conditions
   pass, the symlink target uses the sanitized name (annotations stripped). If
   conditions fail, the file is skipped entirely.

Example: `.config/mise/conf.d/20-desktop.toml##!docker`
- Fold: `conf.d/` cannot be folded (has annotated child)
- Stow: if not in Docker, symlink as `20-desktop.toml`; if in Docker, skip

### Fold Resolution

`fold_targets` receives two lists (separated by `--`): all scanned entries (pre-filter)
and candidates (post-filter). It returns the final resolved target list:

- **Fold points**: directories that can be symlinked as a whole (shallowest/maximal)
- **Individual files**: files not covered by any fold point

A directory is foldable only if:
1. All its scanned descendants survived filtering (no exclusions)
2. No descendant has a `##` annotation
3. It is not a fold barrier or ancestor of a barrier

```
Usage: stow_sh::fold_targets [--barrier=PATH ...] pkg_root -- all1 all2 ... -- cand1 cand2 ...
```

Example output with `--barrier=.config`:
```
Input (all = candidates, no exclusions):
  .config/nvim/init.lua
  .config/nvim/lua/plugins.lua
  .config/mise/conf.d/00-core.toml
  .config/mise/conf.d/20-desktop.toml##!docker
  .config/mise/config.toml
  .bashrc

Output:
  .bashrc                                     (flat file)
  .config/mise/conf.d/00-core.toml            (individual — tainted subtree)
  .config/mise/conf.d/20-desktop.toml##!docker (individual — annotated)
  .config/mise/config.toml                    (individual — tainted parent)
  .config/nvim                                (fold point — clean subtree)
```

### Module Dependency Graph

```
main.sh
  ├── version.sh    (version constant — no deps)
  ├── log.sh        (logging — no deps)
  ├── args.sh       (arg parsing — calls log.sh functions)
  ├── conditions.sh (## annotations, condition evaluation, plugin loader — calls log.sh)
  │     └── loads: conditions.d/*.sh (built-ins), then $XDG_CONFIG_HOME/stow.sh/conditions/*.sh (user)
  ├── filter.sh     (filtering — calls log.sh, reads args.sh state)
  ├── scan.sh       (scanning — calls log.sh)
  ├── fold.sh       (folding — calls log.sh, calls conditions.sh for annotation detection)
  ├── xdg.sh        (XDG barriers — calls log.sh, reads XDG_* env vars)
  └── stow.sh       (stow/unstow ops — calls log.sh, args.sh, conditions.sh)
```

### Naming Conventions

All functions use `stow_sh::` namespace prefix.
Condition predicates use `stow_sh::condition::<type>` namespace (e.g. `stow_sh::condition::os`).
State variables use `_stow_sh_` prefix with getter functions (e.g. `stow_sh::get_source()`).

## Known Issues

### Medium

1. **Per-file `git check-ignore`**: O(n) forks instead of batched `--stdin`.
2. **Subshell getter overhead**: every `$(stow_sh::get_*)` call forks a subshell.

## Development Guidelines

### Shell Style

- **Formatter**: shfmt (configured in `.editorconfig`)
- **Indentation**: 4 spaces
- **Error mode**: `set -euo pipefail` in all entrypoints
- **Namespace**: all new functions must use `stow_sh::` prefix
- **Condition predicates**: `stow_sh::condition::<type>` prefix
- **State variables**: `_stow_sh_` prefix, accessed via getter functions
- **Output**: user-facing output to stdout, log/debug to stderr
- **Quoting**: always quote variables, especially in `$()` and parameter expansions

### Testing

- **Framework**: [bats-core](https://github.com/bats-core/bats-core)
- **Run tests**: `make test` or `bats --verbose-run test/`
- **Test location**: `test/*.bats`, fixtures in `test/fixtures/`
- **Current coverage** (185 tests, all passing):
  - `args.bats` — CLI argument parsing, short-flag expansion, path setup, getters (33)
  - `conditions.bats` — annotation parsing, path sanitization, condition evaluation, plugins (34)
  - `filter.bats` — git-aware, regex, glob filtering (14)
  - `fold.bats` — directory folding with annotation taint, XDG barriers, exclusion awareness (24)
  - `integration.bats` — end-to-end via `bin/stow.sh`: stow, unstow, restow, folding, XDG barriers, annotations, force, adopt, dry-run, ignore patterns, error cases, idempotency, self-stow (35)
  - `scan.bats` — recursive scanning, dotfiles, annotated filenames, spaces (8)
  - `stow.bats` — stow/unstow operations: symlinks, annotations, conflicts, force, adopt, dry-run (27)
  - `xdg.bats` — XDG barrier computation from environment variables (10)

### When Making Changes

1. Always run `make test` after changes and fix any regressions.
2. When adding/renaming/removing files, update the directory structure in this file.
3. When fixing known issues, remove them from the known issues list above.
4. When introducing new known issues, add them here.
5. Keep this file stateless — it should describe the **current** state of the project, not history.
