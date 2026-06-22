<table>
<tr>
<td width="120">
<img src="assets/logo.png" alt="stow.sh logo" width="100">
</td>
<td>

# stow.sh

[![License: MIT](https://img.shields.io/badge/License-MIT-yellow.svg)](https://github.com/davetothek/stow.sh/blob/main/LICENSE)

[GNU Stow](https://www.gnu.org/software/stow/) rewritten in pure Bash, with extras for dotfiles management. Symlink farm manager with conditional dotfiles, git-aware filtering, per-package ignore files, and XDG-aware directory folding.

</td>
</tr>
</table>

<!--toc:start-->
- [What is this?](#what-is-this)
- [Features](#features)
- [Differences from GNU Stow](#differences-from-gnu-stow)
- [Installation](#installation)
  - [Single file (no install)](#single-file-no-install)
  - [With mise](#with-mise)
  - [From source](#from-source)
  - [Uninstall](#uninstall)
- [Quick Start](#quick-start)
  - [Self-stow mode](#self-stow-mode)
- [Usage](#usage)
  - [Filtering priority](#filtering-priority)
  - [.stowignore](#stowignore)
- [Dotfiles mode](#dotfiles-mode)
- [Conditional Dotfiles](#conditional-dotfiles)
  - [Built-in conditions](#built-in-conditions)
  - [Examples](#examples)
  - [Directory propagation](#directory-propagation)
- [Custom Conditions](#custom-conditions)
- [Directory Folding](#directory-folding)
  - [XDG fold barriers](#xdg-fold-barriers)
  - [Auto-unfold](#auto-unfold)
- [Contributing](#contributing)
- [License](#license)
- [Acknowledgements](#acknowledgements)
<!--toc:end-->

## What is this?

If you keep your dotfiles in one directory (often a git repo) and want them to
show up in the right places in your home directory, **stow.sh creates the
symlinks for you**. You organize the files once; it links them into place — and
removes them cleanly when you ask.

For example, given this layout:

```
~/dotfiles/
  bash/
    .bashrc
    .bash_profile
```

running `stow.sh -t ~ -d ~/dotfiles bash` produces:

```
~/.bashrc        ->  dotfiles/bash/.bashrc
~/.bash_profile  ->  dotfiles/bash/.bash_profile
```

Each top-level directory under your dotfiles (here, `bash`) is a *package* you
can stow or unstow independently. This is the model
[GNU Stow](https://www.gnu.org/software/stow/) pioneered — a "symlink farm
manager." stow.sh is a pure-Bash reimplementation of that idea with extras
aimed at dotfiles (conditional files, git-aware filtering, and more). It is
**not** a byte-for-byte GNU Stow clone — see
[Differences from GNU Stow](#differences-from-gnu-stow).

## Features

Core symlink-farm management — stow, unstow, restow, directory folding, and
conflict handling — plus extras aimed at dotfiles:

- Conditional dotfiles via `##` annotations (e.g. `file##os.linux,shell.bash`)
- GNU Stow-style `--dotfiles` -- keep files un-hidden as `dot-bashrc`, stow them as `.bashrc`
- Git-aware filtering -- respects `.gitignore` rules including negation patterns
- Per-package `.stowignore` files for excluding files from stowing
- Regex (`-i`) and glob (`-I`) ignore patterns on the command line
- XDG-aware directory folding -- `XDG_*` directories stay real, their children can still fold
- Auto-unfold -- falls back to individual symlinks when a target directory already exists
- Pluggable condition predicates as shell functions
- Atomic by default -- if any conflict is detected, nothing is changed (see below)
- Pure Bash 4+, no external dependencies (GNU Stow requires Perl)

## Differences from GNU Stow

stow.sh covers the common dotfiles workflow but is **not** a drop-in
replacement for every GNU Stow option. Be aware of the following.

**Same idea, same core flags:** `-S`/`-D`/`-R` (stow/delete/restow),
`-t`/`--target`, `-d`/`--dir`, `--adopt`, `--no-folding`, `--dotfiles`
(`dot-bashrc` → `.bashrc`), directory folding, and **all-or-nothing conflict
handling** — like GNU Stow, stow.sh checks for conflicts up front and makes no
changes if any are found.

**stow.sh adds (not in GNU Stow):** `##` conditional files, git-aware
filtering (`-g`/`-G`), per-package `.stowignore`, XDG fold barriers
(`--no-xdg`), and always-relative symlinks.

**GNU Stow features stow.sh does *not* implement:**

| GNU Stow | Status in stow.sh |
|----------|-------------------|
| `-p`/`--compat` (legacy symlink-name handling) | not supported |
| `.stow-local-ignore` / `.stow-global-ignore` | use `.stowignore` instead |
| `--defer` / `--override` (cross-package ownership) | not supported |
| `-p`-style multiple independent stow dirs in one run | not supported |

If you depend on any of those, use GNU Stow. For dotfiles, stow.sh is designed
to be a friendlier superset of the *common* workflow.

## Installation

### Single file (no install)

Each [release](https://github.com/davetothek/stow.sh/releases) ships a
self-contained `stow.sh` — every module bundled into one script. Download it,
make it executable, and run:

```bash
curl -fsSLO https://github.com/davetothek/stow.sh/releases/latest/download/stow.sh
chmod +x stow.sh
./stow.sh --version
```

Verify it against the published `SHA256SUMS` if you like. Built-in conditions
are baked in; user conditions in `$XDG_CONFIG_HOME/stow.sh/conditions` still
load.

### With mise

```bash
mise use -g "github:davetothek/stow.sh"
```

### From source

```bash
git clone https://github.com/davetothek/stow.sh.git
cd stow.sh
make install
```

Installs to `~/.local` for regular users, `/usr/local` for root. Override with `PREFIX=`.

### Uninstall

```bash
make uninstall
# or
mise rm "github:davetothek/stow.sh"
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

Naming:
  --dotfiles                Translate a leading 'dot-' to '.' per path
                            component (e.g. dot-bashrc → .bashrc)

Conflict handling:
  -f, --force               Overwrite existing symlinks at the target
  --adopt                   Move existing target files into the package

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

## Dotfiles mode

With `--dotfiles` (GNU Stow compatible), a package entry whose name begins with
`dot-` is stowed as if it began with `.`. This lets your dotfiles live
**un-hidden** in the repository:

```
~/.dotfiles/
  dot-bashrc
  dot-config/
    nvim/
      init.lua
```

```bash
stow.sh --dotfiles -t ~ ~/.dotfiles
```

```
~/.bashrc            ->  .dotfiles/dot-bashrc
~/.config/nvim       ->  .dotfiles/dot-config/nvim   # (folded; .config stays real under XDG)
```

The translation is applied **per path component** — `dot-config/dot-foo` links
as `.config/.foo` — and only to the link name; the package keeps its `dot-`
names. It composes with `##` annotations (`dot-foo##os.linux` → `.foo` on
Linux) and respects XDG fold barriers (a `dot-config` package directory maps to
the `.config` barrier, so it stays a real directory).

A directory that *contains* a `dot-` entry is never folded into a single
symlink (folding would expose the raw `dot-` name), so its `dot-` children are
always linked individually and translated correctly.

## Conditional Dotfiles

Annotate files and directories with `##` followed by conditions. Conditions are evaluated at stow time; the annotation is stripped from the symlink name.

```
filename##condition
filename##cond1,cond2        # AND: all must pass
filename##!condition         # NOT: negation
dir##condition/file          # directory condition propagates to children
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
.bashrc##shell.bash           # Only if shell is bash
.config/sway##wm.sway/        # Entire directory only if sway is installed
gpg-agent.conf##!wsl          # Deploy everywhere except WSL
20-desktop.toml##!docker      # Skip in Docker containers
.config/tlp##laptop/          # Power management only on laptops
monitors.xml##desktop         # Static monitor layout on desktops only
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
