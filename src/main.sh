#!/usr/bin/env bash
# SPDX-License-Identifier: MIT
# Copyright (c) 2025 David Kristiansen

# main.sh — orchestrator for the stow.sh pipeline
#
# Parses arguments, sets up paths, computes XDG fold barriers, and runs
# each package through the scan → filter → fold → stow/unstow pipeline.
# This is the main entrypoint script executed by bin/stow.sh.
#
# Depends on: version.sh, log.sh, args.sh, conditions.sh, filter.sh,
#             scan.sh, fold.sh, xdg.sh, stow.sh

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
source "$ROOT/src/dotfiles.sh"
source "$ROOT/src/stow.sh"

# Load condition plugins (built-ins + user overrides)
stow_sh::load_condition_plugins

# Resolve a single package through the scan → filter → fold pipeline.
#
# Outputs resolved targets (one per line), relative to the package root.
#
# Usage: stow_sh::resolve_package [--no-fold] barrier_flags_var pkg_dir
#   --no-fold — skip the fold phase (used for unstow)
#   barrier_flags_var — name of an array variable holding --barrier=PATH flags
#   pkg_dir — absolute path to the package directory
# Output: one resolved target per line
stow_sh::resolve_package() {
    local skip_fold=false
    if [[ "${1:-}" == "--no-fold" ]]; then
        skip_fold=true
        shift
    fi

    local barrier_flags_var="$1"
    local pkg_dir
    pkg_dir="$(readlink -f "$2")"

    # Copy barrier flags from the named variable
    local -n _barrier_flags="$barrier_flags_var"

    # Load .stowignore for this package (reset from previous package)
    stow_sh::reset_stowignore
    stow_sh::load_stowignore "$pkg_dir/.stowignore"

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

    # Fold (or pass through if folding disabled or skipped for unstow)
    local -a resolved
    if [[ "$skip_fold" == false ]] && ! stow_sh::is_folding_disabled; then
        stow_sh::log debug 2 "Resolving fold targets..."
        mapfile -t resolved < <(stow_sh::fold_targets \
            "${_barrier_flags[@]}" "$pkg_dir" \
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

# Top-level entry point: parse → setup → resolve → stow/unstow/restow.
# Run every stow/unstow/restow operation once over the resolved package
# lists. Reads package lists via the args getters and fold barriers from the
# global _stow_sh_barrier_flags array, so it is self-contained and can be
# called twice (once for the conflict pre-flight, once to apply).
#
# Honors dry-run and pre-flight modes via the predicates in __create_link /
# __remove_link, so it never mutates the filesystem while either is set.
#
# Usage: stow_sh::__apply_operations target_dir
# Returns: 0 if all operations succeeded, 1 if any had an unresolved conflict
stow_sh::__apply_operations() {
    local target_dir="$1"

    local -a stow_packages unstow_packages restow_packages
    mapfile -t stow_packages < <(stow_sh::get_stow_packages)
    mapfile -t unstow_packages < <(stow_sh::get_unstow_packages)
    mapfile -t restow_packages < <(stow_sh::get_restow_packages)

    local had_error=false

    # --- Restow: unstow then stow ---
    local pkg_dir resolve_output
    for pkg_dir in "${restow_packages[@]}"; do
        [[ -z "$pkg_dir" ]] && continue
        local pkg="${pkg_dir##*/}"
        stow_sh::log debug 1 "Restowing package: $pkg"

        # Unstow phase: skip folding (let __remove_link handle filesystem state)
        local -a unstow_resolved
        if resolve_output="$(stow_sh::resolve_package --no-fold _stow_sh_barrier_flags "$pkg_dir")"; then
            if [[ -n "$resolve_output" ]]; then
                mapfile -t unstow_resolved <<< "$resolve_output"
            else
                unstow_resolved=()
            fi
        else
            had_error=true
            continue
        fi

        # Stow phase: use fold logic for optimal symlinks
        local -a stow_resolved
        if resolve_output="$(stow_sh::resolve_package _stow_sh_barrier_flags "$pkg_dir")"; then
            if [[ -n "$resolve_output" ]]; then
                mapfile -t stow_resolved <<< "$resolve_output"
            else
                stow_resolved=()
            fi
        else
            had_error=true
            continue
        fi

        stow_sh::log debug 1 "Resolved ${#unstow_resolved[@]} unstow + ${#stow_resolved[@]} stow targets for restow of '$pkg'"
        stow_sh::report "+" "restow $pkg (${#stow_resolved[@]} targets)"

        stow_sh::unstow_package "$pkg_dir" "$target_dir" "${unstow_resolved[@]}" || had_error=true
        stow_sh::stow_package "$pkg_dir" "$target_dir" "${stow_resolved[@]}" || had_error=true
    done

    # --- Unstow ---
    for pkg_dir in "${unstow_packages[@]}"; do
        [[ -z "$pkg_dir" ]] && continue
        local pkg="${pkg_dir##*/}"
        stow_sh::log debug 1 "Unstowing package: $pkg"

        local -a resolved
        if resolve_output="$(stow_sh::resolve_package --no-fold _stow_sh_barrier_flags "$pkg_dir")"; then
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
        stow_sh::report "-" "unstow $pkg (${#resolved[@]} targets)"

        stow_sh::unstow_package "$pkg_dir" "$target_dir" "${resolved[@]}" || had_error=true
    done

    # --- Stow ---
    for pkg_dir in "${stow_packages[@]}"; do
        [[ -z "$pkg_dir" ]] && continue
        local pkg="${pkg_dir##*/}"
        stow_sh::log debug 1 "Stowing package: $pkg"

        local -a resolved
        if resolve_output="$(stow_sh::resolve_package _stow_sh_barrier_flags "$pkg_dir")"; then
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
        stow_sh::report "+" "stow $pkg (${#resolved[@]} targets)"

        stow_sh::stow_package "$pkg_dir" "$target_dir" "${resolved[@]}" || had_error=true
    done

    [[ "$had_error" == true ]] && return 1
    return 0
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

    # Compute XDG fold barriers relative to the target directory. Global so
    # __apply_operations can pass them to resolve_package by name (nameref).
    declare -ga _stow_sh_barrier_flags=()
    if stow_sh::is_xdg_mode; then
        local -a xdg_barriers
        mapfile -t xdg_barriers < <(stow_sh::compute_xdg_barriers "$target_dir")
        local b
        for b in "${xdg_barriers[@]}"; do
            # Barriers are target-relative (e.g. ".config"); map them onto the
            # package directory that holds them ("dot-config") under --dotfiles.
            [[ -n "$b" ]] && _stow_sh_barrier_flags+=("--barrier=$(stow_sh::dotfiles_untranslate "$b")")
        done
        if [[ ${#_stow_sh_barrier_flags[@]} -gt 0 ]]; then
            stow_sh::log debug 1 "XDG fold barriers: ${xdg_barriers[*]}"
        fi
    fi

    # Count non-empty package names across all operations
    local -a all_packages
    mapfile -t all_packages < <(
        stow_sh::get_stow_packages
        stow_sh::get_unstow_packages
        stow_sh::get_restow_packages
    )
    local total=0 _p
    for _p in "${all_packages[@]}"; do
        [[ -n "$_p" ]] && total=$((total + 1))
    done
    if [[ "$total" -eq 0 ]]; then
        stow_sh::log error "No stow targets provided."
        stow_sh::usage 1
    fi

    # User-requested dry-run: show what would happen, never apply.
    if stow_sh::is_dry_run; then
        if ! stow_sh::__apply_operations "$target_dir"; then
            stow_sh::log error "Some operations would fail"
            exit 1
        fi
        stow_sh::log debug 1 "Dry-run complete"
        return 0
    fi

    # Phase 1 — conflict pre-flight. Run every operation mutation-free; if any
    # unresolved conflict exists, abort with ZERO changes. This is the
    # all-or-nothing guarantee GNU Stow provides: never leave a half-applied
    # tree. Conflicts resolvable by --force/--adopt are not flagged here.
    _stow_sh_preflight=true
    _stow_sh_dry_run=true
    local preflight_ok=true
    stow_sh::__apply_operations "$target_dir" || preflight_ok=false
    _stow_sh_dry_run=false
    _stow_sh_preflight=false

    if [[ "$preflight_ok" == false ]]; then
        stow_sh::log error "Aborting: conflicts detected — no changes made. Resolve the conflicts above, or re-run with --force (overwrite) or --adopt (absorb existing files)."
        exit 1
    fi

    # Phase 2 — apply for real. A failure here is unexpected (e.g. a concurrent
    # filesystem change between the two passes) but still reported loudly.
    if ! stow_sh::__apply_operations "$target_dir"; then
        stow_sh::log error "Some operations failed"
        exit 1
    fi

    stow_sh::log debug 1 "All operations completed successfully"
}

main "$@"
