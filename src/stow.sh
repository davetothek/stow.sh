# SPDX-License-Identifier: MIT
# Copyright (c) 2025 David Kristiansen

# shellcheck shell=bash

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
# Depends on: log.sh, args.sh (is_dry_run, is_force, is_adopt, is_dotfiles),
#             conditions.sh (check_conditions, sanitize_path, has_annotation),
#             dotfiles.sh (dotfiles_translate)

# Cache of symlink contents (link_path → readlink output). The conflict
# pre-flight and the apply pass read the same links; caching halves the
# readlink forks. Entries are invalidated whenever a link is removed.
declare -gA _stow_sh_readlink_cache=()

# Link paths this run plans to create, and their ancestor directories.
# stow_package builds both sets again for each package. __create_link reads
# them to tell a planned fold point from a stale one. __unfold_stale_walk
# reads them to tell package content from application state.
declare -gA _stow_sh_planned_links=()
declare -gA _stow_sh_planned_under=()

# Stale fold points that this pass handled, mapped to their outcome:
# "unfolded", "kept", or "error". One fold point can cover many files, and a
# dry-run pass does not remove it. Each file below it therefore finds it
# again. The map keeps the report to one line and repeats the outcome.
declare -gA _stow_sh_unfolded_folds=()

# Files that git tracks below the current stale fold point, and their parent
# directories. __unfold_stale fills the set, and __unfold_stale_walk reads
# it. Eviction refuses a tracked file — see __unfold_stale.
declare -gA _stow_sh_evict_tracked=()

# True after __unfold_stale keeps a stale fold point in place, because
# eviction is off or the package is outside git. The caller then treats the
# files below the fold point as already stowed.
declare -g _stow_sh_fold_kept=false

# True after an operation moves a file into or out of a package directory.
# main.sh then drops the cached resolution of that package.
declare -g _stow_sh_pkg_mutated=false

# Read a symlink's content (raw, not canonicalized) through the cache.
# Sets _stow_sh_readlink.
#
# Usage: stow_sh::__readlink_cached /path/to/symlink
stow_sh::__readlink_cached() {
    local p="$1"
    if [[ -n "${_stow_sh_readlink_cache[$p]+x}" ]]; then
        _stow_sh_readlink="${_stow_sh_readlink_cache[$p]}"
    else
        _stow_sh_readlink="$(readlink "$p")"
        _stow_sh_readlink_cache["$p"]="$_stow_sh_readlink"
    fi
}

# Log "Already stowed" at debug level only.
#
# This is not reported to stdout — it's not actionable information.
# The user cares about what changed, not what was already fine.
#
# Usage: stow_sh::__log_already_stowed "description"
stow_sh::__log_already_stowed() {
    stow_sh::log debug 1 "Already stowed: $1"
}

# Pure-bash dirname: sets _stow_sh_dir to the parent of $1.
#
# Handles absolute and relative paths: "/a/b" → "/a", "/a" → "/", "a/b" → "a",
# "a" → ".". Avoids forking a subprocess — critical in per-target hot loops.
#
# Usage: stow_sh::__dir_of "/path/to/file"
#        echo "$_stow_sh_dir"
stow_sh::__dir_of() {
    local p="$1"
    if [[ "$p" == */* ]]; then
        p="${p%/*}"
        _stow_sh_dir="${p:-/}"
    else
        _stow_sh_dir="."
    fi
}

# Pure-bash relative path: sets _stow_sh_rel to the path of $2 relative to
# directory $1. Equivalent to `realpath -m --relative-to="$1" "$2"` when both
# inputs are canonical absolute paths (no symlink components, no . or ..).
#
# Callers must fall back to realpath when a path component may be a symlink
# (textual and canonical parents diverge there).
#
# Usage: stow_sh::__relpath "/home/u/target/.config" "/home/u/pkgs/big/file"
#        echo "$_stow_sh_rel"   # → "../../pkgs/big/file"
stow_sh::__relpath() {
    local from="${1%/}" to="${2%/}"
    local up=""
    while [[ "$to" != "$from" && "$to" != "$from"/* ]]; do
        up+="../"
        from="${from%/*}"
        [[ -z "$from" ]] && from="/"
    done
    local rest="${to#"$from"}"
    rest="${rest#/}"
    local rel="${up}${rest}"
    _stow_sh_rel="${rel:-.}"
}

# Compute the link path (relative to the target dir) for a resolved target.
# Sets _stow_sh_link_rel (var-returning to avoid a subshell per target).
#
# Strips ## annotations, then applies --dotfiles translation (dot- → .).
# Both steps are no-ops when not applicable, so this is safe for every target.
#
# Usage: stow_sh::__link_rel "dot-config##os.linux/init.lua"
#        echo "$_stow_sh_link_rel"
stow_sh::__link_rel() {
    local target="$1"
    _stow_sh_link_rel="$target"
    if stow_sh::has_annotation "$target"; then
        stow_sh::__sanitize_path_var "$target"
        # shellcheck disable=SC2154  # set by __sanitize_path_var (conditions.sh)
        _stow_sh_link_rel="$_stow_sh_sanitized"
    fi
    stow_sh::__dotfiles_translate_var "$_stow_sh_link_rel"
    # shellcheck disable=SC2154  # set by __dotfiles_translate_var (dotfiles.sh)
    _stow_sh_link_rel="$_stow_sh_dtrans"
}

# Stow resolved targets from a package into the target directory.
#
# Each entry in resolved_targets is a relative path from pkg_dir. It may
# be a directory (fold point) or a file. Annotated entries (##) have
# conditions evaluated and annotations stripped from the link name.
#
# Usage: stow_sh::stow_package pkg_dir target_dir target1 target2 ...
# Returns: 0 on success, 1 if any target had a conflict that couldn't be resolved
stow_sh::stow_package() {
    local pkg_dir="$1"
    local target_dir="$2"
    shift 2
    local -a resolved_targets=("$@")

    stow_sh::log debug 1 "Stowing ${#resolved_targets[@]} targets from '$pkg_dir' into '$target_dir'"

    # Record the plan before the run creates a link. The run then checks each
    # target against the full plan, not against the targets seen so far. The
    # plan keeps the targets that fail their conditions. A fold point with a
    # failed condition is no proof that the fold point is stale.
    _stow_sh_planned_links=()
    _stow_sh_planned_under=()
    _stow_sh_unfolded_folds=()
    _stow_sh_pkg_mutated=false
    local _plan_target _plan_dir
    for _plan_target in "${resolved_targets[@]}"; do
        [[ -z "$_plan_target" ]] && continue
        stow_sh::__link_rel "$_plan_target"
        _stow_sh_planned_links["$target_dir/$_stow_sh_link_rel"]=1
        stow_sh::__dir_of "$target_dir/$_stow_sh_link_rel"
        _plan_dir="$_stow_sh_dir"
        while [[ "$_plan_dir" != "$target_dir" && "$_plan_dir" != "/" && "$_plan_dir" != "." ]]; do
            # Early exit: a recorded dir has all its ancestors recorded too
            [[ -n "${_stow_sh_planned_under[$_plan_dir]+set}" ]] && break
            _stow_sh_planned_under["$_plan_dir"]=1
            stow_sh::__dir_of "$_plan_dir"
            _plan_dir="$_stow_sh_dir"
        done
    done

    # Sweep for stale fold points before the link loop. The loop's own
    # detection needs a planned link below a fold point, and a fold point
    # whose whole subtree the filter removed has none.
    local had_error=false
    stow_sh::__sweep_stale_folds "$pkg_dir" "" "$target_dir" || had_error=true

    local target
    for target in "${resolved_targets[@]}"; do
        [[ -z "$target" ]] && continue

        # Evaluate ## conditions — skip target if conditions fail
        if stow_sh::has_annotation "$target"; then
            if ! stow_sh::check_conditions "$target"; then
                stow_sh::log debug 1 "Skipping '$target' — conditions not met"
                stow_sh::report "~" "skip $target (conditions not met)"
                continue
            fi
        fi

        # Compute source (what the symlink points to) and link path
        local source_path="$pkg_dir/$target"
        stow_sh::__link_rel "$target"
        local link_path="$target_dir/$_stow_sh_link_rel"

        stow_sh::__create_link "$source_path" "$link_path" "$pkg_dir" "$target_dir" || had_error=true
    done

    if [[ "$had_error" == true ]]; then
        return 1
    fi
    return 0
}

# Unstow resolved targets — remove symlinks that point into the package.
#
# Usage: stow_sh::unstow_package pkg_dir target_dir target1 target2 ...
# Returns: 0 on success, 1 if any target had an error
stow_sh::unstow_package() {
    local pkg_dir="$1"
    local target_dir="$2"
    shift 2
    local -a resolved_targets=("$@")

    local had_error=false

    # Reset ancestor tracking for this package (global so __remove_link can access it).
    # Prevents duplicate reports when multiple files share the same ancestor fold point.
    declare -gA _stow_sh_handled_ancestors=()

    # Canonicalize the target dir once per package — __remove_link needs it
    # for its cleanup loop and would otherwise fork readlink per target.
    _stow_sh_canon_target="$(readlink -f "$target_dir")"

    stow_sh::log debug 1 "Unstowing ${#resolved_targets[@]} targets from '$pkg_dir' out of '$target_dir'"

    local target
    for target in "${resolved_targets[@]}"; do
        [[ -z "$target" ]] && continue

        # Compute the link path (annotation stripping + dotfiles translation)
        stow_sh::__link_rel "$target"
        local link_path="$target_dir/$_stow_sh_link_rel"
        local source_path="$pkg_dir/$target"

        stow_sh::__remove_link "$link_path" "$source_path" "$target_dir" || had_error=true
    done

    if [[ "$had_error" == true ]]; then
        return 1
    fi
    return 0
}

# --- Internal helpers ---

# Walk the package's directories and take apart each stale fold point.
#
# The per-file detection in __create_link needs a planned link below the
# fold point. A fold point whose whole subtree the filter removed has no
# planned link below it, so no file ever finds it (#5). This sweep checks
# the fold points directly: for each package directory, compute its link
# path and look at the target.
#
#   * A path the plan holds — prune. As a symlink, it is a correct fold
#     point that serves everything below it. As a real directory, the
#     link loop auto-unfolds it and links its children, so every fold
#     point below it serves planned content.
#   * A symlink into the package that the plan does not hold — stale.
#     __unfold_stale takes it apart under the usual rules (eviction,
#     the tracked-file guard, --no-evict, dry-run).
#   * A real directory — descend: a deeper fold point can hide below it.
#   * Anything else — prune. A foreign symlink is not stow's, and below a
#     path that does not exist at the target, nothing is stowed.
#
# The walk descends only where the target mirrors the package with real
# directories, so the cost is a few lstat calls per run.
#
# Usage: stow_sh::__sweep_stale_folds pkg_dir rel target_dir
#   rel — package-relative directory, "" at the package root
# Returns: 0 on success, 1 if __unfold_stale reported an error
stow_sh::__sweep_stale_folds() {
    local pkg_dir="$1"
    local rel="$2"
    local target_dir="$3"

    local abs="$pkg_dir${rel:+/$rel}"
    local had_error=false
    local entry name child_rel link_path
    for entry in "$abs"/* "$abs"/.*; do
        [[ -d "$entry" && ! -L "$entry" ]] || continue
        name="${entry##*/}"
        [[ "$name" == "." || "$name" == ".." ]] && continue
        [[ -z "$rel" && "$name" == ".git" ]] && continue
        child_rel="${rel:+$rel/}$name"
        stow_sh::__link_rel "$child_rel"
        link_path="$target_dir/$_stow_sh_link_rel"

        # The plan covers this path — prune, whatever its current form.
        [[ -n "${_stow_sh_planned_links[$link_path]+set}" ]] && continue

        if [[ -L "$link_path" ]]; then
            local _sweep_target
            _sweep_target="$(readlink -f "$link_path")"
            if [[ "$_sweep_target" == "$pkg_dir"* ]]; then
                stow_sh::__unfold_stale "$link_path" "$_sweep_target" || had_error=true
            fi
            # After an unfold, the target below holds only fresh content.
            # A kept or foreign symlink hides nothing of stow's. No descent.
            continue
        fi

        if [[ -d "$link_path" ]]; then
            stow_sh::__sweep_stale_folds "$pkg_dir" "$child_rel" "$target_dir" || had_error=true
        fi
    done

    [[ "$had_error" == true ]] && return 1
    return 0
}

# Take a stale fold point apart. Replace the directory symlink with a real
# directory. Then move each file that the run does not plan to link. The
# files move out of the package and into the target.
#
# The move is the purpose of the operation, not a side effect. An
# application wrote such a file through the fold point, so the write landed
# in the package. The package does not track the file, because a tracked
# file does not make a fold point stale. A file that stays in the package
# hides application state in the repository, where `git clean` removes it.
# A file that moves to the target stays where the application reads it.
#
# Usage: stow_sh::__unfold_stale fold_link source_dir
#   fold_link — the directory symlink at the target
#   source_dir — canonical path it points to, inside the package
# Returns: 0 on success, 1 if an eviction destination is occupied
stow_sh::__unfold_stale() {
    local fold_link="$1"
    local source_dir="$2"
    _stow_sh_fold_kept=false

    # Each planned file below the fold point finds it again, and a dry-run
    # pass keeps it. Act one time for each pass, and repeat the outcome.
    if [[ -n "${_stow_sh_unfolded_folds[$fold_link]+set}" ]]; then
        case "${_stow_sh_unfolded_folds[$fold_link]}" in
            kept) _stow_sh_fold_kept=true; return 0 ;;
            error) return 1 ;;
            *) return 0 ;;
        esac
    fi

    # --no-evict: keep the fold point and tell the user what it hides. The
    # files stay visible at the target through the symlink, so nothing
    # breaks, but they live in the package until the user acts.
    if ! stow_sh::is_evict; then
        _stow_sh_unfolded_folds["$fold_link"]="kept"
        _stow_sh_fold_kept=true
        stow_sh::is_preflight || stow_sh::log warn "Stale fold point kept (--no-evict): '$fold_link' serves filtered files from inside the package. Re-run with --evict to unfold it, or with -n --evict to preview."
        return 0
    fi

    # Eviction moves only files that git does not track. A package outside a
    # git work tree gives no way to tell package content from application
    # state, so keep the fold point and warn.
    if ! git -C "$source_dir" rev-parse --is-inside-work-tree &> /dev/null; then
        _stow_sh_unfolded_folds["$fold_link"]="kept"
        _stow_sh_fold_kept=true
        stow_sh::is_preflight || stow_sh::log warn "Stale fold point kept: '$fold_link' — the package is outside a git work tree, so stow.sh cannot tell package content from application state. Unfold it manually if intended."
        return 0
    fi

    # Record each tracked file below the fold point, and each parent
    # directory of a tracked file. The walk refuses to move them.
    _stow_sh_evict_tracked=()
    local _tracked
    while IFS= read -r -d '' _tracked; do
        _stow_sh_evict_tracked["$_tracked"]=1
        while [[ "$_tracked" == */* ]]; do
            _tracked="${_tracked%/*}"
            _stow_sh_evict_tracked["$_tracked"]=1
        done
    done < <(git -C "$source_dir" ls-files -z 2> /dev/null)

    local status=0
    if stow_sh::is_dry_run; then
        stow_sh::log debug 1 "WOULD unfold stale fold point: '$fold_link' -> '$source_dir'"
        stow_sh::report "?" "WOULD unfold $fold_link (stale fold point)"
        stow_sh::__unfold_stale_walk "$source_dir" "$fold_link" "" || status=1
    else
        stow_sh::log debug 1 "Unfolding stale fold point: '$fold_link' -> '$source_dir'"
        stow_sh::report "+" "unfold $fold_link (stale fold point)"
        rm "$fold_link"
        unset "_stow_sh_readlink_cache[$fold_link]"
        mkdir "$fold_link"
        stow_sh::__unfold_stale_walk "$source_dir" "$fold_link" "" || status=1
    fi

    if [[ $status -ne 0 ]]; then
        _stow_sh_unfolded_folds["$fold_link"]="error"
        return 1
    fi
    _stow_sh_unfolded_folds["$fold_link"]="unfolded"
    return 0
}

# Walk the source directory of a stale fold point. Move each entry that the
# run does not plan to link.
#
# The plan from stow_package gives three cases for each entry:
#   * The entry is a planned link. Leave it. The target loop in stow_package
#     creates it as a file link or as an inner fold point.
#   * The entry holds planned links deeper down. Make the directory and walk
#     into it. The run then also moves the unplanned entries beside them.
#   * Neither case applies. This run links nothing in the entry, so the
#     entry moves to the target.
#
# A move needs one more permission: git must not track the entry. A tracked
# file that drops out of the plan points at a transient filter — a one-off
# -I or -i flag, or a new .stowignore pattern — and a move would pull
# repository content out of the repository. That is an error, and the
# pre-flight turns it into an atomic abort. An untracked file is the
# application state that #4 describes, and it moves.
#
# Usage: stow_sh::__unfold_stale_walk source_dir dest_dir rel_prefix
#   rel_prefix — path of source_dir relative to the fold point's source,
#                or "" at the fold point itself. Keys _stow_sh_evict_tracked.
# Returns: 0 on success, 1 on a tracked entry or an occupied destination
stow_sh::__unfold_stale_walk() {
    local source_dir="$1"
    local dest_dir="$2"
    local rel_prefix="$3"

    local had_error=false
    local entry name dest rel
    for entry in "$source_dir"/* "$source_dir"/.*; do
        [[ ! -e "$entry" && ! -L "$entry" ]] && continue
        name="${entry##*/}"
        [[ "$name" == "." || "$name" == ".." ]] && continue
        stow_sh::__dotfiles_translate_var "$name"
        dest="$dest_dir/$_stow_sh_dtrans"
        rel="${rel_prefix}${rel_prefix:+/}$name"

        [[ -n "${_stow_sh_planned_links[$dest]+set}" ]] && continue

        if [[ -n "${_stow_sh_planned_under[$dest]+set}" ]]; then
            if [[ -d "$entry" && ! -L "$entry" ]]; then
                if stow_sh::is_dry_run; then
                    stow_sh::log debug 2 "WOULD mkdir '$dest' (unfold)"
                else
                    mkdir -p "$dest"
                fi
                stow_sh::__unfold_stale_walk "$entry" "$dest" "$rel" || had_error=true
            fi
            continue
        fi

        if [[ -n "${_stow_sh_evict_tracked[$rel]+set}" ]]; then
            stow_sh::log error "Refusing to evict '$entry': git tracks it. The run's filters exclude repository content — drop the filter, or move the file manually."
            had_error=true
            continue
        fi

        if stow_sh::is_dry_run; then
            stow_sh::log debug 1 "WOULD evict: '$entry' -> '$dest'"
            stow_sh::report "?" "WOULD evict $entry -> $dest"
            continue
        fi
        # The run made this destination tree empty. A path that exists here
        # shows a change from another process. Refuse. Do not overwrite.
        if [[ -e "$dest" || -L "$dest" ]]; then
            stow_sh::log error "Refusing to evict '$entry': '$dest' already exists"
            had_error=true
            continue
        fi
        stow_sh::log debug 1 "Evicting: '$entry' -> '$dest'"
        stow_sh::report "+" "evict $entry -> $dest"
        mv "$entry" "$dest"
        _stow_sh_pkg_mutated=true
    done

    [[ "$had_error" == true ]] && return 1
    return 0
}

# Create a single symlink, handling conflicts.
#
# Handles four cases at the link path: nothing exists (create), already
# correct (skip), conflicting symlink (force removes it), and real
# file/dir (adopt moves it into the package, or force removes it).
# Symlinks are always relative, computed via realpath -m --relative-to.
#
# Usage: stow_sh::__create_link source_path link_path pkg_dir target_dir
# Returns: 0 on success, 1 on unresolvable conflict
stow_sh::__create_link() {
    local source_path="$1"
    local link_path="$2"
    local pkg_dir="$3"
    local target_dir="$4"

    # Verify source exists
    if [[ ! -e "$source_path" ]]; then
        stow_sh::log error "Source does not exist: '$source_path'"
        return 1
    fi

    local link_dir
    stow_sh::__dir_of "$link_path"
    link_dir="$_stow_sh_dir"

    # Find an ancestor directory that is a symlink into the package. Such a
    # symlink is a fold point from an earlier run. The plan of this run, not
    # the symlink, shows whether the fold point is still correct:
    #
    #   * in the plan — the run keeps the fold point. Each file below it is
    #     already stowed through the directory symlink.
    #   * not in the plan — the fold point is stale. The run resolved
    #     individual files, because the directory holds a file that the run
    #     must not stow. A gitignored file is the usual cause. The fold point
    #     must come apart. If it stays, it serves that file from inside the
    #     package.
    #
    # The walk is bounded at target_dir: link_path is constructed as
    # "$target_dir/...", and any fold point stow created lives below it.
    # target_dir itself is canonical (realpath at setup), so no ancestor
    # of it can be a symlink.
    #
    # A symlink ancestor pointing elsewhere (e.g. a user's ~/.config →
    # /somewhere) is recorded — it disables the pure-bash relative-path
    # fast path below, since textual and canonical parents diverge there.
    # An unfolded ancestor does not need that flag. It becomes a real
    # directory, so the textual parent and the canonical parent agree.
    local _symlink_ancestor=false
    local _stale_unfold=false
    local _check_dir="$link_dir"
    while [[ "$_check_dir" != "$target_dir" && "$_check_dir" != "/" ]]; do
        if [[ -L "$_check_dir" ]]; then
            local _ancestor_target
            _ancestor_target="$(readlink -f "$_check_dir")"
            # Check if the ancestor symlink points into the package directory
            if [[ "$_ancestor_target" == "$pkg_dir"* ]]; then
                if [[ -n "${_stow_sh_planned_links[$_check_dir]+set}" ]]; then
                    stow_sh::__log_already_stowed "'$link_path' (via directory symlink at '$_check_dir')"
                    return 0
                fi
                stow_sh::__unfold_stale "$_check_dir" "$_ancestor_target" || return 1
                # A kept fold point still serves this file at the target.
                if [[ "$_stow_sh_fold_kept" == true ]]; then
                    stow_sh::__log_already_stowed "'$link_path' (via kept stale fold point at '$_check_dir')"
                    return 0
                fi
                _stale_unfold=true
            else
                _symlink_ancestor=true
            fi
        fi
        stow_sh::__dir_of "$_check_dir"
        _check_dir="$_stow_sh_dir"
    done

    # Compute the relative path from the link's parent directory to the
    # source. Pure bash on the fast path (all inputs canonical, no symlink
    # ancestors); realpath only when a symlinked ancestor makes textual
    # and canonical paths diverge.
    local rel_source
    if [[ "$_symlink_ancestor" == false ]]; then
        stow_sh::__relpath "$link_dir" "$source_path"
        rel_source="$_stow_sh_rel"
    else
        rel_source="$(realpath -m --relative-to="$link_dir" "$source_path")"
    fi

    # Check for conflicts at the link path.
    #
    # A stale fold point above this path stops the checks. What the checks
    # find through such a fold point is the content of the package, not a
    # conflict. A real unfold empties that view. A dry-run pass keeps the
    # symlink and still reads through it. A false conflict there stops the
    # pre-flight of a clean run.
    if [[ "$_stale_unfold" == true ]]; then
        stow_sh::log debug 2 "Ignoring state at '$link_path' — visible only through an unfolded fold point"
    elif [[ -L "$link_path" ]]; then
        # It's a symlink — check where it points. Fast path: the link
        # content matches exactly what we would create (the common case on
        # a repeated stow) — no canonicalization forks needed.
        local existing_raw
        stow_sh::__readlink_cached "$link_path"
        existing_raw="$_stow_sh_readlink"
        if [[ "$existing_raw" == "$rel_source" ]]; then
            stow_sh::__log_already_stowed "'$link_path'"
            return 0
        fi

        # Slow path: canonical comparison catches equivalent links written
        # differently (e.g. absolute, or via a different relative route).
        local existing_target
        existing_target="$(readlink -f "$link_path")"
        local canonical_source
        canonical_source="$(readlink -f "$source_path")"

        if [[ "$existing_target" == "$canonical_source" ]]; then
            stow_sh::__log_already_stowed "'$link_path'"
            return 0
        fi

        # Points elsewhere — conflict
        if stow_sh::is_force; then
            if stow_sh::is_dry_run; then
                stow_sh::log debug 1 "WOULD remove conflicting symlink: '$link_path' -> '$existing_raw'"
                stow_sh::report "?" "WOULD force $link_path"
                return 0
            fi
            stow_sh::log debug 1 "Removing conflicting symlink: '$link_path'"
            stow_sh::report "+" "force $link_path (was -> $existing_raw)"
            rm "$link_path"
            unset '_stow_sh_readlink_cache[$link_path]'
        else
            stow_sh::log error "Conflict: '$link_path' is a symlink to '$existing_raw' (use --force to override)"
            return 1
        fi
    elif [[ -e "$link_path" ]]; then
        # Exists as a real file or directory
        if [[ -d "$source_path" && -d "$link_path" && ! -L "$link_path" ]]; then
            # Auto-unfold: source is a fold point (directory) but target is
            # already a real directory. Instead of erroring, enumerate
            # immediate children and call __create_link for each. Child
            # directories that don't exist at the target become directory
            # symlinks (fold); those that do exist recurse into auto-unfold.
            stow_sh::log debug 1 "Auto-unfolding: '$link_path' is a real directory, linking children"
            local _unfold_had_error=false
            local _unfold_child _name
            for _unfold_child in "$source_path"/*; do
                [[ -e "$_unfold_child" ]] || continue
                stow_sh::__dotfiles_translate_var "${_unfold_child##*/}"
                _name="$_stow_sh_dtrans"
                stow_sh::__create_link "$_unfold_child" "$link_path/$_name" "$pkg_dir" "$target_dir" || _unfold_had_error=true
            done
            # Also handle dotfiles (hidden files/dirs)
            for _unfold_child in "$source_path"/.*; do
                _name="${_unfold_child##*/}"
                [[ "$_name" == "." || "$_name" == ".." ]] && continue
                [[ -e "$_unfold_child" ]] || continue
                stow_sh::__dotfiles_translate_var "$_name"
                _name="$_stow_sh_dtrans"
                stow_sh::__create_link "$_unfold_child" "$link_path/$_name" "$pkg_dir" "$target_dir" || _unfold_had_error=true
            done
            if [[ "$_unfold_had_error" == true ]]; then
                return 1
            fi
            return 0
        elif stow_sh::is_adopt; then
            if stow_sh::is_dry_run; then
                stow_sh::log debug 1 "WOULD adopt: '$link_path' -> '$source_path'"
                stow_sh::report "?" "WOULD adopt $link_path"
                return 0
            fi
            stow_sh::log debug 1 "Adopting: '$link_path' -> '$source_path'"
            stow_sh::report "+" "adopt $link_path -> $source_path"
            # Move the existing file into the package, then symlink
            local source_dir
            stow_sh::__dir_of "$source_path"
            source_dir="$_stow_sh_dir"
            mkdir -p "$source_dir"
            mv "$link_path" "$source_path"
            _stow_sh_pkg_mutated=true
        elif stow_sh::is_force; then
            # Safety guards run BEFORE the dry-run/pre-flight early return, so
            # an unresolvable --force conflict is caught during pre-flight and
            # aborts the whole run with zero changes (never half-applied).
            #
            # Guard 1: never delete a path that resolves outside the target
            # directory. link_path is built from target_dir by construction, so
            # this only trips on a bug or a crafted package — exactly when we
            # most want to refuse to delete.
            local _canonical_target _canonical_link_dir
            _canonical_target="$(readlink -f "$target_dir")"
            _canonical_link_dir="$(readlink -f "$link_dir")"
            if [[ "$_canonical_link_dir" != "$_canonical_target" && "$_canonical_link_dir" != "$_canonical_target"/* ]]; then
                stow_sh::log error "Refusing to force-remove '$link_path': resolves outside target '$target_dir'"
                return 1
            fi
            # Guard 2: never recursively delete a real directory. Auto-unfold
            # already handles a directory source over a real directory; reaching
            # here with a real dir means a file would replace a populated
            # directory. That is a genuine conflict, not something --force
            # should silently wipe.
            if [[ -d "$link_path" && ! -L "$link_path" ]]; then
                stow_sh::log error "Refusing to force-remove real directory: '$link_path' (remove it manually if intended)"
                return 1
            fi
            if stow_sh::is_dry_run; then
                stow_sh::log debug 1 "WOULD remove conflicting path: '$link_path'"
                stow_sh::report "?" "WOULD force $link_path"
                return 0
            fi
            stow_sh::log debug 1 "Removing conflicting path: '$link_path'"
            stow_sh::report "+" "force $link_path"
            rm -f "$link_path"
        else
            stow_sh::log error "Conflict: '$link_path' already exists (use --adopt or --force)"
            return 1
        fi
    fi

    # Create parent directories if needed
    if [[ ! -d "$link_dir" ]]; then
        if stow_sh::is_dry_run; then
            stow_sh::log debug 1 "WOULD mkdir -p '$link_dir'"
        else
            stow_sh::log debug 2 "Creating directory: '$link_dir'"
            mkdir -p "$link_dir"
        fi
    fi

    # Create the symlink (rel_source was computed above, before the
    # conflict checks, so the already-stowed fast path could reuse it)
    if stow_sh::is_dry_run; then
        stow_sh::log debug 1 "WOULD link: '$link_path' -> '$rel_source'"
        stow_sh::report "?" "WOULD link $link_path -> $rel_source"
    else
        stow_sh::log debug 1 "Linking: '$link_path' -> '$rel_source'"
        ln -s "$rel_source" "$link_path"
        stow_sh::report "+" "$link_path -> $rel_source"
    fi
    return 0
}

# Remove a single symlink if it points to the expected source.
#
# After removal, cleans up empty parent directories up to (but not
# including) target_dir. Uses readlink -f to canonicalize both sides
# so relative symlinks resolve correctly.
#
# Usage: stow_sh::__remove_link link_path expected_source target_dir
# Returns: 0 on success, 1 if the link doesn't point where expected
stow_sh::__remove_link() {
    local link_path="$1"
    local expected_source="$2"
    local target_dir="$3"

    if [[ ! -L "$link_path" ]]; then
        if [[ ! -e "$link_path" ]]; then
            stow_sh::log debug 1 "Already unstowed (does not exist): '$link_path'"
            return 0
        fi
        # Auto-unfold inverse: expected source is a directory and the target
        # is a real directory (previously auto-unfolded during stow). Enumerate
        # immediate children and call __remove_link for each. Child directory
        # symlinks are removed directly; real directories recurse.
        if [[ -d "$expected_source" && -d "$link_path" ]]; then
            stow_sh::log debug 1 "Auto-unfolding unstow: '$link_path' is a real directory, removing children"
            local _unfold_had_error=false
            local _unfold_child _name
            for _unfold_child in "$expected_source"/*; do
                [[ -e "$_unfold_child" ]] || continue
                stow_sh::__dotfiles_translate_var "${_unfold_child##*/}"
                _name="$_stow_sh_dtrans"
                stow_sh::__remove_link "$link_path/$_name" "$_unfold_child" "$target_dir" || _unfold_had_error=true
            done
            # Also handle dotfiles (hidden files/dirs)
            for _unfold_child in "$expected_source"/.*; do
                _name="${_unfold_child##*/}"
                [[ "$_name" == "." || "$_name" == ".." ]] && continue
                [[ -e "$_unfold_child" ]] || continue
                stow_sh::__dotfiles_translate_var "$_name"
                _name="$_stow_sh_dtrans"
                stow_sh::__remove_link "$link_path/$_name" "$_unfold_child" "$target_dir" || _unfold_had_error=true
            done
            if [[ "$_unfold_had_error" == true ]]; then
                return 1
            fi
            return 0
        fi
        # Check if an ancestor directory is a symlink pointing into the
        # package (i.e. stow created a fold point). If so, remove the
        # ancestor symlink instead — it covers this file.
        #
        # _canonical_source is only needed when a symlink ancestor is
        # actually found, so it's computed lazily — the common case
        # (ancestor already handled) then costs zero forks.
        local _canonical_source=""
        local _check_dir
        stow_sh::__dir_of "$link_path"
        _check_dir="$_stow_sh_dir"
        while [[ "$_check_dir" != "$target_dir" && "$_check_dir" != "/" ]]; do
            if [[ -L "$_check_dir" ]] || [[ -n "${_stow_sh_handled_ancestors["$_check_dir"]+x}" ]]; then
                # Already handled this ancestor (e.g. removed, or reported in dry-run)
                if [[ -n "${_stow_sh_handled_ancestors["$_check_dir"]+x}" ]]; then
                    stow_sh::log debug 1 "Already handled ancestor fold point: '$_check_dir' (covers '$link_path')"
                    return 0
                fi
                local _ancestor_target
                _ancestor_target="$(readlink -f "$_check_dir")"
                [[ -n "$_canonical_source" ]] || _canonical_source="$(readlink -f "$expected_source")"
                # The ancestor covers this file if its resolved target is a
                # prefix of the file's expected source (both canonical).
                if [[ "$_canonical_source" == "$_ancestor_target"/* ]]; then
                    stow_sh::log debug 1 "Removing ancestor fold point: '$_check_dir' (covers '$link_path')"
                    _stow_sh_handled_ancestors["$_check_dir"]=1
                    stow_sh::__remove_link "$_check_dir" "$_ancestor_target" "$target_dir"
                    return $?
                fi
            fi
            stow_sh::__dir_of "$_check_dir"
            _check_dir="$_stow_sh_dir"
        done
        stow_sh::log error "Cannot unstow: '$link_path' is not a symlink"
        return 1
    fi

    # Verify symlink points to the expected source. Fast path: the link
    # content matches exactly what stow would have created (relative link
    # from the link's parent) — no canonicalization forks needed.
    local actual_raw
    stow_sh::__readlink_cached "$link_path"
    actual_raw="$_stow_sh_readlink"
    local _link_parent
    stow_sh::__dir_of "$link_path"
    _link_parent="$_stow_sh_dir"
    stow_sh::__relpath "$_link_parent" "$expected_source"
    if [[ "$actual_raw" != "$_stow_sh_rel" ]]; then
        # Slow path: canonical comparison catches equivalent links written
        # differently (e.g. absolute, or through symlinked parents).
        local actual_target
        actual_target="$(readlink -f "$link_path")"
        local canonical_source
        canonical_source="$(readlink -f "$expected_source")"

        if [[ "$actual_target" != "$canonical_source" ]]; then
            stow_sh::log error "Cannot unstow: '$link_path' points to '$actual_target', not '$canonical_source'"
            return 1
        fi
    fi

    # Remove the symlink
    if stow_sh::is_dry_run; then
        stow_sh::log debug 1 "WOULD unlink: '$link_path'"
        stow_sh::report "?" "WOULD unlink $link_path"
    else
        stow_sh::log debug 1 "Unlinking: '$link_path'"
        rm "$link_path"
        unset '_stow_sh_readlink_cache[$link_path]'
        stow_sh::report "-" "$link_path"
    fi

    # Clean up empty parent directories (up to target_dir, exclusive)
    if ! stow_sh::is_dry_run; then
        local dir
        stow_sh::__dir_of "$link_path"
        dir="$_stow_sh_dir"
        # Prefer the per-package canonical target computed by unstow_package;
        # fall back to a readlink fork only when called standalone.
        local canonical_target_dir
        canonical_target_dir="${_stow_sh_canon_target:-$(readlink -f "$target_dir")}"
        while [[ "$dir" != "$canonical_target_dir" && "$dir" != "$target_dir" && "$dir" != "/" ]]; do
            if [[ -d "$dir" ]] && _stow_sh__is_dir_empty "$dir"; then
                stow_sh::log debug 2 "Removing empty directory: '$dir'"
                rmdir "$dir"
                stow_sh::__dir_of "$dir"
                dir="$_stow_sh_dir"
            else
                break
            fi
        done
    fi

    return 0
}

# Check if a directory is empty. Pure bash (glob) — no fork.
#
# Usage: _stow_sh__is_dir_empty /path/to/dir
# Returns: 0 if empty, 1 otherwise
_stow_sh__is_dir_empty() {
    local dir="$1" entry base
    [[ -d "$dir" ]] || return 1
    for entry in "$dir"/* "$dir"/.*; do
        base="${entry##*/}"
        [[ "$base" == "." || "$base" == ".." ]] && continue
        [[ -e "$entry" || -L "$entry" ]] && return 1
    done
    return 0
}
