# stow.sh

[GNU Stow](https://www.gnu.org/software/stow/) rewritten in pure Bash, with extras for dotfiles management.

Stow manages dotfiles by creating symlinks from a source directory (your dotfiles repo) into a target directory (your home). stow.sh does the same thing, plus conditional dotfiles, git-aware filtering, per-package ignore files, and XDG-aware directory folding.

## Features

Everything GNU Stow does, plus:

- Conditional dotfiles via `##` annotations (e.g. `file##os.linux,shell.bash`)
- Git-aware filtering -- respects `.gitignore` rules including negation patterns
- Per-package `.stowignore` files for excluding files from stowing
- Regex (`-i`) and glob (`-I`) ignore patterns on the command line
- XDG-aware directory folding -- `XDG_*` directories stay real, their children can still fold
- Auto-unfold -- falls back to individual symlinks when a target directory already exists
- Pluggable condition predicates as shell functions
- Pure Bash 4+, no external dependencies

## Installation

### From source (recommended)

```bash
git clone https://github.com/davidKristiansen/stow.sh.git
cd stow.sh
make install
```

This symlinks `stow.sh` into `$XDG_BIN_HOME` (or `~/.local/bin`) and copies built-in condition plugins to `$XDG_DATA_HOME/stow.sh/conditions.d/`.

### As a git submodule

Useful when you want stow.sh tracked inside your dotfiles repo:

```bash
cd ~/.dotfiles
git submodule add https://github.com/davidKristiansen/stow.sh.git .local/lib/stow.sh
make -C .local/lib/stow.sh install
```

### Uninstall

```bash
make uninstall
```

## Quick Start

```bash
# Stow all packages (subdirectories) from current dir into parent dir
cd ~/.dotfiles
stow.sh

# Stow a specific package
stow.sh -S vim

# Unstow a package
stow.sh -D vim

# Restow (unstow + stow) to refresh symlinks
stow.sh -R vim

# Dry-run to preview what would happen
stow.sh -n

# Force overwrite existing files/symlinks
stow.sh -f
```

### Self-stow mode

When the source directory has no subdirectories (or none are specified), stow.sh treats the source directory itself as the package. This is the typical setup for a flat dotfiles repo:

```bash
cd ~/.dotfiles
stow.sh -t ~
```

This symlinks everything in `~/.dotfiles/` directly into `~/`.

## Usage

```
stow.sh — a symlink manager for dotfiles

Creates symlinks from a source (dotfiles) directory into a target (home)
directory. Supports conditional files (## annotations), directory folding,
and git-aware filtering.

Usage:
  stow.sh [OPTIONS] [PACKAGE ...]
  stow.sh -S PACKAGE ... [-t TARGET] [-d SOURCE]
  stow.sh -D PACKAGE ... [-t TARGET]
  stow.sh -R PACKAGE ... [-t TARGET] [-d SOURCE]

A PACKAGE is a subdirectory of the source directory containing files to
symlink. If no packages are given, all subdirectories of the source
directory are stowed (or the source itself if it has no subdirectories).

Actions:
  -S, --stow PACKAGE ...    Create symlinks for the given package(s)
  -D, --delete PACKAGE ...  Remove symlinks for the given package(s)
  -R, --restow PACKAGE ...  Remove then re-create symlinks (useful after
                            updating dotfiles)

Directories:
  -d, --dir DIR             Source directory where packages live
                            (default: current directory)
  -t, --target DIR          Target directory for symlinks
                            (default: parent of source directory)

Filtering:
  -g, --git                 Use .gitignore rules to skip ignored files
  -G, --no-git              Disable git-aware filtering
                            (default: auto-detect based on git repo)
  -i, --ignore REGEX ...    Skip files matching regex pattern(s)
  -I, --ignore-glob GLOB ...
                            Skip files matching glob pattern(s)

  A .stowignore file in a package directory can list glob patterns
  (one per line) to permanently exclude files. The .stowignore file
  itself is always excluded. Lines starting with # are comments.

Folding:
  --no-folding              Symlink each file individually instead of
                            symlinking entire directories when possible
  --no-xdg                  Don't treat XDG directories (e.g. ~/.config)
                            as fold barriers

Conflict handling:
  -f, --force               Overwrite existing symlinks at the target
  --adopt                   Move existing target files into the source
                            package, then create the symlink
  --defer=REGEX             Skip if a symlink from another package
                            already exists at the target (repeatable)
  --override=REGEX          Replace symlinks from other packages that
                            match the pattern (repeatable)

Output:
  -v, --verbose             Show more detail (repeat for more: -vvv)
      --verbose=N           Set verbosity to level N directly
      --color=WHEN          Color output: auto, always, never (default: auto)
  -n, --no, --dry-run       Show what would be done without making changes

Info:
  -h, --help                Show this help
      --version             Show version

Examples:
  stow.sh                   Stow all packages from . into ..
  stow.sh vim bash          Stow only the vim and bash packages
  stow.sh -t ~ -d ~/dotfiles -S vim
                            Stow vim from ~/dotfiles into ~
  stow.sh -D vim            Remove symlinks created by the vim package
  stow.sh -R vim            Re-stow vim (unstow + stow)
  stow.sh -n -vv            Dry-run with verbose output — see what
                            would happen without changing anything
```

### Git-aware filtering

When run inside a git repository (auto-detected), stow.sh respects `.gitignore` rules. Files ignored by git are excluded from stowing. This includes negation patterns (`!important.txt`).

Disable with `-G` or `--no-git`. Force enable with `-g`.

### Filtering priority

Filters are applied in order:

1. **Stowignore** -- excludes files matching `.stowignore` patterns (always active)
2. **Git-aware** -- excludes files matching `.gitignore` (if enabled)
3. **Regex** (`-i`) -- excludes files matching any regex pattern
4. **Glob** (`-I`) -- excludes files matching any glob pattern

### .stowignore

A `.stowignore` file in a package directory lists glob patterns (one per line) to permanently exclude files and directories from stowing. The `.stowignore` file itself is always excluded.

```
# .stowignore — project management files, not dotfiles
AGENTS.md
.github
.gitignore
.gitmodules
*.baseline
bootstrap
```

Patterns match against the full relative path, the basename, and every ancestor directory segment. A pattern like `.github` excludes `.github/CODEOWNERS`, `.github/workflows/ci.yml`, etc.

Lines starting with `#` are comments. Blank lines are ignored.

## Conditional Dotfiles

Annotate files and directories with `##` followed by conditions. Conditions are evaluated at stow time; the annotation is stripped from the symlink name.

### Syntax

```
filename##condition
filename##cond1,cond2        # AND: all must pass
filename##!condition          # NOT: negation
dir##condition/file           # directory condition propagates to all children
```

### Built-in conditions

| Condition | Description | Example |
|-----------|-------------|---------|
| `os.<name>` | Matches OS name from `/etc/os-release` (case-insensitive) | `file##os.arch` |
| `shell.<name>` | Matches `$SHELL` basename | `file##shell.zsh` |
| `exe.<name>` | True if executable is in `$PATH` | `file##exe.nvim` |
| `wm.<name>` | Alias for `exe` (window manager check) | `file##wm.sway` |
| `docker` | True if running inside Docker (`/.dockerenv`) | `file##!docker` |
| `wsl` | True if running inside WSL (`/proc/version`) | `file##wsl` |
| `no` | Always false -- file is never deployed | `cache##no` |
| `extension` | Always true -- preserves file extension in source name | `script.conf##extension.sh` |

### Examples

```
.bashrc##shell.bash            # Only deploy if shell is bash
.zshrc##shell.zsh              # Only deploy if shell is zsh
.config/sway##wm.sway/        # Entire directory only if sway is installed
gpg-agent.conf##!wsl           # Deploy everywhere except WSL
20-desktop.toml##!docker       # Skip in Docker containers
.local/lib/stow.sh##no/       # Never deploy (e.g. git submodule)
```

### Directory propagation

When a directory segment has a condition, it propagates to all files inside:

```
.config/zsh##shell.zsh/
  .zshrc
  .zprofile
```

If shell is not zsh, both `.zshrc` and `.zprofile` are skipped. If shell is zsh, the whole directory is symlinked: `~/.config/zsh -> dotfiles/.config/zsh##shell.zsh`.

### Custom conditions

Create shell scripts in `$XDG_CONFIG_HOME/stow.sh/conditions/`:

```bash
# ~/.config/stow.sh/conditions/work.sh
stow_sh::condition::work() {
    [[ "$(hostname)" == *corp* ]]
}
```

Now you can use `file##work` or `file##!work` in your dotfiles.

## Directory Folding

stow.sh minimizes the number of symlinks by "folding" -- when an entire directory can be represented by a single symlink, it creates one directory symlink instead of individual file symlinks.

```
# Without folding (--no-folding):
~/.config/nvim/init.lua -> dotfiles/.config/nvim/init.lua
~/.config/nvim/lua/plugins.lua -> dotfiles/.config/nvim/lua/plugins.lua

# With folding (default):
~/.config/nvim -> dotfiles/.config/nvim
```

A directory can be folded only if:
1. All files on disk inside it are accounted for in the candidate list
2. No descendant has a `##` annotation in its own name
3. It is not a fold barrier

### XDG-aware fold barriers

XDG directories act as fold barriers -- they cannot become symlinks because other applications expect them to be real directories.

Barriers are computed from set `XDG_*` environment variables:
- `XDG_CONFIG_HOME` (typically `~/.config`)
- `XDG_DATA_HOME` (typically `~/.local/share`)
- `XDG_STATE_HOME` (typically `~/.local/state`)
- `XDG_CACHE_HOME` (typically `~/.cache`)
- `XDG_BIN_HOME` (typically `~/.local/bin`)
- `XDG_RUNTIME_DIR`

The barrier directory itself must be real, but children can still fold:

```
~/.config/                 # real directory (barrier)
~/.config/nvim -> dotfiles # single symlink (child of barrier, folded)
~/.config/mise/config.toml # individual symlink (sibling has annotation)
```

Disable with `--no-xdg`.

### Auto-unfold

When a fold point conflicts with an existing real directory at the target (e.g. `~/.gnupg` already has private keys), stow.sh falls back to creating individual symlinks inside it instead of reporting a conflict. Child directories that don't exist at the target are still folded into single symlinks.

## Development

### Prerequisites

- Bash 4+
- [bats-core](https://github.com/bats-core/bats-core) (for tests)
- shfmt (for formatting, configured in `.editorconfig`)

### Running tests

```bash
make test
# or
bats --verbose-run test/
```

### Commit convention

This project enforces [Conventional Commits](https://www.conventionalcommits.org/). Install the git hook:

```bash
make hooks
```

Format: `<type>[(<scope>)][!]: <description>`

Types: `feat`, `fix`, `docs`, `style`, `refactor`, `perf`, `test`, `build`, `ci`, `chore`, `revert`

### Project structure

```
bin/stow.sh        CLI entrypoint
src/main.sh        Orchestrator pipeline
src/args.sh        CLI argument parsing
src/log.sh         Logging framework
src/filter.sh      Path filtering (git/regex/glob)
src/scan.sh        Package directory scanner
src/fold.sh        Directory folding + target resolution
src/stow.sh        Stow/unstow operations
src/xdg.sh         XDG fold barrier computation
src/conditions.sh  Annotation parsing + condition evaluation
conditions.d/      Built-in condition plugins
hooks/             Git hooks (conventional commits)
test/              bats test suite (255 tests)
```

## License

MIT

## Acknowledgements

- [GNU Stow](https://www.gnu.org/software/stow/) -- the original dotfiles symlink manager that inspired this project's core design and CLI interface.
- [yadm](https://yadm.io/) -- its conditional file handling (`##` annotations) was the direct inspiration for stow.sh's conditional dotfiles system.
