# SPDX-License-Identifier: MIT
# Copyright (c) 2025 David Kristiansen

# xdg.sh — XDG-aware fold barrier detection
#
# When XDG_* environment variables are set, their directories become fold
# barriers. Folding stops before symlinking an XDG directory as a whole —
# the XDG directory itself must be a real directory, but children inside
# it can still be folded normally.
#
# Only environment variables that are actually set are considered.
# No paths are hardcoded — barriers are derived purely from XDG_* values.
#
# Depends on: log.sh

# The XDG environment variables we check for fold barriers.
# Each value is resolved to an absolute path and compared to the stow target.
# We check all *_HOME vars — these are single directories.
# XDG_DATA_DIRS/XDG_CONFIG_DIRS are colon-separated search paths (system dirs)
# and are not relevant for stow targets, so they are excluded.
readonly _STOW_SH_XDG_VARS=(
    XDG_CONFIG_HOME
    XDG_DATA_HOME
    XDG_STATE_HOME
    XDG_CACHE_HOME
    XDG_BIN_HOME
    XDG_RUNTIME_DIR
)

# Compute XDG fold barrier paths relative to the stow target directory.
#
# For each set XDG_* variable, if its value is a subdirectory of the target,
# output the relative path from target to that directory.
#
# Usage: stow_sh::compute_xdg_barriers /absolute/target
# Output: one relative barrier path per line (e.g. ".config", ".local/share")
stow_sh::compute_xdg_barriers() {
    local target="$1"

    # Normalize target to absolute path with trailing slash for prefix matching
    target="$(realpath -m "$target")"
    local target_prefix="$target/"

    local var xdg_path rel
    for var in "${_STOW_SH_XDG_VARS[@]}"; do
        xdg_path="${!var:-}"
        [[ -n "$xdg_path" ]] || continue

        # Normalize the XDG path
        xdg_path="$(realpath -m "$xdg_path")"

        # Check if XDG path is under the target directory
        if [[ "$xdg_path" == "$target_prefix"* ]]; then
            rel="${xdg_path#"$target_prefix"}"
            stow_sh::log debug 2 "XDG barrier: $var=$xdg_path → relative '$rel'"
            echo "$rel"
        else
            stow_sh::log debug 3 "XDG skip: $var=$xdg_path is not under target $target"
        fi
    done
}
