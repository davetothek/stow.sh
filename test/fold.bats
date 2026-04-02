#!/usr/bin/env bats
# SPDX-License-Identifier: MIT
# Copyright (c) 2025 David Kristiansen

setup() {
    source "$BATS_TEST_DIRNAME/../src/log.sh"
    source "$BATS_TEST_DIRNAME/../src/conditions.sh"
    source "$BATS_TEST_DIRNAME/../src/fold.sh"
}

# Helper: call fold_targets with same list for all_entries and candidates
# (no files excluded by filtering)
fold_no_exclusions() {
    local -a args=()
    local -a entries=()
    local seen_pkg_root=false
    local pkg_root=""

    # Collect barrier flags and pkg_root, rest are entries
    for arg in "$@"; do
        if [[ "$arg" == --barrier=* ]]; then
            args+=("$arg")
        elif [[ "$seen_pkg_root" == false ]]; then
            pkg_root="$arg"
            seen_pkg_root=true
        else
            entries+=("$arg")
        fi
    done

    # Call with identical all_entries and candidates
    stow_sh::fold_targets "${args[@]}" "$pkg_root" -- "${entries[@]}" -- "${entries[@]}"
}

# =============================================================================
# Basic folding (no annotations, no exclusions)
# =============================================================================

@test "fold_targets folds parent dirs and excludes flat files from fold points" {
    run fold_no_exclusions "." "a/b/file1" "a/b/file2"
    [ "$status" -eq 0 ]
    # a is the shallowest foldable dir — should be the fold point
    [[ "$output" == *"a"* ]]
    # individual files are covered by fold point a — should NOT appear
    [[ "$output" != *"file1"* ]]
    [[ "$output" != *"file2"* ]]
}

@test "fold_targets returns flat files as individual entries" {
    run fold_no_exclusions "." "file1" "file2"
    [ "$status" -eq 0 ]
    [[ "$output" == *"file1"* ]]
    [[ "$output" == *"file2"* ]]
}

@test "fold_targets handles single file in subdirectory" {
    run fold_no_exclusions "." "a/b/c/file.txt"
    [ "$status" -eq 0 ]
    # a is the shallowest fold point — covers everything
    local lines
    mapfile -t lines <<< "$output"
    [ "${#lines[@]}" -eq 1 ]
    [ "${lines[0]}" = "a" ]
}

@test "fold_targets returns maximal (shallowest) fold point" {
    run fold_no_exclusions "." "a/b/file1" "a/c/file2"
    [ "$status" -eq 0 ]
    # a is the shallowest fold point covering both branches
    local lines
    mapfile -t lines <<< "$output"
    [ "${#lines[@]}" -eq 1 ]
    [ "${lines[0]}" = "a" ]
}

@test "fold_targets handles mix of flat files and nested dirs" {
    run fold_no_exclusions "." ".bashrc" ".config/nvim/init.lua"
    [ "$status" -eq 0 ]
    [[ "$output" == *".bashrc"* ]]
    [[ "$output" == *".config"* ]]
    # .bashrc is flat, .config is fold point — 2 entries
    local lines
    mapfile -t lines <<< "$output"
    [ "${#lines[@]}" -eq 2 ]
}

# =============================================================================
# Annotation-aware folding
# =============================================================================

@test "fold_targets blocks folding when descendant has ## annotation" {
    # conf.d contains an annotated file — cannot fold conf.d or ancestors
    # All individual files should appear instead
    run fold_no_exclusions "." \
        ".config/mise/conf.d/00-core.toml" \
        ".config/mise/conf.d/10-dev.toml" \
        ".config/mise/conf.d/20-desktop.toml##!docker"
    [ "$status" -eq 0 ]
    # All 3 files should appear as individual entries
    [[ "$output" == *"00-core.toml"* ]]
    [[ "$output" == *"10-dev.toml"* ]]
    [[ "$output" == *"20-desktop.toml##!docker"* ]]
    # No fold points for tainted dirs
    [[ "$output" != *"conf.d"$'\n'* ]]  # conf.d alone shouldn't appear as fold point
}

@test "fold_targets allows folding in clean subtrees alongside tainted ones" {
    # nvim/ is clean, mise/ has an annotated file
    run fold_no_exclusions "." \
        ".config/nvim/init.lua" \
        ".config/nvim/lua/plugins.lua" \
        ".config/mise/conf.d/00-core.toml" \
        ".config/mise/conf.d/20-desktop.toml##!docker"
    [ "$status" -eq 0 ]
    # nvim subtree is clean — should be a fold point (but .config can't fold
    # because mise is tainted)
    [[ "$output" == *".config/nvim"* ]]
    # mise individual files should appear
    [[ "$output" == *"00-core.toml"* ]]
    [[ "$output" == *"20-desktop.toml##!docker"* ]]
    # mise should NOT appear as a fold point
    local line
    while IFS= read -r line; do
        [[ "$line" != ".config/mise" ]]
        [[ "$line" != ".config/mise/conf.d" ]]
    done <<< "$output"
}

@test "fold_targets taints only the annotated branch, not siblings" {
    run fold_no_exclusions "." \
        "a/clean/file1" \
        "a/clean/file2" \
        "a/dirty/file##os.linux"
    [ "$status" -eq 0 ]
    # a/clean should be a fold point (but not a — ancestor is tainted)
    [[ "$output" == *"a/clean"* ]]
    # a/dirty's file should appear individually
    [[ "$output" == *"file##os.linux"* ]]
    # a should NOT be a fold point (dirty taints it)
    local line
    while IFS= read -r line; do
        [[ "$line" != "a" ]]
    done <<< "$output"
}

@test "fold_targets handles only annotated files" {
    run fold_no_exclusions "." \
        "dir/file1##os.linux" \
        "dir/file2##shell.bash"
    [ "$status" -eq 0 ]
    # dir is fully tainted — both files appear individually
    [[ "$output" == *"file1##os.linux"* ]]
    [[ "$output" == *"file2##shell.bash"* ]]
    # No fold points
    local line
    while IFS= read -r line; do
        [[ "$line" != "dir" ]]
    done <<< "$output"
}

@test "fold_targets handles deeply nested annotation" {
    run fold_no_exclusions "." \
        "a/b/c/d/file.txt" \
        "a/b/c/d/other##exe.nvim"
    [ "$status" -eq 0 ]
    # Entire chain is tainted — both files appear individually
    [[ "$output" == *"file.txt"* ]]
    [[ "$output" == *"other##exe.nvim"* ]]
    local line
    while IFS= read -r line; do
        [[ "$line" != "a" ]]
        [[ "$line" != "a/b" ]]
        [[ "$line" != "a/b/c" ]]
        [[ "$line" != "a/b/c/d" ]]
    done <<< "$output"
}

@test "fold_targets: real-world mise example" {
    run fold_no_exclusions "." \
        ".config/mise/conf.d/00-core.toml" \
        ".config/mise/conf.d/10-dev.toml" \
        ".config/mise/conf.d/20-desktop.toml##!docker" \
        ".config/mise/config.toml"
    [ "$status" -eq 0 ]
    # All individual files should appear — no folding possible
    [[ "$output" == *"00-core.toml"* ]]
    [[ "$output" == *"10-dev.toml"* ]]
    [[ "$output" == *"20-desktop.toml##!docker"* ]]
    [[ "$output" == *"config.toml"* ]]
    # No fold points
    local line
    while IFS= read -r line; do
        [[ "$line" != ".config" ]]
        [[ "$line" != ".config/mise" ]]
        [[ "$line" != ".config/mise/conf.d" ]]
    done <<< "$output"
}

# =============================================================================
# XDG barrier folding
# =============================================================================

@test "fold_targets: barrier prevents folding at barrier dir" {
    # .config is a barrier — cannot fold .config itself
    run fold_no_exclusions --barrier=.config "." \
        ".config/nvim/init.lua" \
        ".config/nvim/lua/plugins.lua"
    [ "$status" -eq 0 ]
    # nvim is INSIDE .config — children of barriers CAN fold
    [[ "$output" == *".config/nvim"* ]]
    # .config itself must NOT be a fold point
    local line
    while IFS= read -r line; do
        [[ "$line" != ".config" ]]
    done <<< "$output"
    # Only one entry: the fold point for nvim (covers nvim/lua too)
    local lines
    mapfile -t lines <<< "$output"
    [ "${#lines[@]}" -eq 1 ]
    [ "${lines[0]}" = ".config/nvim" ]
}

@test "fold_targets: barrier ancestor is also protected" {
    # .local/share is a barrier — .local must not fold either
    run fold_no_exclusions --barrier=.local/share "." \
        ".local/share/app/data.db" \
        ".local/share/app/config"
    [ "$status" -eq 0 ]
    # app is inside .local/share — children of barrier can fold
    [[ "$output" == *".local/share/app"* ]]
    # .local/share and .local must NOT appear as fold points
    local line
    while IFS= read -r line; do
        [[ "$line" != ".local/share" ]]
        [[ "$line" != ".local" ]]
    done <<< "$output"
}

@test "fold_targets: multiple barriers protect multiple paths" {
    run fold_no_exclusions \
        --barrier=.config \
        --barrier=.local/share \
        --barrier=.cache \
        "." \
        ".config/nvim/init.lua" \
        ".local/share/app/data.db" \
        ".cache/myapp/tmp"
    [ "$status" -eq 0 ]
    # Children inside barriers can fold
    [[ "$output" == *".config/nvim"* ]]
    [[ "$output" == *".local/share/app"* ]]
    [[ "$output" == *".cache/myapp"* ]]
    # Barriers and their ancestors must not fold
    local line
    while IFS= read -r line; do
        [[ "$line" != ".config" ]]
        [[ "$line" != ".local/share" ]]
        [[ "$line" != ".local" ]]
        [[ "$line" != ".cache" ]]
    done <<< "$output"
}

@test "fold_targets: no barriers still works normally" {
    run fold_no_exclusions "." \
        ".config/nvim/init.lua" \
        ".config/nvim/lua/plugins.lua"
    [ "$status" -eq 0 ]
    # Without barriers, .config CAN fold — shallowest fold point
    local lines
    mapfile -t lines <<< "$output"
    [ "${#lines[@]}" -eq 1 ]
    [ "${lines[0]}" = ".config" ]
}

@test "fold_targets: barrier + annotation interact correctly" {
    # .config is a barrier, mise has annotated child
    run fold_no_exclusions --barrier=.config "." \
        ".config/nvim/init.lua" \
        ".config/mise/conf.d/00-core.toml" \
        ".config/mise/conf.d/20-desktop.toml##!docker"
    [ "$status" -eq 0 ]
    # nvim is clean and inside barrier — can fold
    [[ "$output" == *".config/nvim"* ]]
    # mise individual files should appear
    [[ "$output" == *"00-core.toml"* ]]
    [[ "$output" == *"20-desktop.toml##!docker"* ]]
    # .config is a barrier — cannot fold
    local line
    while IFS= read -r line; do
        [[ "$line" != ".config" ]]
    done <<< "$output"
}

@test "fold_targets: real-world XDG scenario with .local subtree" {
    run fold_no_exclusions \
        --barrier=.local/bin \
        --barrier=.local/share \
        --barrier=.local/state \
        --barrier=.config \
        --barrier=.cache \
        "." \
        ".local/bin/my-script" \
        ".local/share/myapp/data.db" \
        ".local/share/myapp/cache/tmp" \
        ".local/state/myapp/log" \
        ".config/nvim/init.lua" \
        ".config/nvim/lua/plugins.lua"
    [ "$status" -eq 0 ]
    # Children of barriers can fold as directories
    [[ "$output" == *".local/share/myapp"* ]]
    [[ "$output" == *".config/nvim"* ]]
    # .local/state/myapp is a fold point (one file inside, clean subtree)
    [[ "$output" == *".local/state/myapp"* ]]
    # .local/bin/my-script — my-script is a direct child of barrier, its parent
    # is the barrier itself (.local/bin) so it can't fold — appears as individual file
    [[ "$output" == *"my-script"* ]]
    # Barriers and ancestors must not fold
    local line
    while IFS= read -r line; do
        [[ "$line" != ".local" ]]
        [[ "$line" != ".local/bin" ]]
        [[ "$line" != ".local/share" ]]
        [[ "$line" != ".local/state" ]]
        [[ "$line" != ".config" ]]
        [[ "$line" != ".cache" ]]
    done <<< "$output"
}

# =============================================================================
# Exclusion-aware folding (files removed by filter)
# =============================================================================

@test "fold_targets: excluded file prevents parent from folding" {
    # all_entries has file2, but candidates does not — file2 was filtered out
    # So a/b cannot be folded (would leak file2)
    run stow_sh::fold_targets "." \
        -- "a/b/file1" "a/b/file2" \
        -- "a/b/file1"
    [ "$status" -eq 0 ]
    # a/b cannot fold (file2 was excluded) — file1 appears individually
    [[ "$output" == *"a/b/file1"* ]]
    # a and a/b should NOT be fold points
    local line
    while IFS= read -r line; do
        [[ "$line" != "a" ]]
        [[ "$line" != "a/b" ]]
    done <<< "$output"
}

@test "fold_targets: exclusion taints only affected branch" {
    # a/clean has all files surviving, a/partial has one excluded
    run stow_sh::fold_targets "." \
        -- "a/clean/f1" "a/clean/f2" "a/partial/f3" "a/partial/f4" \
        -- "a/clean/f1" "a/clean/f2" "a/partial/f3"
    [ "$status" -eq 0 ]
    # a/clean is foldable — all its files survived
    [[ "$output" == *"a/clean"* ]]
    # a/partial is tainted — f3 appears individually
    [[ "$output" == *"a/partial/f3"* ]]
    # a cannot fold (a/partial is tainted)
    local line
    while IFS= read -r line; do
        [[ "$line" != "a" ]]
        [[ "$line" != "a/partial" ]]
    done <<< "$output"
}

@test "fold_targets: exclusion + annotation + barrier combined" {
    # .config barrier, annotation in mise, excluded file in i3
    run stow_sh::fold_targets \
        --barrier=.config \
        "." \
        -- ".config/nvim/init.lua" ".config/nvim/lua/plugins.lua" \
           ".config/mise/conf.d/00-core.toml" ".config/mise/conf.d/20-desktop.toml##!docker" \
           ".config/i3/config" ".config/i3/scripts/lock.sh" \
        -- ".config/nvim/init.lua" ".config/nvim/lua/plugins.lua" \
           ".config/mise/conf.d/00-core.toml" ".config/mise/conf.d/20-desktop.toml##!docker" \
           ".config/i3/config"
    [ "$status" -eq 0 ]
    # nvim: clean, inside barrier — folds
    [[ "$output" == *".config/nvim"* ]]
    # mise: tainted by annotation — individual files
    [[ "$output" == *"00-core.toml"* ]]
    [[ "$output" == *"20-desktop.toml##!docker"* ]]
    # i3: tainted by exclusion (scripts/lock.sh filtered out) — config appears individually
    [[ "$output" == *".config/i3/config"* ]]
    # .config barrier — cannot fold
    local line
    while IFS= read -r line; do
        [[ "$line" != ".config" ]]
        [[ "$line" != ".config/mise" ]]
        [[ "$line" != ".config/mise/conf.d" ]]
        [[ "$line" != ".config/i3" ]]
    done <<< "$output"
}

@test "fold_targets: no exclusions allows full folding" {
    # Same list for both — nothing excluded
    run stow_sh::fold_targets "." \
        -- "a/b/f1" "a/b/f2" "a/c/f3" \
        -- "a/b/f1" "a/b/f2" "a/c/f3"
    [ "$status" -eq 0 ]
    # a is the shallowest fold point — covers everything
    local lines
    mapfile -t lines <<< "$output"
    [ "${#lines[@]}" -eq 1 ]
    [ "${lines[0]}" = "a" ]
}

@test "fold_targets: all files excluded leaves empty output" {
    # all_entries has files, candidates is empty
    run stow_sh::fold_targets "." \
        -- "a/b/f1" "a/b/f2" \
        --
    [ "$status" -eq 0 ]
    [ "$output" = "" ]
}

# =============================================================================
# Edge cases
# =============================================================================

@test "fold_targets: single flat file returns it as-is" {
    run fold_no_exclusions "." ".bashrc"
    [ "$status" -eq 0 ]
    local lines
    mapfile -t lines <<< "$output"
    [ "${#lines[@]}" -eq 1 ]
    [ "${lines[0]}" = ".bashrc" ]
}

@test "fold_targets: expected output for discovery example" {
    # The exact example from the design doc
    run stow_sh::fold_targets --barrier=.config "." \
        -- ".config/nvim/init.lua" ".config/nvim/lua/plugins.lua" \
           ".config/mise/conf.d/00-core.toml" ".config/mise/conf.d/20-desktop.toml##!docker" \
           ".config/mise/config.toml" ".bashrc" \
        -- ".config/nvim/init.lua" ".config/nvim/lua/plugins.lua" \
           ".config/mise/conf.d/00-core.toml" ".config/mise/conf.d/20-desktop.toml##!docker" \
           ".config/mise/config.toml" ".bashrc"
    [ "$status" -eq 0 ]
    # Expected output (sorted):
    #   .bashrc                                     (flat file)
    #   .config/mise/conf.d/00-core.toml            (individual — tainted subtree)
    #   .config/mise/conf.d/20-desktop.toml##!docker (individual — annotated)
    #   .config/mise/config.toml                    (individual — tainted parent)
    #   .config/nvim                                (fold point — clean subtree inside barrier)
    local lines
    mapfile -t lines <<< "$output"
    [ "${#lines[@]}" -eq 5 ]
    [ "${lines[0]}" = ".bashrc" ]
    [ "${lines[1]}" = ".config/mise/conf.d/00-core.toml" ]
    [ "${lines[2]}" = ".config/mise/conf.d/20-desktop.toml##!docker" ]
    [ "${lines[3]}" = ".config/mise/config.toml" ]
    [ "${lines[4]}" = ".config/nvim" ]
}
