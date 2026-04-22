# Contributing to stow.sh

## Prerequisites

- Bash 4+
- [bats-core](https://github.com/bats-core/bats-core) for tests
- [shfmt](https://github.com/mvdan/sh) for formatting (configured in `.editorconfig`)
- [commitizen](https://commitizen-tools.github.io/commitizen/) for version bumps

## Development setup

Run directly from the source tree -- `bin/stow.sh` resolves all paths relative to itself:

```bash
# Add bin/ to PATH, or symlink:
ln -sf "$(pwd)/bin/stow.sh" ~/.local/bin/stow.sh
```

Install the git hooks for commit message validation:

```bash
make hooks
```

## Running tests

```bash
make test
# or
bats --verbose-run test/
```

The test suite has 255+ tests across unit, integration, and end-to-end:

| File | Scope |
|------|-------|
| `test/args.bats` | CLI argument parsing |
| `test/conditions.bats` | Annotation parsing, condition evaluation, plugins |
| `test/filter.bats` | Git-aware, regex, glob, stowignore filtering |
| `test/fold.bats` | Directory folding, barriers, exclusions |
| `test/integration.bats` | End-to-end via `bin/stow.sh` |
| `test/scan.bats` | Package directory scanning |
| `test/stow.bats` | Stow/unstow operations |
| `test/xdg.bats` | XDG barrier computation |

Always run `make test` after changes and fix any regressions.

## Project structure

```
bin/stow.sh          CLI entrypoint — sets STOW_ROOT, execs main.sh
src/
  main.sh            Orchestrator — scan → filter → fold → stow/unstow
  args.sh            CLI argument parsing, path setup, getters
  log.sh             Logging (color, debug levels, stderr, user reports)
  filter.sh          Path filtering (stowignore / git / regex / glob)
  scan.sh            Package directory scanner (find -type f)
  fold.sh            Directory folding + target resolution
  stow.sh            Stow/unstow operations, conflict handling, auto-unfold
  xdg.sh             XDG fold barrier detection
  conditions.sh      Annotation parsing, condition evaluation, plugin loader
  version.sh         Version constant
conditions.d/        Built-in condition plugins
hooks/               Git hooks (conventional commit validation)
test/                bats test suite
```

## Architecture

### Execution flow

```
bin/stow.sh  →  sets STOW_ROOT  →  exec src/main.sh "$@"
                                          │
                  sources: all src/*.sh modules
                  loads condition plugins (conditions.d/*.sh + user overrides)
                                          │
                                       main()
                                          │
                    parse_args → setup_paths → compute_xdg_barriers
                                          │
                              for each package:
                                load_stowignore
                                scan_package      (find -type f)
                                filter_candidates (stowignore + git + regex + glob)
                                fold_targets      (resolve fold points + individual files)
                                stow/unstow_package
```

### Module dependency graph

```
main.sh
  ├── version.sh    (no deps)
  ├── log.sh        (no deps)
  ├── args.sh       (→ log.sh)
  ├── conditions.sh (→ log.sh; loads conditions.d/*.sh + user plugins)
  ├── filter.sh     (→ log.sh, reads args.sh state)
  ├── scan.sh       (→ log.sh)
  ├── fold.sh       (→ log.sh, → conditions.sh)
  ├── xdg.sh        (→ log.sh, reads XDG_* env vars)
  └── stow.sh       (→ log.sh, → args.sh, → conditions.sh)
```

### Naming conventions

- Functions: `stow_sh::` namespace prefix
- Condition predicates: `stow_sh::condition::<type>`
- State variables: `_stow_sh_` prefix with getter functions

## Commit convention

This project enforces [Conventional Commits](https://www.conventionalcommits.org/). The `commit-msg` hook validates format.

**Format**: `<type>[(<scope>)][!]: <description>`

**Types**: `feat`, `fix`, `docs`, `style`, `refactor`, `perf`, `test`, `build`, `ci`, `chore`, `revert`

**Scopes** (optional): `stow`, `fold`, `filter`, `scan`, `args`, `log`, `xdg`, `conditions`

**Examples**:
```
feat(fold): add XDG barrier support
fix: handle symlink-only subdirectories in completeness check
refactor(stow)!: rename internal link function
test(integration): add auto-unfold end-to-end tests
```

## Shell style

- **Formatter**: shfmt (configured in `.editorconfig`)
- **Indentation**: 4 spaces
- **Error mode**: `set -euo pipefail` in all entrypoints
- **Namespace**: all functions use `stow_sh::` prefix
- **Output**: user-facing output to stdout, log/debug to stderr
- **Quoting**: always quote variables

## Releasing

**Always use `make release`** to bump versions. Never manually edit `src/version.sh` or `.cz.toml`.

```bash
make release          # clean tree check → tests → cz bump → changelog → tag
git push && git push --tags   # triggers CI release with tarball
```

CI (GitHub Actions) runs tests again and creates a GitHub Release with a source tarball attached.

## Adding a condition plugin

Create a file in `conditions.d/` with a function named `stow_sh::condition::<type>`:

```bash
# conditions.d/mycheck.sh
stow_sh::condition::mycheck() {
    local arg="$1"    # part after the dot (e.g. mycheck.foo → "foo")
    # return 0 if condition is met, 1 otherwise
}
```

The argument after the dot in `##mycheck.value` is passed as `$1`. Conditions without a dot receive an empty string.

Add tests in `test/conditions.bats` and update the built-in conditions table in `README.md`.
