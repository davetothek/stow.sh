# SPDX-License-Identifier: MIT
# Copyright (c) 2025 David Kristiansen

# fold.sh — directory folding logic
#
# Determines which directories can be symlinked as a whole instead of
# creating individual file symlinks. Returns the resolved target list:
# fold points for foldable directories, individual files for everything else.
#
# A directory can be folded when:
#   1. Every entry on disk under it is accounted for in the candidate list
#   2. No descendant below it has a ## annotation in its own name
#   3. The directory is not a fold barrier (e.g. an XDG directory)
#
# Completeness is verified by reading the actual filesystem (bash glob)
# at each potential fold point, comparing disk contents against the
# candidate list. This replaces the previous two-list approach that
# required scanning the entire package tree upfront.
#
# Annotation-aware folding: an annotated directory (e.g. dir##cond/) CAN
# be a fold point if all children inside it are clean (no ## in their own
# names). The condition is evaluated at stow time; the symlink target uses
# the annotated name while the link name is sanitized. Only ancestors
# ABOVE the annotated directory are tainted (they would expose the raw
# ## name if folded).
#
# Fold barriers prevent a directory from being symlinked as a whole.
# Children inside a barrier can still be folded normally. Ancestors of
# a barrier are also protected — if .local/share is a barrier, .local
# cannot be folded either (it must remain a real directory).
#
# Depends on: log.sh, conditions.sh (for stow_sh::has_annotation)

# Pure-bash dirname: sets _dir to the parent of $1, or "." if no slash.
# Avoids forking a subprocess — critical for performance in tight loops.
#
# Usage: stow_sh::__parent_of "path/to/file"
#        echo "$_dir"
stow_sh::__parent_of() {
    if [[ "$1" == */* ]]; then
        _dir="${1%/*}"
    else
        _dir="."
    fi
}

# Check if a directory contains any regular files (recursively).
#
# Walks entries via bash glob and recurses into subdirectories. Returns
# as soon as any regular file is found. Symlinks are not counted (they
# are not scanned by find -type f).
#
# Used by __dir_complete to skip directories that are invisible to the
# scan pipeline (e.g. systemd *.target.wants dirs that contain only
# symlinks to system-installed services).
#
# Usage: stow_sh::__dir_has_files /absolute/path/to/dir
# Returns: 0 if at least one regular file exists, 1 otherwise
stow_sh::__dir_has_files() {
    local dir="$1"
    local entry base
    for entry in "$dir"/* "$dir"/.*; do
        [[ ! -e "$entry" && ! -L "$entry" ]] && continue
        base="${entry##*/}"
        [[ "$base" == "." || "$base" == ".." ]] && continue
        [[ -L "$entry" ]] && continue
        # Found a regular file — return immediately
        [[ -f "$entry" ]] && return 0
        # Recurse into subdirectories
        if [[ -d "$entry" ]]; then
            stow_sh::__dir_has_files "$entry" && return 0
        fi
    done
    return 1
}

# Check if a directory on disk is fully covered by the candidate set.
#
# Lists all entries (files and dirs) inside pkg_root/dir via bash glob
# and checks that every entry is either: (a) a file present in the
# candidate set, (b) a subdirectory whose complete subtree is covered
# (represented as a fold point in covered_dirs), or (c) a subdirectory
# that contains no regular files (only symlinks or empty).
#
# Case (c) handles directories like systemd's *.target.wants that
# contain only symlinks created by the system. These directories are
# invisible to scan_package (find -type f) and should not block folding.
#
# Uses bash glob (single readdir syscall, no fork) for each directory.
#
# Usage: stow_sh::__dir_complete dir pkg_root candidate_children_name covered_dirs_name
#   dir — relative path of the directory to check
#   pkg_root — absolute path to the package root
#   candidate_children_name — name of assoc array mapping dir → child count in candidates
#   covered_dirs_name — name of assoc array of dirs known to be fully covered
# Returns: 0 if complete, 1 if any entry on disk is missing from candidates
stow_sh::__dir_complete() {
    local dir="$1"
    local pkg_root="$2"
    local -n _cand_children="$3"
    local -n _covered="$4"

    local abs_dir="$pkg_root/$dir"

    # Count entries on disk (regular files + real dirs, including dotfiles).
    # Symlinks are skipped — scan_package uses find -type f which only
    # emits regular files, so symlinks inside the package are not candidates.
    #
    # Subdirectories that contain no regular files (recursively) are also
    # skipped — they are invisible to scan_package and irrelevant to fold
    # completeness. This handles dirs like systemd's *.target.wants that
    # contain only symlinks created by the system after the initial stow.
    local -i disk_count=0
    local entry base child_rel
    for entry in "$abs_dir"/* "$abs_dir"/.*; do
        # Skip . and .. and non-existent globs
        [[ ! -e "$entry" && ! -L "$entry" ]] && continue
        base="${entry##*/}"
        [[ "$base" == "." || "$base" == ".." ]] && continue
        # Skip symlinks — they are not scanned by find -type f
        [[ -L "$entry" ]] && continue
        # Skip subdirectories that contain no regular files (only symlinks or empty)
        if [[ -d "$entry" ]]; then
            child_rel="$dir/$base"
            if [[ -z "${_covered[$child_rel]+set}" ]]; then
                # Quick check: does this subdir have any regular files?
                if ! stow_sh::__dir_has_files "$entry"; then
                    stow_sh::log debug 3 "Dir '$child_rel' has no regular files — skipping in completeness check"
                    continue
                fi
            fi
        fi
        disk_count+=1
    done

    # Count candidates that are direct children of this dir.
    # candidate_children counts files; covered_dirs counts subdirs that folded.
    local -i cand_count=0
    cand_count="${_cand_children[$dir]:-0}"

    # Also count covered subdirectories as "accounted for"
    for entry in "$abs_dir"/* "$abs_dir"/.*; do
        [[ ! -e "$entry" && ! -L "$entry" ]] && continue
        base="${entry##*/}"
        [[ "$base" == "." || "$base" == ".." ]] && continue
        if [[ -d "$entry" && ! -L "$entry" ]]; then
            child_rel="$dir/$base"
            if [[ -n "${_covered[$child_rel]+set}" ]]; then
                cand_count+=1
            fi
        fi
    done

    if [[ $disk_count -eq $cand_count ]]; then
        return 0
    else
        stow_sh::log debug 3 "Dir '$dir' incomplete: $disk_count on disk, $cand_count accounted for"
        return 1
    fi
}

# Resolve a list of candidates into fold points and individual files.
#
# Takes a single candidate list (post-filter). A directory is a fold
# point if ALL its entries on disk are accounted for in the candidate
# list, none of its descendants have ## annotations, and it is not
# a barrier (or ancestor of a barrier).
#
# Completeness is verified by reading the filesystem at each potential
# fold point (bash glob), comparing disk contents against candidates.
#
# Usage: stow_sh::fold_targets [--barrier=PATH ...] pkg_root -- candidate1 candidate2 ...
# Output: one resolved target per line (fold points + individual files), sorted
stow_sh::fold_targets() {
    local _dir  # scratch variable for __parent_of

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
            stow_sh::__parent_of "$bdir"
            bdir="$_dir"
        done
        shift
    done

    local pkg_root="$1"
    shift

    # Parse candidate list after "--"
    if [[ "$1" != "--" ]]; then
        stow_sh::log error "fold_targets: expected '--' separator after pkg_root, got '$1'"
        return 1
    fi
    shift

    local -a candidates=("$@")

    stow_sh::log debug 3 "Resolving fold targets: ${#candidates[@]} candidates"
    if [[ "$has_barriers" == true ]]; then
        stow_sh::log debug 3 "Active fold barriers: ${!barrier_dirs[*]}"
    fi

    # Build a set of candidates for O(1) lookup
    local -A candidate_set
    local candidate
    for candidate in "${candidates[@]}"; do
        candidate_set["$candidate"]=1
    done

    # Build direct-children-per-dir count: for each candidate file,
    # count it as a direct child of its immediate parent directory.
    local -A dir_child_count
    local dir
    for candidate in "${candidates[@]}"; do
        stow_sh::__parent_of "$candidate"
        dir="$_dir"
        if [[ "$dir" != "." ]]; then
            dir_child_count["$dir"]=$(( ${dir_child_count[$dir]:-0} + 1 ))
        fi
    done

    # --- Taint pass: mark dirs with ## annotated descendants ---
    #
    # An annotated directory (e.g. dir##cond/) CAN be a fold point — its
    # condition is evaluated at stow time and the link name is sanitized.
    # Only ancestors ABOVE the deepest annotated segment are tainted,
    # because folding them would expose the raw ## name.
    #
    # Algorithm: for each annotated candidate, find the deepest ##-bearing
    # path segment. Start tainting from that segment's parent upward.
    local -A tainted_dirs
    for candidate in "${candidates[@]}"; do
        if [[ "$candidate" == *"##"* ]]; then
            # Find the deepest ## segment by walking segments right-to-left.
            local -a segs
            IFS='/' read -r -a segs <<< "$candidate"
            local deepest_idx=-1
            local i
            for (( i = ${#segs[@]} - 1; i >= 0; i-- )); do
                if [[ "${segs[i]}" == *"##"* ]]; then
                    deepest_idx=$i
                    break
                fi
            done

            if [[ $deepest_idx -ge 0 ]]; then
                # Reconstruct path up to the deepest annotated segment
                local annotated_path=""
                for (( i = 0; i <= deepest_idx; i++ )); do
                    if [[ -n "$annotated_path" ]]; then
                        annotated_path+="/${segs[i]}"
                    else
                        annotated_path="${segs[i]}"
                    fi
                done

                stow_sh::log debug 3 "Annotation in '$candidate' (deepest: '${segs[deepest_idx]}') — tainting above '$annotated_path'"

                # Taint from the PARENT of the annotated segment upward.
                # The annotated segment itself is a valid fold candidate.
                stow_sh::__parent_of "$annotated_path"
                dir="$_dir"
                while [[ "$dir" != "." && "$dir" != "/" && "$dir" != "$pkg_root" ]]; do
                    tainted_dirs["$dir"]=1
                    stow_sh::__parent_of "$dir"
                    dir="$_dir"
                done
            fi
        fi
    done

    # --- Build ancestor map: for each candidate, record all ancestor dirs ---
    local -A ancestor_dirs
    for candidate in "${candidates[@]}"; do
        stow_sh::__parent_of "$candidate"
        dir="$_dir"
        while [[ "$dir" != "." && "$dir" != "/" && "$dir" != "$pkg_root" ]]; do
            # Early exit: if already seen, all its ancestors are too
            [[ -n "${ancestor_dirs[$dir]+set}" ]] && break
            ancestor_dirs["$dir"]=1
            stow_sh::__parent_of "$dir"
            dir="$_dir"
        done
    done

    # --- Determine foldable directories (bottom-up with filesystem check) ---
    #
    # Sort ancestor dirs by depth (deepest first) so children are resolved
    # before parents. A directory is foldable if:
    #   - It has candidate descendants (is in ancestor_dirs)
    #   - It is not tainted by annotations
    #   - It is not a barrier
    #   - All entries on disk under it are accounted for (completeness check)
    local -a sorted_dirs
    local d
    # Sort by number of slashes (depth), deepest first
    while IFS= read -r d; do
        sorted_dirs+=("$d")
    done < <(for d in "${!ancestor_dirs[@]}"; do
        local slashes="${d//[^\/]/}"
        printf '%d\t%s\n' "${#slashes}" "$d"
    done | sort -t$'\t' -k1,1rn | cut -f2)

    local -A foldable_dirs
    local -A covered_dirs  # dirs whose entire subtree is accounted for
    for dir in "${sorted_dirs[@]}"; do
        if [[ -n "${tainted_dirs[$dir]+set}" ]]; then
            stow_sh::log debug 3 "Dir '$dir' is tainted — not foldable"
            continue
        fi
        if [[ -n "${barrier_dirs[$dir]+set}" ]]; then
            stow_sh::log debug 3 "Dir '$dir' is a barrier — not foldable"
            continue
        fi
        # Filesystem completeness check
        if stow_sh::__dir_complete "$dir" "$pkg_root" dir_child_count covered_dirs; then
            stow_sh::log debug 3 "Dir '$dir' is foldable (filesystem complete)"
            foldable_dirs["$dir"]=1
            covered_dirs["$dir"]=1
        fi
    done

    # --- Find maximal (shallowest) fold points ---
    # A foldable dir is a maximal fold point if none of its ancestors are foldable.
    # This gives us the shallowest fold points that absorb the most files.
    local -A fold_points
    local parent
    for dir in "${!foldable_dirs[@]}"; do
        stow_sh::__parent_of "$dir"
        parent="$_dir"
        local absorbed=false
        while [[ "$parent" != "." && "$parent" != "/" && "$parent" != "$pkg_root" ]]; do
            if [[ -n "${foldable_dirs[$parent]+set}" ]]; then
                absorbed=true
                break
            fi
            stow_sh::__parent_of "$parent"
            parent="$_dir"
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
        stow_sh::__parent_of "$candidate"
        dir="$_dir"
        local covered=false
        while [[ "$dir" != "." && "$dir" != "/" && "$dir" != "$pkg_root" ]]; do
            if [[ -n "${fold_points[$dir]+set}" ]]; then
                covered=true
                break
            fi
            stow_sh::__parent_of "$dir"
            dir="$_dir"
        done
        if [[ "$covered" == false ]]; then
            stow_sh::log debug 3 "Individual file (not covered by fold): $candidate"
            results+=("$candidate")
        fi
    done

    # Output sorted results
    printf "%s\n" "${results[@]}" | sort
}
