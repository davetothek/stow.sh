# SPDX-License-Identifier: MIT
# Copyright (c) 2025 David Kristiansen

# filter.sh — triple-layer path filtering engine
#
# Filters candidate paths through up to three layers:
#   1. Git-aware: consult git check-ignore (respects negation patterns)
#   2. Regex: user-supplied -i patterns matched against relative paths
#   3. Glob: user-supplied -I patterns matched against relative paths
#
# Reads paths from stdin (one per line) and writes survivors to stdout.
#
# Depends on: log.sh, args.sh (state variables _stow_sh_ignore,
#             _stow_sh_ignore_glob, _stow_sh_git_mode)

shopt -s globstar extglob 2> /dev/null  # enable ** and extglob support

# Guard against re-declaration when sourced after args.sh
if ! declare -p _stow_sh_ignore 2> /dev/null | grep -q 'declare \-a'; then
    declare -a _stow_sh_ignore=()
fi

if ! declare -p _stow_sh_ignore_glob 2> /dev/null | grep -q 'declare \-a'; then
    declare -a _stow_sh_ignore_glob=()
fi

: "${_stow_sh_git_mode:=false}"

# Check whether a path should be ignored by git rules.
#
# Uses `git check-ignore --verbose` to distinguish between matched ignore
# rules and negation patterns (lines starting with !). The .git/ directory
# itself is always ignored.
#
# Usage: stow_sh::git_should_ignore relpath path
# Returns: 0 if ignored, 1 if kept
stow_sh::git_should_ignore() {
    local relpath="$1"
    local path="$2"
    local check_path output last_line

    # Always ignore .git/ directory explicitly
    if [[ "$path" == ".git" || "$path" == .git/* ]]; then
        return 0
    fi

    if [[ "$relpath" == "." ]]; then
        check_path="$path"
    else
        check_path="$relpath/$path"
    fi

    local rc=0
    output=$(git check-ignore --verbose "$check_path" 2> /dev/null) || rc=$?

    if [[ $rc -eq 0 ]]; then
        last_line=$(tail -n1 <<< "$output")
        if [[ "$last_line" =~ ^.*:[0-9]+:!.*$ ]]; then
            return 1  # explicitly re-included via negation pattern
        else
            return 0  # matched an ignore rule
        fi
    elif [[ $rc -eq 1 ]]; then
        return 1  # not ignored
    else
        return 1  # unknown failure — default to keeping the path
    fi
}

# Check if a path matches any user-supplied regex ignore pattern (-i).
#
# Usage: stow_sh::match_regex_ignore path
# Returns: 0 if matched (should ignore), 1 otherwise
stow_sh::match_regex_ignore() {
    local path="$1"
    for pattern in "${_stow_sh_ignore[@]}"; do
        [[ "$path" =~ $pattern ]] && return 0
    done
    return 1
}

# Check if a path matches any user-supplied glob ignore pattern (-I).
#
# Usage: stow_sh::match_glob_ignore path
# Returns: 0 if matched (should ignore), 1 otherwise
stow_sh::match_glob_ignore() {
    local path="$1"
    for pattern in "${_stow_sh_ignore_glob[@]}"; do
        [[ "$path" == $pattern ]] && return 0
    done
    return 1
}

# Read candidate paths from stdin and emit only those that survive all
# active filter layers (git, regex, glob).
#
# Usage: printf '%s\n' "${paths[@]}" | stow_sh::filter_candidates
# Output: surviving paths, one per line
stow_sh::filter_candidates() {
    local relpath="."
    if git_root=$(git rev-parse --show-toplevel 2> /dev/null); then
        relpath=$(realpath --relative-to="$git_root" .)
    fi

    local keep

    while IFS= read -r path; do
        keep=true
        stow_sh::log debug 3 "Filtering: $path"

        if [[ "$_stow_sh_git_mode" == true ]]; then
            if stow_sh::git_should_ignore "$relpath" "$path"; then
                stow_sh::log debug 3 "  → excluded by gitignore"
                keep=false
            fi
        fi

        if [[ $keep == true && ${#_stow_sh_ignore[@]} -gt 0 ]]; then
            if stow_sh::match_regex_ignore "$path"; then
                stow_sh::log debug 3 "  → excluded by regex ignore"
                keep=false
            fi
        fi

        if [[ $keep == true && ${#_stow_sh_ignore_glob[@]} -gt 0 ]]; then
            if stow_sh::match_glob_ignore "$path"; then
                stow_sh::log debug 3 "  → excluded by glob ignore"
                keep=false
            fi
        fi

        if [[ $keep == true ]]; then
            stow_sh::log debug 3 "  → kept"
            echo "$path"
        fi
    done
}
