<table>
<tr>
<td width="120">
<img src="assets/logo.png" alt="stow.sh logo" width="100">
</td>
<td>

# stow.sh

[![License: MIT](https://img.shields.io/badge/License-MIT-yellow.svg)](https://github.com/davetothek/stow.sh/blob/main/LICENSE)

[GNU Stow](https://www.gnu.org/software/stow/) rewritten in pure Bash, with extras for dotfiles: conditional files, git-aware filtering, per-package ignore files, and XDG-aware directory folding.

</td>
</tr>
</table>

<!--toc:start-->
- [What it does](#what-it-does)
- [Install](#install)
- [Quick start](#quick-start)
- [Compared to GNU Stow](#compared-to-gnu-stow)
- [Usage](#usage)
- [Ignoring files](#ignoring-files)
  - [.stowignore](#stowignore)
  - [Git-aware filtering](#git-aware-filtering)
- [Dotfiles mode](#dotfiles-mode)
- [Conditional dotfiles](#conditional-dotfiles)
  - [Built-in conditions](#built-in-conditions)
  - [Custom conditions](#custom-conditions)
- [Directory folding](#directory-folding)
  - [XDG fold barriers](#xdg-fold-barriers)
  - [Auto-unfold](#auto-unfold)
  - [Stale fold points](#stale-fold-points)
- [Contributing](#contributing)
- [License](#license)
- [Acknowledgements](#acknowledgements)
<!--toc:end-->

## What it does

Keep your dotfiles in one directory (usually a git repo); stow.sh symlinks them
into your home directory, and removes the links again when asked.

```
$ tree -a ~/dotfiles               $ stow.sh -t ~ -d ~/dotfiles bash
~/dotfiles                         + ~/.bashrc       -> dotfiles/bash/.bashrc
└── bash                           + ~/.bash_profile -> dotfiles/bash/.bash_profile
    ├── .bashrc
    └── .bash_profile
```

Each top-level directory (`bash` above) is a **package** you stow or unstow on
its own. When the source directory has no subdirectories, the source itself is
the package.

## Install

| Method | Command |
|--------|---------|
| Single file | `curl -fsSLO https://github.com/davetothek/stow.sh/releases/latest/download/stow.sh && chmod +x stow.sh` |
| mise | `mise use -g "github:davetothek/stow.sh"` |
| From source | `git clone https://github.com/davetothek/stow.sh.git && cd stow.sh && make install` |

- **Single file**: every module bundled into one script; verify it against the
  release's `SHA256SUMS`. User conditions still load.
- **From source**: installs to `~/.local`, or `/usr/local` as root. Override
  with `PREFIX=`; run `make` to list all targets.
- **Uninstall**: `make uninstall` or `mise rm "github:davetothek/stow.sh"`.

Requires Bash 4+. No other dependencies.

## Quick start

```bash
cd ~/dotfiles
stow.sh              # stow every package into the parent directory
stow.sh -S vim       # stow one package
stow.sh -D vim       # unstow it
stow.sh -R vim       # restow: unstow + stow, after changing the package
stow.sh -n -v        # dry-run: show what would happen
```

Every change is reported on stdout:

| Symbol | Meaning |
|--------|---------|
| `+` | created (link, unfold, evict, adopt, force) |
| `-` | removed |
| `~` | skipped (conditions not met) |
| `?` | would happen (dry-run) |

Runs are **all-or-nothing**: conflicts are checked up front, and if any are
found nothing is changed.

## Compared to GNU Stow

Same model and core flags: `-S`/`-D`/`-R`, `-t`, `-d`, `--adopt`,
`--no-folding`, `--dotfiles`, directory folding, atomic conflict handling.

| | GNU Stow | stow.sh |
|---|:---:|:---:|
| Runtime | Perl | Bash 4+ |
| [`##` conditional files](#conditional-dotfiles) | – | ✓ |
| [Git-aware filtering](#git-aware-filtering) (`-g`/`-G`) | – | ✓ |
| Per-package ignore file | `.stow-local-ignore` | [`.stowignore`](#stowignore) |
| Regex (`-i`) / glob (`-I`) ignores | regex only | ✓ |
| [XDG fold barriers](#xdg-fold-barriers) | – | ✓ |
| [Stale fold point](#stale-fold-points) repair | – | ✓ |
| `-p`/`--compat` | ✓ | – |
| `.stow-global-ignore` | ✓ | – |
| `--defer` / `--override` | ✓ | – |

If you depend on a feature stow.sh lacks, use GNU Stow.

## Usage

```
stow.sh [OPTIONS] [PACKAGE ...]

Actions:
  -S, --stow PACKAGE ...      Create symlinks
  -D, --delete PACKAGE ...    Remove symlinks
  -R, --restow PACKAGE ...    Remove, then re-create symlinks

Directories:
  -d, --dir DIR               Source directory (default: .)
  -t, --target DIR            Target directory (default: parent of source)

Filtering:
  -g, --git / -G, --no-git    Honour .gitignore (default: on inside a git repo)
  -i, --ignore REGEX ...      Skip paths matching a regex
  -I, --ignore-glob GLOB ...  Skip paths matching a glob

Folding & naming:
  --no-folding                Link every file individually
  --no-xdg                    Don't treat XDG directories as fold barriers
  --dotfiles                  Link dot-foo as .foo

Conflicts:
  -f, --force                 Overwrite existing symlinks at the target
  --adopt                     Move existing target files into the package
  --evict / --no-evict        Move filtered files out of a stale fold (default) / keep it

Output:
  -v, --verbose[=N]           More detail (repeatable: -vvv)
  -n, --no, --dry-run         Preview without changing anything
  --color=WHEN                auto | always | never
  -h, --help / --version
```

## Ignoring files

Four filters run in order; a path dropped by any of them is not stowed:

1. **`.stowignore`** in the package (always on)
2. **`.gitignore`** rules (`-g`)
3. **Regex** patterns (`-i`)
4. **Glob** patterns (`-I`)

### .stowignore

One glob per line; `#` starts a comment. A pattern matches the full relative
path, the basename, or any ancestor directory. The file itself is never stowed.

```
# .stowignore
AGENTS.md
.github
*.baseline
bootstrap
```

### Git-aware filtering

On by default inside a git repository. Git-ignored files are skipped,
negation patterns included. Never stowed:

- `.git/`
- the **package-root** `.gitignore` — it configures the filter, and nobody
  wants it as `~/.gitignore`

A **nested** `.gitignore` is content and deploys normally. If it ignores
anything beside it, that directory can't fold (the symlink would expose the
ignored files).

To deploy a global gitignore, use `~/.config/git/ignore` (git's XDG default),
or `dot-gitignore` under `--dotfiles`.

## Dotfiles mode

`--dotfiles` (GNU Stow compatible) lets dotfiles live **un-hidden** in the repo:
each path component starting with `dot-` is linked as `.`.

```
~/dotfiles/dot-bashrc              →  ~/.bashrc
~/dotfiles/dot-config/nvim/        →  ~/.config/nvim     (folded)
~/dotfiles/dot-config/dot-foo      →  ~/.config/.foo
```

- Only link names change; the package keeps its `dot-` names.
- Composes with conditions: `dot-foo##os.linux` → `.foo` on Linux.
- `dot-config` maps to the `.config` XDG barrier, so it stays a real directory.
- A directory that *contains* a `dot-` entry never folds; its children are
  linked individually so the names translate.

## Conditional dotfiles

Append `##` and conditions to a file or directory name. Conditions are checked
at stow time and the annotation is stripped from the link name.

```
file##cond             # deploy if cond is true
file##cond1,cond2      # AND
file##!cond            # NOT
dir##cond/             # applies to everything inside dir
```

```
.bashrc##shell.bash           # only when the shell is bash
.config/sway##wm.sway/        # whole directory, only if sway is installed
.config/systemd##!container   # skip in any container
monitors.xml##desktop         # desktops only
.local/lib/stow.sh##no/       # never deploy (e.g. a git submodule)
```

A directory whose children are clean can still fold:
`.config/zsh##shell.zsh/` becomes `~/.config/zsh -> dotfiles/.config/zsh##shell.zsh`
when the shell is zsh, and is skipped entirely otherwise.

### Built-in conditions

| Condition | True when | Example |
|-----------|-----------|---------|
| `os.<name>` | `/etc/os-release` matches | `file##os.arch` |
| `shell.<name>` | `$SHELL` basename matches | `file##shell.zsh` |
| `exe.<name>` | executable is in `$PATH` | `file##exe.nvim` |
| `wm.<name>` | alias for `exe` | `file##wm.sway` |
| `docker` | `/.dockerenv` exists | `file##!docker` |
| `container` | inside Docker, Podman, nspawn or LXC | `file##!container` |
| `wsl` | running under WSL | `file##wsl` |
| `laptop` | a battery is present | `file##laptop` |
| `desktop` | no battery is present | `file##desktop` |
| `no` | never | `cache##no` |
| `extension` | always — keeps a file extension | `script.conf##extension.sh` |

### Custom conditions

Every `.sh` file in `$XDG_CONFIG_HOME/stow.sh/conditions/` is sourced at
startup. Define `stow_sh::condition::<name>`; text after a dot arrives as `$1`.
A user condition overrides a built-in of the same name.

```bash
# ~/.config/stow.sh/conditions/custom.sh
stow_sh::condition::work() { [[ "$(hostname)" == *corp* ]]; }
stow_sh::condition::host() { [[ "$(hostname)" == "$1" ]]; }
```

Use them as `file##work` or `.config/special##host.myserver/`.

## Directory folding

stow.sh links a whole directory when it can, instead of every file in it:

```
~/.config/nvim -> dotfiles/.config/nvim                     # folded (default)
~/.config/nvim/init.lua -> dotfiles/.config/nvim/init.lua   # --no-folding
```

A directory folds only if every file in it is stowed, no descendant carries a
`##` annotation, and it is not an XDG barrier.

### XDG fold barriers

Directories named by `XDG_CONFIG_HOME`, `XDG_DATA_HOME`, `XDG_STATE_HOME`,
`XDG_CACHE_HOME`, `XDG_BIN_HOME` and `XDG_RUNTIME_DIR` (and their ancestors)
stay real directories, since other applications write there. Their children
can still fold:

```
~/.config/                  # real directory (barrier)
~/.config/nvim -> dotfiles  # folded child
```

Disable with `--no-xdg`.

### Auto-unfold

If a fold point meets an existing real directory at the target (say `~/.gnupg`
with your private keys), stow.sh links the package's entries into it
individually. Subdirectories missing at the target still fold.

### Stale fold points

A fold is only safe while every file in the directory belongs at the target.
When a file becomes filtered (newly gitignored, or a new `.stowignore`
pattern), the next run unfolds the directory and moves that file out of the
package:

```
# An earlier run folded ~/.config/app, and the app wrote local.conf through it.
$ stow.sh -S dotfiles
+ unfold ~/.config/app (stale fold point)
+ evict dotfiles/dot-config/app/local.conf -> ~/.config/app/local.conf
+ ~/.config/app/config.toml -> ../../dotfiles/dot-config/app/config.toml
```

Through the fold the app wrote into your repository, where `git clean -xdf`
would delete it. After the eviction it is a plain local file where the app
expects it. Safeguards:

- **Only untracked files move.** A tracked file being filtered suggests a
  one-off filter (`-I`, a new `.stowignore` line); that is an error, and the
  run aborts with zero changes.
- **`--no-evict`** keeps the fold point and warns.
- **Outside a git work tree** nothing is evicted (package content and app state
  are indistinguishable); the fold point stays, with a warning.

A fold whose *entire* directory became ignored is found too, by a sweep of the
package's directories. `--dry-run` shows every unfold and move. This makes
`mkdir -p` lines in bootstrap scripts, there only to stop a directory folding,
unnecessary.

## Contributing

See [CONTRIBUTING.md](CONTRIBUTING.md) for setup, architecture, tests and
commit conventions.

## License

MIT

## Acknowledgements

- [GNU Stow](https://www.gnu.org/software/stow/) — the original symlink farm
  manager this project reimplements.
- [yadm](https://yadm.io/) — its `##` alternate files inspired stow.sh's
  conditional dotfiles.
