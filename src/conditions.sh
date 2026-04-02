#!/usr/bin/env bash
# SPDX-License-Identifier: MIT
# Copyright (c) 2025 David Kristiansen

# conditions.sh — annotation parsing, condition evaluation, and plugin loading
#
# Paths can be annotated with conditions using the ## delimiter:
#   file##os.linux          → deploy only on Linux
#   file##shell.bash        → deploy only if default shell is bash
#   file##!docker           → deploy only if NOT in a Docker container
#   file##os.linux,exe.nvim → deploy only on Linux AND if nvim is in PATH
#
# Condition predicates are loaded as plugins. Each plugin defines one or more
# functions following the naming convention: stow_sh::condition::<type>()
#
# Loading order:
#   1. Built-in conditions from conditions.d/*.sh (shipped with stow.sh)
#      Searched in: $STOW_ROOT/conditions.d/ (dev), then
#                   $XDG_DATA_HOME/stow.sh/conditions.d/ (installed)
#   2. User conditions from $XDG_CONFIG_HOME/stow.sh/conditions/*.sh
#
# User plugins can override built-ins by defining the same function name.

# --- Plugin Loading ---

# Source all *.sh files from a directory.
# Usage: stow_sh::__load_conditions_from /path/to/dir
stow_sh::__load_conditions_from() {
    local dir="$1"

    if [[ ! -d "$dir" ]]; then
        stow_sh::log debug 2 "Condition directory not found: '$dir'"
        return 0
    fi

    local plugin
    for plugin in "$dir"/*.sh; do
        [[ -f "$plugin" ]] || continue
        stow_sh::log debug 2 "Loading condition plugin: $plugin"
        # shellcheck source=/dev/null
        source "$plugin"
    done
}

# Load all condition plugins: built-ins first, then user overrides.
# Call this once during startup (after log.sh is sourced).
stow_sh::load_condition_plugins() {
    local builtin_loaded=false

    # 1. Built-ins: try STOW_ROOT first (running from checkout)
    if [[ -n "${STOW_ROOT:-}" && -d "$STOW_ROOT/conditions.d" ]]; then
        stow_sh::log debug 2 "Loading built-in conditions from STOW_ROOT"
        stow_sh::__load_conditions_from "$STOW_ROOT/conditions.d"
        builtin_loaded=true
    fi

    # 2. Built-ins: fall back to XDG_DATA_HOME (installed)
    if [[ "$builtin_loaded" == false ]]; then
        local data_dir="${XDG_DATA_HOME:-$HOME/.local/share}/stow.sh/conditions.d"
        stow_sh::log debug 2 "Loading built-in conditions from XDG_DATA_HOME"
        stow_sh::__load_conditions_from "$data_dir"
    fi

    # 3. User plugins from XDG_CONFIG_HOME (always loaded, can override built-ins)
    local user_dir="${XDG_CONFIG_HOME:-$HOME/.config}/stow.sh/conditions"
    stow_sh::__load_conditions_from "$user_dir"
}

# --- Annotation Parsing ---

# Check if a path segment contains a ## annotation
# Usage: stow_sh::has_annotation "file##os.linux"
stow_sh::has_annotation() {
    [[ "$1" == *"##"* ]]
}

# Check if any path in a list has a ## annotation in any segment
# Usage: stow_sh::any_has_annotation path1 path2 ...
stow_sh::any_has_annotation() {
    local path
    for path in "$@"; do
        if [[ "$path" == *"##"* ]]; then
            return 0
        fi
    done
    return 1
}

# Extract the condition string from an annotated path segment
# The LAST ## in the basename is used (handles nested dirs)
# Usage: stow_sh::extract_conditions "file##os.linux,shell.bash"
#   → prints "os.linux,shell.bash"
stow_sh::extract_conditions() {
    local path="$1"
    local basename="${path##*/}"
    if [[ "$basename" == *"##"* ]]; then
        echo "${basename##*##}"
    fi
}

# Strip ## annotations from a full path
# e.g. foo##os.linux/bar##wm.sway → foo/bar
stow_sh::sanitize_path() {
    local path="$1"
    local sanitized=""
    local token

    IFS='/' read -ra parts <<< "$path"
    for token in "${parts[@]}"; do
        sanitized+="${token%%##*}/"
    done
    sanitized="${sanitized%/}"
    stow_sh::log debug 3 "Sanitized '$path' → '$sanitized'"
    echo "$sanitized"
}

# --- Condition Evaluation ---

# Evaluate all conditions on a candidate path.
# Returns 0 if all conditions pass (file should be deployed), 1 otherwise.
# Usage: stow_sh::check_conditions "file##os.linux,!docker"
stow_sh::check_conditions() {
    local candidate="$1"

    if ! stow_sh::has_annotation "$candidate"; then
        return 0
    fi

    local condition_string
    condition_string="$(stow_sh::extract_conditions "$candidate")"

    if [[ -z "$condition_string" ]]; then
        return 0
    fi

    local -a conditions
    IFS=',' read -r -a conditions <<< "$condition_string"

    local condition expected func cond_type cond_args
    for condition in "${conditions[@]}"; do
        expected=0
        if [[ "$condition" == !* ]]; then
            condition="${condition:1}"
            expected=1
        fi

        IFS='.' read -r -a cond <<< "$condition"
        cond_type="${cond[0]}"
        cond_args=("${cond[@]:1}")
        func="stow_sh::condition::${cond_type}"

        if ! declare -f "$func" > /dev/null 2>&1; then
            stow_sh::log warn "Unknown condition type: '$cond_type' in '$candidate'"
            return 1
        fi

        "$func" "${cond_args[@]}"
        local result=$?

        if [[ "$result" -ne "$expected" ]]; then
            stow_sh::log debug 2 "Condition '${condition}' not met for '$candidate'"
            return 1
        else
            stow_sh::log debug 2 "Condition '${condition}' met for '$candidate'"
        fi
    done
    return 0
}
