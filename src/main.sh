#!/usr/bin/env bash
# SPDX-License-Identifier: MIT
# Copyright (c) 2025 David Kristiansen

# ======================================================
# stow.sh — A minimal GNU Stow-like utility
# ------------------------------------------------------
# This is the main entrypoint script. It parses arguments,
# sets up paths, resolves stow targets, and performs
# stow/unstow/restow operations.
# ======================================================

set -euo pipefail

ROOT="${STOW_ROOT:-$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)}"
export STOW_ROOT="$ROOT"

# Source all required modules
source "$ROOT/src/version.sh"
source "$ROOT/src/log.sh"
source "$ROOT/src/args.sh"
source "$ROOT/src/conditions.sh"
source "$ROOT/src/filter.sh"
source "$ROOT/src/scan.sh"
source "$ROOT/src/fold.sh"
source "$ROOT/src/xdg.sh"
source "$ROOT/src/stow.sh"

# Load condition plugins (built-ins + user overrides)
stow_sh::load_condition_plugins

# Resolve a single package through the scan → filter → fold pipeline.
#
# Outputs resolved targets (one per line), relative to the package root.
#
# Usage: stow_sh::resolve_package barrier_flags_var pkg_dir
# Args:
#   $1 — name of an array variable holding --barrier=PATH flags
#   $2 — absolute path to the package directory
stow_sh::resolve_package() {
    local barrier_flags_var="$1"
    local pkg_dir
    pkg_dir="$(readlink -f "$2")"

    # Copy barrier flags from the named variable
    local -n _barrier_flags="$barrier_flags_var"

    # Scan
    stow_sh::log debug 2 "Scanning package: '$pkg_dir'"
    local -a pkg_entries
    local scan_output
    if ! scan_output="$(stow_sh::scan_package "$pkg_dir")"; then
        return 1
    fi
    if [[ -n "$scan_output" ]]; then
        mapfile -t pkg_entries <<< "$scan_output"
    else
        pkg_entries=()
    fi

    if [[ ${#pkg_entries[@]} -eq 0 ]]; then
        stow_sh::log debug 1 "No entries found in package '$pkg_dir'"
        return 0
    fi

    local -a relative_entries=()
    local entry
    for entry in "${pkg_entries[@]}"; do
        relative_entries+=("${entry#"$pkg_dir"/}")
    done

    if [[ $(stow_sh::get_debug) -ge 3 ]]; then
        stow_sh::log debug 3 "Raw candidates (${#relative_entries[@]}):"
        local line
        for line in "${relative_entries[@]}"; do
            stow_sh::log debug 3 "  $line"
        done
    fi

    # Filter
    stow_sh::log debug 2 "Filtering candidates..."
    local -a filtered
    mapfile -t filtered < <(printf "%s\n" "${relative_entries[@]}" | stow_sh::filter_candidates)

    if [[ $(stow_sh::get_debug) -ge 3 ]]; then
        stow_sh::log debug 3 "Filtered candidates (${#filtered[@]}):"
        local line
        for line in "${filtered[@]}"; do
            stow_sh::log debug 3 "  $line"
        done
    fi

    # Fold (or pass through if folding disabled)
    local -a resolved
    if ! stow_sh::is_folding_disabled; then
        stow_sh::log debug 2 "Resolving fold targets..."
        mapfile -t resolved < <(stow_sh::fold_targets \
            "${_barrier_flags[@]}" "." \
            -- "${relative_entries[@]}" \
            -- "${filtered[@]}")
    else
        resolved=("${filtered[@]}")
    fi

    # Output resolved targets
    local target
    for target in "${resolved[@]}"; do
        [[ -n "$target" ]] && printf "%s\n" "$target"
    done
}

main() {
    stow_sh::parse_args "$@"
    stow_sh::log_setup "$(stow_sh::get_color_mode)" "$(stow_sh::get_debug)"
    stow_sh::log debug 3 "Raw args: $*"

    stow_sh::log debug 2 "Setting up paths..."
    stow_sh::setup_paths

    local source_dir target_dir
    source_dir="$(stow_sh::get_source)"
    target_dir="$(stow_sh::get_target)"

    # Compute XDG fold barriers relative to the target directory
    local -a barrier_flags=()
    if stow_sh::is_xdg_mode; then
        local -a xdg_barriers
        mapfile -t xdg_barriers < <(stow_sh::compute_xdg_barriers "$target_dir")
        local b
        for b in "${xdg_barriers[@]}"; do
            [[ -n "$b" ]] && barrier_flags+=("--barrier=$b")
        done
        if [[ ${#barrier_flags[@]} -gt 0 ]]; then
            stow_sh::log debug 1 "XDG fold barriers: ${xdg_barriers[*]}"
        fi
    fi

    # Gather package lists for each operation
    local -a stow_packages unstow_packages restow_packages
    mapfile -t stow_packages < <(stow_sh::get_stow_packages)
    mapfile -t unstow_packages < <(stow_sh::get_unstow_packages)
    mapfile -t restow_packages < <(stow_sh::get_restow_packages)

    # Count non-empty package names
    local total=0
    local _p
    for _p in "${stow_packages[@]}" "${unstow_packages[@]}" "${restow_packages[@]}"; do
        [[ -n "$_p" ]] && total=$((total + 1))
    done
    if [[ "$total" -eq 0 ]]; then
        stow_sh::log error "No stow targets provided."
        stow_sh::usage 1
    fi

    local had_error=false

    # --- Restow: unstow then stow ---
    local pkg resolve_output
    for pkg in "${restow_packages[@]}"; do
        [[ -z "$pkg" ]] && continue
        local pkg_dir
        pkg_dir="$(readlink -f "$source_dir/$pkg")"
        stow_sh::log info "Restowing package: $pkg"

        local -a resolved
        if resolve_output="$(stow_sh::resolve_package barrier_flags "$pkg_dir")"; then
            if [[ -n "$resolve_output" ]]; then
                mapfile -t resolved <<< "$resolve_output"
            else
                resolved=()
            fi
        else
            had_error=true
            continue
        fi

        stow_sh::log debug 1 "Resolved ${#resolved[@]} targets for restow of '$pkg'"

        stow_sh::unstow_package "$pkg_dir" "$target_dir" "${resolved[@]}" || had_error=true
        stow_sh::stow_package "$pkg_dir" "$target_dir" "${resolved[@]}" || had_error=true
    done

    # --- Unstow ---
    for pkg in "${unstow_packages[@]}"; do
        [[ -z "$pkg" ]] && continue
        local pkg_dir
        pkg_dir="$(readlink -f "$source_dir/$pkg")"
        stow_sh::log info "Unstowing package: $pkg"

        local -a resolved
        if resolve_output="$(stow_sh::resolve_package barrier_flags "$pkg_dir")"; then
            if [[ -n "$resolve_output" ]]; then
                mapfile -t resolved <<< "$resolve_output"
            else
                resolved=()
            fi
        else
            had_error=true
            continue
        fi

        stow_sh::log debug 1 "Resolved ${#resolved[@]} targets for unstow of '$pkg'"

        stow_sh::unstow_package "$pkg_dir" "$target_dir" "${resolved[@]}" || had_error=true
    done

    # --- Stow ---
    for pkg in "${stow_packages[@]}"; do
        [[ -z "$pkg" ]] && continue
        local pkg_dir
        pkg_dir="$(readlink -f "$source_dir/$pkg")"
        stow_sh::log info "Stowing package: $pkg"

        local -a resolved
        if resolve_output="$(stow_sh::resolve_package barrier_flags "$pkg_dir")"; then
            if [[ -n "$resolve_output" ]]; then
                mapfile -t resolved <<< "$resolve_output"
            else
                resolved=()
            fi
        else
            had_error=true
            continue
        fi

        stow_sh::log debug 1 "Resolved ${#resolved[@]} targets for stow of '$pkg'"

        stow_sh::stow_package "$pkg_dir" "$target_dir" "${resolved[@]}" || had_error=true
    done

    if [[ "$had_error" == true ]]; then
        stow_sh::log error "Some operations failed"
        exit 1
    fi

    stow_sh::log debug 1 "All operations completed successfully"
}

main "$@"
