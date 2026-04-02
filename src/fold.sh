# SPDX-License-Identifier: MIT
# Copyright (c) 2025 David Kristiansen

# fold.sh — directory folding logic
#
# Determines which directories can be symlinked as a whole instead of
# creating individual file symlinks. Returns the resolved target list:
# fold points for foldable directories, individual files for everything else.
#
# A directory can be folded when:
#   1. All its descendants survived filtering (none were excluded)
#   2. No descendant has a ## annotation (annotations mean source/target
#      filenames differ, so a directory symlink would leak raw ## names)
#   3. The directory is not a fold barrier (e.g. an XDG directory)
#
# Fold barriers prevent a directory from being symlinked as a whole.
# Children inside a barrier can still be folded normally. Ancestors of
# a barrier are also protected — if .local/share is a barrier, .local
# cannot be folded either (it must remain a real directory).
#
# Depends on: log.sh, conditions.sh (for stow_sh::has_annotation)

# Resolve a list of candidates into fold points and individual files.
#
# Takes two lists separated by "--": all scanned entries (pre-filter) and
# candidates (post-filter). A directory is a fold point if ALL its scanned
# descendants survived filtering, none have ## annotations, and it is not
# a barrier (or ancestor of a barrier). Files not covered by any fold
# point are returned as individual entries.
#
# Usage: stow_sh::fold_targets [--barrier=PATH ...] pkg_root -- all... -- candidates...
# Output: one resolved target per line (fold points + individual files), sorted
stow_sh::fold_targets() {
    # Parse --barrier flags
    local -A barrier_dirs
    local has_barriers=false
    while [[ $# -gt 0 && "$1" == --barrier=* ]]; do
        local barrier="${1#--barrier=}"
        has_barriers=true
        stow_sh::log debug 2 "Fold barrier: '$barrier'"
        # Mark the barrier and all its ancestors as protected
        local bdir="$barrier"
        while [[ "$bdir" != "." && "$bdir" != "/" ]]; do
            barrier_dirs["$bdir"]=1
            bdir="$(dirname "$bdir")"
        done
        shift
    done

    local pkg_root="$1"
    shift

    # Parse two lists separated by "--"
    # First "--" separates pkg_root from all_entries
    if [[ "$1" != "--" ]]; then
        stow_sh::log error "fold_targets: expected '--' separator after pkg_root, got '$1'"
        return 1
    fi
    shift

    local -a all_entries=()
    while [[ $# -gt 0 && "$1" != "--" ]]; do
        all_entries+=("$1")
        shift
    done

    if [[ $# -eq 0 ]]; then
        stow_sh::log error "fold_targets: expected second '--' separator"
        return 1
    fi
    shift  # consume second "--"

    local -a candidates=("$@")

    stow_sh::log debug 3 "Resolving fold targets: ${#all_entries[@]} scanned, ${#candidates[@]} candidates"
    if [[ "$has_barriers" == true ]]; then
        stow_sh::log debug 3 "Active fold barriers: ${!barrier_dirs[*]}"
    fi

    # Build a set of candidates for O(1) lookup
    local -A candidate_set
    local candidate
    for candidate in "${candidates[@]}"; do
        candidate_set["$candidate"]=1
    done

    # --- Taint pass 1: mark dirs with ## annotated descendants ---
    local -A tainted_dirs
    local dir
    for candidate in "${candidates[@]}"; do
        if stow_sh::has_annotation "$candidate"; then
            stow_sh::log debug 3 "Annotation found in '$candidate' — tainting ancestors"
            dir="$(dirname "$candidate")"
            while [[ "$dir" != "." && "$dir" != "/" && "$dir" != "$pkg_root" ]]; do
                tainted_dirs["$dir"]=1
                dir="$(dirname "$dir")"
            done
        fi
    done

    # --- Taint pass 2: mark dirs with excluded descendants ---
    # An entry is "excluded" if it's in all_entries but not in candidates.
    # Any ancestor of an excluded entry cannot be folded.
    local entry
    for entry in "${all_entries[@]}"; do
        if [[ -z "${candidate_set[$entry]+set}" ]]; then
            stow_sh::log debug 3 "Excluded entry '$entry' — tainting ancestors"
            dir="$(dirname "$entry")"
            while [[ "$dir" != "." && "$dir" != "/" && "$dir" != "$pkg_root" ]]; do
                tainted_dirs["$dir"]=1
                dir="$(dirname "$dir")"
            done
        fi
    done

    # --- Build ancestor map: for each candidate, record all ancestor dirs ---
    local -A ancestor_dirs
    for candidate in "${candidates[@]}"; do
        dir="$(dirname "$candidate")"
        while [[ "$dir" != "." && "$dir" != "/" && "$dir" != "$pkg_root" ]]; do
            ancestor_dirs["$dir"]=1
            dir="$(dirname "$dir")"
        done
    done

    # --- Determine foldable directories ---
    # A directory is foldable if:
    #   - It has candidate descendants (is in ancestor_dirs)
    #   - It is not tainted
    #   - It is not a barrier or ancestor of a barrier
    local -A foldable_dirs
    for dir in "${!ancestor_dirs[@]}"; do
        if [[ -n "${tainted_dirs[$dir]+set}" ]]; then
            stow_sh::log debug 3 "Dir '$dir' is tainted — not foldable"
            continue
        fi
        if [[ -n "${barrier_dirs[$dir]+set}" ]]; then
            stow_sh::log debug 3 "Dir '$dir' is a barrier — not foldable"
            continue
        fi
        stow_sh::log debug 3 "Dir '$dir' is foldable"
        foldable_dirs["$dir"]=1
    done

    # --- Find maximal (shallowest) fold points ---
    # A foldable dir is a maximal fold point if none of its ancestors are foldable.
    # This gives us the shallowest fold points that absorb the most files.
    local -A fold_points
    for dir in "${!foldable_dirs[@]}"; do
        local parent
        parent="$(dirname "$dir")"
        local absorbed=false
        while [[ "$parent" != "." && "$parent" != "/" && "$parent" != "$pkg_root" ]]; do
            if [[ -n "${foldable_dirs[$parent]+set}" ]]; then
                absorbed=true
                break
            fi
            parent="$(dirname "$parent")"
        done
        if [[ "$absorbed" == false ]]; then
            stow_sh::log debug 3 "Maximal fold point: $dir"
            fold_points["$dir"]=1
        fi
    done

    # --- Collect results: fold points + uncovered individual files ---
    local -a results=()

    # Add fold points
    for dir in "${!fold_points[@]}"; do
        results+=("$dir")
    done

    # For each candidate, check if it's covered by a fold point
    for candidate in "${candidates[@]}"; do
        dir="$(dirname "$candidate")"
        local covered=false
        while [[ "$dir" != "." && "$dir" != "/" && "$dir" != "$pkg_root" ]]; do
            if [[ -n "${fold_points[$dir]+set}" ]]; then
                covered=true
                break
            fi
            dir="$(dirname "$dir")"
        done
        if [[ "$covered" == false ]]; then
            stow_sh::log debug 3 "Individual file (not covered by fold): $candidate"
            results+=("$candidate")
        fi
    done

    # Output sorted results
    printf "%s\n" "${results[@]}" | sort
}
