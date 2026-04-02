#!/usr/bin/env bash
# SPDX-License-Identifier: MIT
# Copyright (c) 2025 David Kristiansen

# stow.sh — stow and unstow operations
#
# Creates and removes symlinks for resolved targets. Each target is either
# a fold point (directory symlink) or an individual file symlink.
#
# Stow: for each target, evaluate ## conditions, strip annotations from
# the link name, create parent directories, and create the symlink.
#
# Unstow: for each target, verify the symlink points into the package,
# remove it, and clean up empty parent directories.
#
# Depends on: log.sh, args.sh (is_dry_run, is_force, is_adopt),
#             conditions.sh (check_conditions, sanitize_path, has_annotation)

# Stow resolved targets from a package into the target directory.
#
# Each entry in resolved_targets is a relative path from pkg_dir. It may be
# a directory (fold point) or a file. Annotated entries (##) have conditions
# evaluated and annotations stripped from the link name.
#
# Usage: stow_sh::stow_package pkg_dir target_dir resolved_target1 resolved_target2 ...
# Returns: 0 on success, 1 if any target had a conflict that couldn't be resolved
stow_sh::stow_package() {
    local pkg_dir="$1"
    local target_dir="$2"
    shift 2
    local -a resolved_targets=("$@")

    local had_error=false

    stow_sh::log debug 1 "Stowing ${#resolved_targets[@]} targets from '$pkg_dir' into '$target_dir'"

    local target
    for target in "${resolved_targets[@]}"; do
        [[ -z "$target" ]] && continue

        # Evaluate ## conditions — skip target if conditions fail
        if stow_sh::has_annotation "$target"; then
            if ! stow_sh::check_conditions "$target"; then
                stow_sh::log info "Skipping '$target' — conditions not met"
                continue
            fi
        fi

        # Compute source (what the symlink points to) and link path
        local source_path="$pkg_dir/$target"
        local link_rel
        if stow_sh::has_annotation "$target"; then
            link_rel="$(stow_sh::sanitize_path "$target")"
        else
            link_rel="$target"
        fi
        local link_path="$target_dir/$link_rel"

        stow_sh::__create_link "$source_path" "$link_path" "$pkg_dir" || had_error=true
    done

    if [[ "$had_error" == true ]]; then
        return 1
    fi
    return 0
}

# Unstow resolved targets — remove symlinks that point into the package.
#
# Usage: stow_sh::unstow_package pkg_dir target_dir resolved_target1 resolved_target2 ...
# Returns: 0 on success, 1 if any target had an error
stow_sh::unstow_package() {
    local pkg_dir="$1"
    local target_dir="$2"
    shift 2
    local -a resolved_targets=("$@")

    local had_error=false

    stow_sh::log debug 1 "Unstowing ${#resolved_targets[@]} targets from '$pkg_dir' out of '$target_dir'"

    local target
    for target in "${resolved_targets[@]}"; do
        [[ -z "$target" ]] && continue

        # Compute the link path (with annotation stripping)
        local link_rel
        if stow_sh::has_annotation "$target"; then
            link_rel="$(stow_sh::sanitize_path "$target")"
        else
            link_rel="$target"
        fi
        local link_path="$target_dir/$link_rel"
        local source_path="$pkg_dir/$target"

        stow_sh::__remove_link "$link_path" "$source_path" "$target_dir" || had_error=true
    done

    if [[ "$had_error" == true ]]; then
        return 1
    fi
    return 0
}

# --- Internal helpers ---

# Create a single symlink, handling conflicts.
# Usage: stow_sh::__create_link source_path link_path pkg_dir
stow_sh::__create_link() {
    local source_path="$1"
    local link_path="$2"
    local pkg_dir="$3"

    # Verify source exists
    if [[ ! -e "$source_path" ]]; then
        stow_sh::log error "Source does not exist: '$source_path'"
        return 1
    fi

    local link_dir
    link_dir="$(dirname "$link_path")"

    # Check for conflicts at the link path
    if [[ -L "$link_path" ]]; then
        # It's a symlink — check where it points
        local existing_target
        existing_target="$(readlink -f "$link_path")"
        local canonical_source
        canonical_source="$(readlink -f "$source_path")"

        if [[ "$existing_target" == "$canonical_source" ]]; then
            stow_sh::log debug 1 "Already stowed: '$link_path'"
            return 0
        fi

        # Points elsewhere — conflict
        if stow_sh::is_force; then
            if stow_sh::is_dry_run; then
                stow_sh::log info "WOULD remove conflicting symlink: '$link_path' -> '$(readlink "$link_path")'"
                stow_sh::log info "WOULD link: '$link_path' -> '$source_path'"
                return 0
            fi
            stow_sh::log info "Removing conflicting symlink: '$link_path'"
            rm "$link_path"
        else
            stow_sh::log error "Conflict: '$link_path' is a symlink to '$(readlink "$link_path")' (use --force to override)"
            return 1
        fi
    elif [[ -e "$link_path" ]]; then
        # Exists as a real file or directory
        if stow_sh::is_adopt; then
            if stow_sh::is_dry_run; then
                stow_sh::log info "WOULD adopt: '$link_path' -> '$source_path'"
                stow_sh::log info "WOULD link: '$link_path' -> '$source_path'"
                return 0
            fi
            stow_sh::log info "Adopting: '$link_path' -> '$source_path'"
            # Move the existing file into the package, then symlink
            local source_dir
            source_dir="$(dirname "$source_path")"
            mkdir -p "$source_dir"
            mv "$link_path" "$source_path"
        elif stow_sh::is_force; then
            if stow_sh::is_dry_run; then
                stow_sh::log info "WOULD remove conflicting path: '$link_path'"
                stow_sh::log info "WOULD link: '$link_path' -> '$source_path'"
                return 0
            fi
            stow_sh::log info "Removing conflicting path: '$link_path'"
            rm -rf "$link_path"
        else
            stow_sh::log error "Conflict: '$link_path' already exists (use --adopt or --force)"
            return 1
        fi
    fi

    # Create parent directories if needed
    if [[ ! -d "$link_dir" ]]; then
        if stow_sh::is_dry_run; then
            stow_sh::log info "WOULD mkdir -p '$link_dir'"
        else
            stow_sh::log debug 2 "Creating directory: '$link_dir'"
            mkdir -p "$link_dir"
        fi
    fi

    # Compute relative path from link's parent directory to source
    local rel_source
    rel_source="$(realpath -m --relative-to="$link_dir" "$source_path")"

    # Create the symlink
    if stow_sh::is_dry_run; then
        stow_sh::log info "WOULD link: '$link_path' -> '$rel_source'"
    else
        stow_sh::log info "Linking: '$link_path' -> '$rel_source'"
        ln -s "$rel_source" "$link_path"
    fi
    return 0
}

# Remove a single symlink if it points to the expected source.
# Cleans up empty parent directories up to target_dir.
# Usage: stow_sh::__remove_link link_path expected_source target_dir
stow_sh::__remove_link() {
    local link_path="$1"
    local expected_source="$2"
    local target_dir="$3"

    if [[ ! -L "$link_path" ]]; then
        if [[ ! -e "$link_path" ]]; then
            stow_sh::log debug 1 "Already unstowed (does not exist): '$link_path'"
            return 0
        fi
        stow_sh::log error "Cannot unstow: '$link_path' is not a symlink"
        return 1
    fi

    # Verify symlink points to the expected source
    local actual_target
    actual_target="$(readlink -f "$link_path")"
    local canonical_source
    canonical_source="$(readlink -f "$expected_source")"

    if [[ "$actual_target" != "$canonical_source" ]]; then
        stow_sh::log error "Cannot unstow: '$link_path' points to '$actual_target', not '$canonical_source'"
        return 1
    fi

    # Remove the symlink
    if stow_sh::is_dry_run; then
        stow_sh::log info "WOULD unlink: '$link_path'"
    else
        stow_sh::log info "Unlinking: '$link_path'"
        rm "$link_path"
    fi

    # Clean up empty parent directories (up to target_dir, exclusive)
    if ! stow_sh::is_dry_run; then
        local dir
        dir="$(dirname "$link_path")"
        local canonical_target_dir
        canonical_target_dir="$(readlink -f "$target_dir")"
        while [[ "$dir" != "$canonical_target_dir" && "$dir" != "/" ]]; do
            if [[ -d "$dir" ]] && _stow_sh__is_dir_empty "$dir"; then
                stow_sh::log debug 2 "Removing empty directory: '$dir'"
                rmdir "$dir"
                dir="$(dirname "$dir")"
            else
                break
            fi
        done
    fi

    return 0
}

# Check if a directory is empty
_stow_sh__is_dir_empty() {
    local dir="$1"
    [[ -d "$dir" ]] && [[ -z "$(ls -A "$dir" 2>/dev/null)" ]]
}
