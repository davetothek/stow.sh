# SPDX-License-Identifier: MIT
# Copyright (c) 2025 David Kristiansen

# args.sh — CLI argument parsing, path setup, and getter functions
#
# Parses command-line options into internal state variables, resolves
# source and target directories, and provides getter functions so other
# modules never access state variables directly.
#
# When no -S/-D/-R packages are given, auto-discovers subdirectories of
# the source directory. If none are found, falls back to self-stow mode
# (treating the source directory itself as the package).
#
# Depends on: log.sh

# --- Module state ---

_stow_sh_force=false
_stow_sh_debug=0
_stow_sh_dry_run=false
_stow_sh_color_mode="auto"
_stow_sh_adopt=false
_stow_sh_no_folding=false
_stow_sh_xdg_mode=true
_stow_sh_git_mode="auto"  # auto, true, false
_stow_sh_dir=""
_stow_sh_target=""
_stow_sh_source=""
declare -a _stow_sh_defer=()
declare -a _stow_sh_override=()
declare -a _stow_sh_ignore=()
declare -a _stow_sh_ignore_glob=()
declare -a _stow_sh_stow_packages=()
declare -a _stow_sh_unstow_targets=()
declare -a _stow_sh_restow_targets=()

# --- Getter functions ---
# Each getter echoes the corresponding state variable so callers can
# use command substitution: val="$(stow_sh::get_force)"

stow_sh::get_force() { echo "$_stow_sh_force"; }
stow_sh::get_debug() { echo "$_stow_sh_debug"; }
stow_sh::get_dry_run() { echo "$_stow_sh_dry_run"; }
stow_sh::get_color_mode() { echo "$_stow_sh_color_mode"; }
stow_sh::get_dir() { echo "$_stow_sh_dir"; }
stow_sh::get_target() { echo "$_stow_sh_target"; }
stow_sh::get_source() { echo "$_stow_sh_source"; }
stow_sh::get_git_mode() { echo "$_stow_sh_git_mode"; }
stow_sh::get_ignore() { printf '%s\n' "${_stow_sh_ignore[@]}"; }
stow_sh::get_ignore_glob() { printf '%s\n' "${_stow_sh_ignore_glob[@]}"; }
stow_sh::get_stow_packages() { printf '%s\n' "${_stow_sh_stow_packages[@]}"; }
stow_sh::get_unstow_packages() { printf '%s\n' "${_stow_sh_unstow_targets[@]}"; }
stow_sh::get_restow_packages() { printf '%s\n' "${_stow_sh_restow_targets[@]}"; }

# --- Boolean predicates ---
# Return 0 (true) or 1 (false) directly — suitable for use in if/&& chains.

stow_sh::is_folding_disabled() { [[ "${_stow_sh_no_folding:-false}" == true ]]; }
stow_sh::is_xdg_mode() { [[ "${_stow_sh_xdg_mode:-true}" == true ]]; }
stow_sh::is_dry_run() { [[ "${_stow_sh_dry_run:-false}" == true ]]; }
stow_sh::is_force() { [[ "${_stow_sh_force:-false}" == true ]]; }
stow_sh::is_adopt() { [[ "${_stow_sh_adopt:-false}" == true ]]; }

# Print usage information and exit.
#
# Usage: stow_sh::usage <exit_code>
stow_sh::usage() {
    echo
    echo "Usage: stow.sh [OPTIONS] [<directory>]"
    echo
    echo "Options:"
    echo "  -d DIR, --dir=DIR             Source directory (default: current directory)"
    echo "  -t DIR, --target=DIR          Target directory (default: parent of source)"
    echo "  -S PATH, --stow PATH          Stow the specified path(s)"
    echo "  -D PATH, --delete PATH        Unstow the specified path(s)"
    echo "  -R PATH, --restow PATH        Restow the specified path(s)"
    echo "  -i REGEX, --ignore=REGEX      Ignore pattern(s)"
    echo "  -I GLOB, --ignore-glob=GLOB   Ignore glob pattern(s)"
    echo "  --defer=PATH                  Defer link creation for specified path (repeatable)"
    echo "  --override=PATH               Override for specified path (repeatable)"
    echo "  --adopt                       Adopt pre-existing files into stow structure"
    echo "  --no-folding                  Disable directory folding"
    echo "  --no-xdg                      Disable XDG-aware fold barriers"
    echo "  -g, --git                     Enable git-aware filtering"
    echo "  -G, --no-git                  Disable git-aware filtering"
    echo "  -f, --force                   Overwrite existing symlinks"
    echo "  -n, --no                      Dry-run mode (no filesystem changes)"
    echo "  -v, --verbose                 Increase verbosity (repeatable)"
    echo "      --verbose=N               Set verbosity level directly"
    echo "      --color=WHEN              Colorize output: never, always, auto"
    echo "  -h, --help                    Show this help and exit"
    echo "      --version                 Show version and exit"
    echo
    echo "Positional Arguments:"
    echo "  <directory>                   Fallback stow root if not using -S/-D/-R"
    exit "$1"
}

# Walk up from $PWD looking for a .gitignore file.
#
# Usage: stow_sh::find_gitignore_upwards
# Output: absolute path to the nearest .gitignore, or nothing if not found
stow_sh::find_gitignore_upwards() {
    local dir="$PWD"
    while [[ "$dir" != "/" ]]; do
        if [[ -f "$dir/.gitignore" ]]; then
            echo "$dir/.gitignore"
            return
        fi
        dir="$(dirname "$dir")"
    done
}

# Parse command-line arguments into module state.
#
# Handles short-flag expansion (e.g. -vvn → -v -v -n), long options,
# multi-value flags (-S pkg1 pkg2), and auto-detection of git mode.
# After parsing, discovers default stow packages if none were given.
#
# Usage: stow_sh::parse_args "$@"
stow_sh::parse_args() {
    stow_sh::log debug 3 "parse_args() invoked with args: $*"
    local explicit_git_flag=false

    while [[ $# -gt 0 ]]; do
        # Expand combined short flags: -vvn → -v -v -n
        if [[ "$1" =~ ^-[^-] && "${#1}" -gt 2 ]]; then
            expanded_short_opts=()
            for ((i = 1; i < ${#1}; i++)); do
                expanded_short_opts+=("-${1:i:1}")
            done
            set -- "${expanded_short_opts[@]}" "${@:2}"
            continue
        fi
        case "$1" in
            -d | --dir)
                _stow_sh_dir="$2"
                stow_sh::log debug 2 "Set dir: $_stow_sh_dir"
                shift 2
                ;;
            -t | --target)
                _stow_sh_target="$2"
                stow_sh::log debug 2 "Set target: $_stow_sh_target"
                shift 2
                ;;
            -f | --force)
                _stow_sh_force=true
                stow_sh::log debug 2 "Enabled force mode"
                shift
                ;;
            -n | --no)
                _stow_sh_dry_run=true
                stow_sh::log debug 2 "Enabled dry-run mode"
                shift
                ;;
            -v)
                _stow_sh_debug=$((_stow_sh_debug + 1))
                stow_sh::log debug 2 "Increased verbosity to $_stow_sh_debug"
                shift
                ;;
            --verbose=*)
                _stow_sh_debug="${1#*=}"
                stow_sh::log debug 2 "Set verbosity level to $_stow_sh_debug"
                shift
                ;;
            --color=*)
                _stow_sh_color_mode="${1#*=}"
                stow_sh::log debug 2 "Set color_mode=$_stow_sh_color_mode"
                shift
                ;;
            -i | --ignore)
                shift
                while [[ $# -gt 0 && "$1" != -* ]]; do
                    _stow_sh_ignore+=("$1")
                    stow_sh::log debug 2 "Added ignore pattern: $1"
                    shift
            done
                ;;
            --ignore=*)
                _stow_sh_ignore+=("${1#*=}")
                stow_sh::log debug 2 "Added ignore pattern: ${1#*=}"
                shift
                ;;
            -I | --ignore-glob)
                shift
                while [[ $# -gt 0 && "$1" != -* ]]; do
                    _stow_sh_ignore_glob+=("$1")
                    stow_sh::log debug 2 "Added ignore-glob pattern: $1"
                    shift
            done
                ;;
            --ignore-glob=*)
                _stow_sh_ignore_glob+=("${1#*=}")
                stow_sh::log debug 2 "Added ignore-glob pattern: ${1#*=}"
                shift
                ;;
            -g | --git)
                _stow_sh_git_mode=true
                explicit_git_flag=true
                stow_sh::log debug 2 "Explicitly enabled git mode"
                shift
                ;;
            -G | --no-git)
                _stow_sh_git_mode=false
                explicit_git_flag=true
                stow_sh::log debug 2 "Explicitly disabled git mode"
                shift
                ;;
            -S | --stow)
                shift
                while [[ $# -gt 0 && "$1" != -* ]]; do
                    _stow_sh_stow_packages+=("$1")
                    stow_sh::log debug 2 "Added stow target: $1"
                    shift
            done
                ;;
            -D | --delete)
                shift
                while [[ $# -gt 0 && "$1" != -* ]]; do
                    _stow_sh_unstow_targets+=("$1")
                    stow_sh::log debug 2 "Added unstow target: $1"
                    shift
            done
                ;;
            -R | --restow)
                shift
                while [[ $# -gt 0 && "$1" != -* ]]; do
                    _stow_sh_restow_targets+=("$1")
                    stow_sh::log debug 2 "Added restow target: $1"
                    shift
            done
                ;;
            --adopt)
                _stow_sh_adopt=true
                stow_sh::log debug 2 "Enabled adopt mode"
                shift
                ;;
            --no-folding)
                _stow_sh_no_folding=true
                stow_sh::log debug 2 "Disabled folding"
                shift
                ;;
            --no-xdg)
                _stow_sh_xdg_mode=false
                stow_sh::log debug 2 "Disabled XDG-aware fold barriers"
                shift
                ;;
            --defer=*)
                _stow_sh_defer+=("${1#*=}")
                stow_sh::log debug 2 "Added defer pattern: ${1#*=}"
                shift
                ;;
            --override=*)
                _stow_sh_override+=("${1#*=}")
                stow_sh::log debug 2 "Added override pattern: ${1#*=}"
                shift
                ;;
            -h | --help)
                stow_sh::usage 0
                ;;
            --version)
                echo "stow.sh version $STOW_SH_VERSION"
                exit 0
                ;;
            --)
                shift
                break
                ;;
            -* | --*)
                stow_sh::log error "Unknown option: $1"
                stow_sh::usage 1
                ;;
            *)
                break
                ;;
        esac
    done

    # Auto-detect git mode when neither -g nor -G was given
    if [[ "$explicit_git_flag" == false ]]; then
        if git rev-parse --is-inside-work-tree &> /dev/null; then
            _stow_sh_git_mode=true
            stow_sh::log debug 2 "Auto-enabled git mode (inside git repo)"
        else
            _stow_sh_git_mode=false
            stow_sh::log debug 2 "Not inside git repo — git mode disabled"
        fi
    fi

    if [[ "$_stow_sh_git_mode" == true ]]; then
        if ! git_root=$(git rev-parse --show-toplevel 2> /dev/null); then
            stow_sh::log error "Cannot enable --git: not inside a git repository"
            exit 1
        fi

        expected_gitignore="$git_root/.gitignore"
        if [[ ! -f "$expected_gitignore" ]]; then
            stow_sh::log error "No .gitignore found at git repo root: $expected_gitignore"
            exit 1
        fi

        ignore_git_file="$expected_gitignore"
        stow_sh::log debug 2 "Git-aware mode: using gitignore from $ignore_git_file"
    fi

    # At most one positional argument (legacy stow root path)
    if [[ $# -gt 1 ]]; then
        stow_sh::usage 1
    elif [[ $# -eq 1 ]]; then
        _stow_sh_stow_packages+=("$1")
        stow_sh::log debug 2 "Added positional stow target: $1"
    fi

    # Auto-discover packages if none were specified via -S/-D/-R
    if [[ ${#_stow_sh_stow_packages[@]} -eq 0 && ${#_stow_sh_unstow_targets[@]} -eq 0 && ${#_stow_sh_restow_targets[@]} -eq 0 ]]; then
        local scan_root
        if [[ -z "$_stow_sh_dir" ]]; then
            scan_root="$(pwd)"
        else
            scan_root="$(realpath "$_stow_sh_dir")"
        fi
        stow_sh::log debug 1 "No stow targets provided — defaulting to all subdirs in $scan_root"
        while IFS= read -r dir; do
            [[ "$dir" == .* ]] && continue
            _stow_sh_stow_packages+=("$dir")
        done < <(find "$scan_root" -mindepth 1 -maxdepth 1 -type d -printf "%f\n")

        # Self-stow fallback: treat the source dir itself as the package
        if [[ ${#_stow_sh_stow_packages[@]} -eq 0 ]]; then
            _stow_sh_stow_packages+=(".")
            stow_sh::log debug 1 "No subdirectories found — self-stow mode (source dir is the package)"
        fi
    fi
}

# Resolve source and target directories to absolute paths.
#
# If -d was not given, defaults to $PWD. If -t was not given, defaults
# to the parent of the source directory (matching GNU Stow behavior).
#
# Usage: stow_sh::setup_paths
stow_sh::setup_paths() {
    stow_sh::log debug 3 "setup_paths() with dir='$_stow_sh_dir' and target='$_stow_sh_target'"

    if [[ -z "$_stow_sh_dir" ]]; then
        _stow_sh_source="$(pwd)"
    else
        _stow_sh_source="$(realpath "$_stow_sh_dir")"
    fi

    if [[ -n "$_stow_sh_target" ]]; then
        _stow_sh_target="$(realpath "$_stow_sh_target")"
    else
        _stow_sh_target="$(dirname "$_stow_sh_source")"
    fi

    stow_sh::log debug 2 "Using source: $_stow_sh_source"
    stow_sh::log debug 2 "Using target: $_stow_sh_target"
}
