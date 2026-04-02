# SPDX-License-Identifier: MIT
# Copyright (c) 2025 David Kristiansen

# filter.sh — triple-layer path filtering engine
#
# Filters candidate paths through up to three layers:
#   1. Git-aware: batch git check-ignore via --stdin (single fork)
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

# Check whether a single path should be ignored by git rules.
#
# Uses `git check-ignore --verbose` to distinguish between matched ignore
# rules and negation patterns (lines starting with !). The .git/ directory
# itself is always ignored.
#
# Note: this forks a subprocess per call — use __build_git_ignored_set for
# bulk filtering. Kept as a public function for testability.
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

# Build a set of git-ignored paths using a single batched call.
#
# Pipes all paths through `git check-ignore -n --verbose --stdin` and
# parses the output to determine which paths are ignored. Negation
# patterns (lines starting with !) are handled correctly.
#
# Usage: stow_sh::__build_git_ignored_set paths_array ignored_set_name
#   paths_array — name of array containing relative paths to check
#   ignored_set_name — name of associative array to populate (path → 1)
stow_sh::__build_git_ignored_set() {
    local -n _paths="$1"
    local -n _ignored="$2"

    local relpath="."
    local git_root
    if git_root=$(git rev-parse --show-toplevel 2> /dev/null); then
        relpath=$(realpath --relative-to="$git_root" .)
    fi

    # Build input: prepend relpath if not "."
    local -a check_paths=()
    local p
    for p in "${_paths[@]}"; do
        # .git/ is always ignored — mark it directly, skip git check-ignore
        if [[ "$p" == ".git" || "$p" == .git/* ]]; then
            _ignored["$p"]=1
            continue
        fi
        if [[ "$relpath" == "." ]]; then
            check_paths+=("$p")
        else
            check_paths+=("$relpath/$p")
        fi
    done

    [[ ${#check_paths[@]} -eq 0 ]] && return 0

    # Single batched call: -n shows non-matching lines too so we can
    # distinguish ignored / negated / clean in one pass.
    # Output format: <source>:<linenum>:<pattern>\t<pathname>
    #   ignored:  ".gitignore:1:lazy-lock.json\tpath"
    #   negated:  ".gitignore:5:!pattern\tpath"  (pattern starts with !)
    #   clean:    "::\tpath"
    local output
    output=$(printf '%s\n' "${check_paths[@]}" \
        | git check-ignore -n --verbose --stdin 2> /dev/null) || true

    local line rule tab_part
    while IFS= read -r line; do
        [[ -z "$line" ]] && continue
        # Split on tab: left side is source:linenum:pattern, right side is pathname
        rule="${line%%	*}"
        tab_part="${line#*	}"

        # Strip relpath prefix to get back to the original relative path
        if [[ "$relpath" != "." ]]; then
            tab_part="${tab_part#"$relpath"/}"
        fi

        if [[ "$rule" == "::" ]]; then
            # Not ignored — skip
            continue
        fi

        # Extract the pattern (after second colon)
        local pattern="${rule#*:}"    # "linenum:pattern"
        pattern="${pattern#*:}"       # "pattern"

        if [[ "$pattern" == !* ]]; then
            # Negation pattern — explicitly re-included
            stow_sh::log debug 3 "Git re-included (negation): '$tab_part'"
        else
            # Matched an ignore rule
            _ignored["$tab_part"]=1
            stow_sh::log debug 3 "Git ignored: '$tab_part'"
        fi
    done <<< "$output"
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
# Git filtering is done in a single batched call rather than per-file
# to avoid O(n) subprocess forks.
#
# Usage: printf '%s\n' "${paths[@]}" | stow_sh::filter_candidates
# Output: surviving paths, one per line
stow_sh::filter_candidates() {
    # Read all paths into an array first (needed for batched git check)
    local -a all_paths=()
    while IFS= read -r path; do
        all_paths+=("$path")
    done

    # Build git-ignored set in one batched call
    local -A git_ignored=()
    if [[ "$_stow_sh_git_mode" == true ]]; then
        stow_sh::__build_git_ignored_set all_paths git_ignored
    fi

    # Filter each path through all layers
    local keep
    for path in "${all_paths[@]}"; do
        keep=true
        stow_sh::log debug 3 "Filtering: $path"

        if [[ "$_stow_sh_git_mode" == true ]]; then
            if [[ -n "${git_ignored[$path]+set}" ]]; then
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
