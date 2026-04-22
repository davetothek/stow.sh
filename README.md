# stow.sh

[![License: MIT](https://img.shields.io/badge/License-MIT-yellow.svg)](https://github.com/davidKristiansen/stow.sh/blob/main/LICENSE)

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

### With mise

```bash
mise use -g "github:davidKristiansen/stow.sh"
```

### From source

```bash
git clone https://github.com/davidKristiansen/stow.sh.git
cd stow.sh
make install
```

Installs to `~/.local` for regular users, `/usr/local` for root. Override with `PREFIX=`.

### Uninstall

```bash
make uninstall
# or
mise rm "github:davidKristiansen/stow.sh"
```

## Quick Start

```bash
# Stow all packages from current dir into parent dir
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

When the source directory has no subdirectories (or none are specified), stow.sh treats the source directory itself as the package:

```bash
cd ~/.dotfiles
stow.sh    # symlinks everything into ~/
```

## Usage

```
Usage:
  stow.sh [OPTIONS] [PACKAGE ...]
  stow.sh -S PACKAGE ... [-t TARGET] [-d SOURCE]
  stow.sh -D PACKAGE ... [-t TARGET]
  stow.sh -R PACKAGE ... [-t TARGET] [-d SOURCE]

Actions:
  -S, --stow PACKAGE ...    Create symlinks for the given package(s)
  -D, --delete PACKAGE ...  Remove symlinks for the given package(s)
  -R, --restow PACKAGE ...  Remove then re-create symlinks

Directories:
  -d, --dir DIR             Source directory (default: current directory)
  -t, --target DIR          Target directory (default: parent of source)

Filtering:
  -g, --git                 Use .gitignore rules to skip ignored files
  -G, --no-git              Disable git-aware filtering
  -i, --ignore REGEX ...    Skip files matching regex pattern(s)
  -I, --ignore-glob GLOB ...  Skip files matching glob pattern(s)

Folding:
  --no-folding              Symlink each file individually
  --no-xdg                  Don't treat XDG directories as fold barriers

Conflict handling:
  -f, --force               Overwrite existing symlinks at the target
  --adopt                   Move existing target files into the package
  --defer=REGEX             Skip if a symlink already exists at the target
  --override=REGEX          Replace symlinks from other packages

Output:
  -v, --verbose             Show more detail (repeat: -vvv)
  -n, --no, --dry-run       Preview without making changes
  --color=WHEN              auto, always, never (default: auto)
  -h, --help                Show help
  --version                 Show version
```

### Filtering priority

Filters are applied in order:

1. **Stowignore** -- `.stowignore` patterns (always active)
2. **Git-aware** -- `.gitignore` rules (if enabled)
3. **Regex** (`-i`) -- regex patterns
4. **Glob** (`-I`) -- glob patterns

### .stowignore

A `.stowignore` file in a package directory lists glob patterns (one per line) to permanently exclude files and directories. The `.stowignore` file itself is always excluded.

```
# .stowignore
AGENTS.md
.github
*.baseline
bootstrap
```

Patterns match against the full relative path, the basename, and every ancestor directory segment.

## Conditional Dotfiles

Annotate files and directories with `##` followed by conditions. Conditions are evaluated at stow time; the annotation is stripped from the symlink name.

```
filename##condition
filename##cond1,cond2        # AND: all must pass
filename##!condition          # NOT: negation
dir##condition/file           # directory condition propagates to children
```

### Built-in conditions

| Condition | Description | Example |
|-----------|-------------|---------|
| `os.<name>` | Matches OS from `/etc/os-release` | `file##os.arch` |
| `shell.<name>` | Matches `$SHELL` basename | `file##shell.zsh` |
| `exe.<name>` | True if executable is in `$PATH` | `file##exe.nvim` |
| `wm.<name>` | Alias for `exe` | `file##wm.sway` |
| `docker` | True inside Docker (`/.dockerenv`) | `file##!docker` |
| `wsl` | True inside WSL (`/proc/version`) | `file##wsl` |
| `laptop` | True if system has a battery | `file##laptop` |
| `desktop` | True if system has no battery | `file##desktop` |
| `no` | Always false -- never deployed | `cache##no` |
| `extension` | Always true -- preserves file extension | `script.conf##extension.sh` |

### Examples

```
.bashrc##shell.bash            # Only if shell is bash
.config/sway##wm.sway/        # Entire directory only if sway is installed
gpg-agent.conf##!wsl           # Deploy everywhere except WSL
20-desktop.toml##!docker       # Skip in Docker containers
.config/tlp##laptop/           # Power management only on laptops
monitors.xml##desktop          # Static monitor layout on desktops only
.local/lib/stow.sh##no/       # Never deploy (e.g. git submodule)
```

### Directory propagation

When a directory has a condition, it propagates to all files inside:

```
.config/zsh##shell.zsh/
  .zshrc
  .zprofile
```

If shell is not zsh, both files are skipped. If shell is zsh, the whole directory is symlinked as one: `~/.config/zsh -> dotfiles/.config/zsh##shell.zsh`.

## Custom Conditions

Place scripts in `$XDG_CONFIG_HOME/stow.sh/conditions/` (typically `~/.config/stow.sh/conditions/`). Each `.sh` file is sourced at startup:

```bash
# ~/.config/stow.sh/conditions/custom.sh

stow_sh::condition::work() {
    [[ "$(hostname)" == *corp* ]]
}

stow_sh::condition::wayland() {
    [[ -n "${WAYLAND_DISPLAY:-}" ]]
}
```

Then use them: `file##work`, `.config/sway##wayland/`.

Conditions support dot-notation arguments (`$1`):

```bash
stow_sh::condition::host() {
    [[ "$(hostname)" == "$1" ]]
}
```

```
.config/special##host.myserver/
```

User conditions override built-ins if they define the same function name.

## Directory Folding

stow.sh minimizes symlinks by "folding" -- symlinking an entire directory instead of individual files:

```
# Without folding:
~/.config/nvim/init.lua -> dotfiles/.config/nvim/init.lua
~/.config/nvim/lua/plugins.lua -> dotfiles/.config/nvim/lua/plugins.lua

# With folding (default):
~/.config/nvim -> dotfiles/.config/nvim
```

A directory can be folded only if all files inside it are in the candidate list, no descendant has a `##` annotation, and it is not a fold barrier.

### XDG fold barriers

XDG directories act as fold barriers -- they stay real directories because other applications expect that. Barriers are computed from `XDG_CONFIG_HOME`, `XDG_DATA_HOME`, `XDG_STATE_HOME`, `XDG_CACHE_HOME`, `XDG_BIN_HOME`, and `XDG_RUNTIME_DIR`.

The barrier itself stays real, but children can still fold:

```
~/.config/                 # real directory (barrier)
~/.config/nvim -> dotfiles # single symlink (folded child)
```

Disable with `--no-xdg`.

### Auto-unfold

When a fold point conflicts with an existing real directory (e.g. `~/.gnupg` has private keys), stow.sh falls back to individual symlinks inside it. Child directories that don't exist at the target are still folded.

## Contributing

See [CONTRIBUTING.md](CONTRIBUTING.md) for development setup, architecture, testing, and commit conventions.

## License

MIT

## Acknowledgements

- [GNU Stow](https://www.gnu.org/software/stow/) -- the original dotfiles symlink manager that inspired this project.
- [yadm](https://yadm.io/) -- its conditional file handling (`##` annotations) was the direct inspiration for stow.sh's conditional dotfiles system.
