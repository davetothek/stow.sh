#!/usr/bin/env bats
# SPDX-License-Identifier: MIT
# Copyright (c) 2025 David Kristiansen

setup() {
    source "$BATS_TEST_DIRNAME/../src/log.sh"
    source "$BATS_TEST_DIRNAME/../src/conditions.sh"
    source "$BATS_TEST_DIRNAME/../src/fold.sh"

    # Create a temporary package directory for filesystem-based tests
    TEST_PKG="$BATS_TEST_TMPDIR/pkg"
    mkdir -p "$TEST_PKG"
}

# Helper: create files in the test package directory.
# Usage: create_pkg_files "a/b/file1" "a/b/file2" ...
create_pkg_files() {
    local f
    for f in "$@"; do
        mkdir -p "$TEST_PKG/$(dirname "$f")"
        touch "$TEST_PKG/$f"
    done
}

# Helper: call fold_targets with all files as candidates (no exclusions).
# Creates files on disk and passes them as candidates.
# Usage: fold_all [--barrier=X ...] file1 file2 ...
fold_all() {
    local -a barrier_args=()
    while [[ $# -gt 0 && "$1" == --barrier=* ]]; do
        barrier_args+=("$1")
        shift
    done
    local -a files=("$@")
    create_pkg_files "${files[@]}"
    stow_sh::fold_targets "${barrier_args[@]}" "$TEST_PKG" -- "${files[@]}"
}

# =============================================================================
# Basic folding (no annotations, no exclusions)
# =============================================================================

@test "fold_targets folds parent dirs and excludes flat files from fold points" {
    run fold_all "a/b/file1" "a/b/file2"
    [ "$status" -eq 0 ]
    # a is the shallowest foldable dir — should be the fold point
    [[ "$output" == *"a"* ]]
    # individual files are covered by fold point a — should NOT appear
    [[ "$output" != *"file1"* ]]
    [[ "$output" != *"file2"* ]]
}

@test "fold_targets returns flat files as individual entries" {
    run fold_all "file1" "file2"
    [ "$status" -eq 0 ]
    [[ "$output" == *"file1"* ]]
    [[ "$output" == *"file2"* ]]
}

@test "fold_targets handles single file in subdirectory" {
    run fold_all "a/b/c/file.txt"
    [ "$status" -eq 0 ]
    # a is the shallowest fold point — covers everything
    local lines
    mapfile -t lines <<< "$output"
    [ "${#lines[@]}" -eq 1 ]
    [ "${lines[0]}" = "a" ]
}

@test "fold_targets returns maximal (shallowest) fold point" {
    run fold_all "a/b/file1" "a/c/file2"
    [ "$status" -eq 0 ]
    # a is the shallowest fold point covering both branches
    local lines
    mapfile -t lines <<< "$output"
    [ "${#lines[@]}" -eq 1 ]
    [ "${lines[0]}" = "a" ]
}

@test "fold_targets handles mix of flat files and nested dirs" {
    run fold_all ".bashrc" ".config/nvim/init.lua"
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
    run fold_all \
        ".config/mise/conf.d/00-core.toml" \
        ".config/mise/conf.d/10-dev.toml" \
        ".config/mise/conf.d/20-desktop.toml##!docker"
    [ "$status" -eq 0 ]
    # All 3 files should appear as individual entries
    [[ "$output" == *"00-core.toml"* ]]
    [[ "$output" == *"10-dev.toml"* ]]
    [[ "$output" == *"20-desktop.toml##!docker"* ]]
    # No fold points for tainted dirs
    [[ "$output" != *"conf.d"$'\n'* ]]
}

@test "fold_targets allows folding in clean subtrees alongside tainted ones" {
    # nvim/ is clean, mise/ has an annotated file
    run fold_all \
        ".config/nvim/init.lua" \
        ".config/nvim/lua/plugins.lua" \
        ".config/mise/conf.d/00-core.toml" \
        ".config/mise/conf.d/20-desktop.toml##!docker"
    [ "$status" -eq 0 ]
    # nvim subtree is clean — should be a fold point
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
    run fold_all \
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
    run fold_all \
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
    run fold_all \
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
    run fold_all \
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
# Directory-level annotation folding
# =============================================================================

@test "fold_targets: annotated directory with clean children folds" {
    # dir##cond/ has clean children — the annotated dir IS a fold point
    run fold_all \
        "tools##exe.ls/config.toml" \
        "tools##exe.ls/plugin.lua"
    [ "$status" -eq 0 ]
    local lines
    mapfile -t lines <<< "$output"
    [ "${#lines[@]}" -eq 1 ]
    [ "${lines[0]}" = "tools##exe.ls" ]
}

@test "fold_targets: annotated directory taints only ancestors above it" {
    # .config/zsh##shell.zsh/ has clean children — folds at zsh##shell.zsh
    # .config is tainted (ancestor of annotated dir)
    run fold_all \
        ".config/zsh##shell.zsh/.zshrc" \
        ".config/zsh##shell.zsh/.p10k.zsh" \
        ".bashrc"
    [ "$status" -eq 0 ]
    [[ "$output" == *".config/zsh##shell.zsh"* ]]
    [[ "$output" == *".bashrc"* ]]
    # .config cannot fold (ancestor of ## dir)
    local line
    while IFS= read -r line; do
        [[ "$line" != ".config" ]]
    done <<< "$output"
    local lines
    mapfile -t lines <<< "$output"
    [ "${#lines[@]}" -eq 2 ]
}

@test "fold_targets: annotated directory with annotated child cannot fold" {
    # dir##cond/ has a child with its own ## — dir##cond cannot fold
    run fold_all \
        "dir##exe.ls/file1" \
        "dir##exe.ls/file2##os.linux"
    [ "$status" -eq 0 ]
    # dir##exe.ls is tainted by its annotated child — individual files
    [[ "$output" == *"dir##exe.ls/file1"* ]]
    [[ "$output" == *"dir##exe.ls/file2##os.linux"* ]]
    local line
    while IFS= read -r line; do
        [[ "$line" != "dir##exe.ls" ]]
    done <<< "$output"
}

@test "fold_targets: two annotated sibling directories fold independently" {
    # Two sibling annotated dirs, each with clean children
    run fold_all \
        ".config/zsh##shell.zsh/.zshrc" \
        ".config/zsh##no/plugins.zsh"
    [ "$status" -eq 0 ]
    [[ "$output" == *".config/zsh##shell.zsh"* ]]
    [[ "$output" == *".config/zsh##no"* ]]
    # .config cannot fold (has annotated children)
    local line
    while IFS= read -r line; do
        [[ "$line" != ".config" ]]
    done <<< "$output"
    local lines
    mapfile -t lines <<< "$output"
    [ "${#lines[@]}" -eq 2 ]
}

@test "fold_targets: nested annotated directories fold at deepest clean level" {
    # parent##a/child##b/file — child##b can fold, parent##a cannot (has annotated child)
    run fold_all \
        "parent##a/child##b/file1" \
        "parent##a/child##b/file2"
    [ "$status" -eq 0 ]
    local lines
    mapfile -t lines <<< "$output"
    [ "${#lines[@]}" -eq 1 ]
    [ "${lines[0]}" = "parent##a/child##b" ]
}

@test "fold_targets: annotated dir alongside clean sibling under barrier" {
    # .config barrier, zsh##shell.zsh folds, nvim folds, .config can't fold
    run fold_all --barrier=.config \
        ".config/zsh##shell.zsh/.zshrc" \
        ".config/zsh##shell.zsh/.p10k.zsh" \
        ".config/nvim/init.lua" \
        ".config/nvim/lua/plugins.lua"
    [ "$status" -eq 0 ]
    [[ "$output" == *".config/zsh##shell.zsh"* ]]
    [[ "$output" == *".config/nvim"* ]]
    local line
    while IFS= read -r line; do
        [[ "$line" != ".config" ]]
    done <<< "$output"
    local lines
    mapfile -t lines <<< "$output"
    [ "${#lines[@]}" -eq 2 ]
}

@test "fold_targets: real-world stow.sh##no folds as single entry" {
    # .local/lib/stow.sh##no/ has all clean children — folds at stow.sh##no
    run fold_all --barrier=.local/share --barrier=.local/bin \
        ".local/lib/stow.sh##no/src/main.sh" \
        ".local/lib/stow.sh##no/src/fold.sh" \
        ".local/lib/stow.sh##no/bin/stow.sh" \
        ".local/lib/stow.sh##no/Makefile"
    [ "$status" -eq 0 ]
    local lines
    mapfile -t lines <<< "$output"
    [ "${#lines[@]}" -eq 1 ]
    [ "${lines[0]}" = ".local/lib/stow.sh##no" ]
}

# =============================================================================
# XDG barrier folding
# =============================================================================

@test "fold_targets: barrier prevents folding at barrier dir" {
    # .config is a barrier — cannot fold .config itself
    run fold_all --barrier=.config \
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
    run fold_all --barrier=.local/share \
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
    run fold_all \
        --barrier=.config \
        --barrier=.local/share \
        --barrier=.cache \
        ".config/nvim/init.lua" \
        ".local/share/app/data.db" \
        ".local/share/app/cache/tmp" \
        ".local/state/myapp/log" \
        ".cache/myapp/tmp"
    [ "$status" -eq 0 ]
    # Children inside barriers can fold
    [[ "$output" == *".config/nvim"* ]]
    [[ "$output" == *".local/share/app"* ]]
    [[ "$output" == *".cache/myapp"* ]]
    # .local/state is NOT a barrier (only .local/share is) — but .local IS
    # a barrier (ancestor of .local/share). So .local/state can fold up to
    # (but not past) .local. .local/state itself is the shallowest fold point.
    [[ "$output" == *".local/state"* ]]
    # Barriers and their ancestors must not fold
    local line
    while IFS= read -r line; do
        [[ "$line" != ".local" ]]
        [[ "$line" != ".local/share" ]]
        [[ "$line" != ".config" ]]
        [[ "$line" != ".cache" ]]
    done <<< "$output"
}

@test "fold_targets: no barriers still works normally" {
    run fold_all \
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
    run fold_all --barrier=.config \
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
    run fold_all \
        --barrier=.local/bin \
        --barrier=.local/share \
        --barrier=.local/state \
        --barrier=.config \
        --barrier=.cache \
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
# Exclusion-aware folding (files on disk but not in candidates)
# =============================================================================

@test "fold_targets: excluded file prevents parent from folding" {
    # Create 2 files on disk but only pass 1 as a candidate
    create_pkg_files "a/b/file1" "a/b/file2"
    run stow_sh::fold_targets "$TEST_PKG" -- "a/b/file1"
    [ "$status" -eq 0 ]
    # a/b cannot fold (file2 exists on disk but isn't a candidate) — file1 individually
    [[ "$output" == *"a/b/file1"* ]]
    # a and a/b should NOT be fold points
    local line
    while IFS= read -r line; do
        [[ "$line" != "a" ]]
        [[ "$line" != "a/b" ]]
    done <<< "$output"
}

@test "fold_targets: exclusion taints only affected branch" {
    # a/clean has all files surviving, a/partial has one missing
    create_pkg_files "a/clean/f1" "a/clean/f2" "a/partial/f3" "a/partial/f4"
    run stow_sh::fold_targets "$TEST_PKG" -- \
        "a/clean/f1" "a/clean/f2" "a/partial/f3"
    [ "$status" -eq 0 ]
    # a/clean is foldable — all its files are candidates
    [[ "$output" == *"a/clean"* ]]
    # a/partial is not foldable — f3 appears individually
    [[ "$output" == *"a/partial/f3"* ]]
    # a cannot fold (a/partial is not foldable)
    local line
    while IFS= read -r line; do
        [[ "$line" != "a" ]]
        [[ "$line" != "a/partial" ]]
    done <<< "$output"
}

@test "fold_targets: exclusion + annotation + barrier combined" {
    # .config barrier, annotation in mise, excluded file in i3
    create_pkg_files \
        ".config/nvim/init.lua" ".config/nvim/lua/plugins.lua" \
        ".config/mise/conf.d/00-core.toml" ".config/mise/conf.d/20-desktop.toml##!docker" \
        ".config/i3/config" ".config/i3/scripts/lock.sh"

    # lock.sh is on disk but NOT in candidates (filtered out)
    run stow_sh::fold_targets --barrier=.config "$TEST_PKG" -- \
        ".config/nvim/init.lua" ".config/nvim/lua/plugins.lua" \
        ".config/mise/conf.d/00-core.toml" ".config/mise/conf.d/20-desktop.toml##!docker" \
        ".config/i3/config"
    [ "$status" -eq 0 ]
    # nvim: clean, inside barrier — folds
    [[ "$output" == *".config/nvim"* ]]
    # mise: tainted by annotation — individual files
    [[ "$output" == *"00-core.toml"* ]]
    [[ "$output" == *"20-desktop.toml##!docker"* ]]
    # i3: scripts/lock.sh on disk but not candidate — config individually
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
    run fold_all "a/b/f1" "a/b/f2" "a/c/f3"
    [ "$status" -eq 0 ]
    # a is the shallowest fold point — covers everything
    local lines
    mapfile -t lines <<< "$output"
    [ "${#lines[@]}" -eq 1 ]
    [ "${lines[0]}" = "a" ]
}

@test "fold_targets: all candidates empty gives empty output" {
    # No candidates — output should be empty
    run stow_sh::fold_targets "$TEST_PKG" --
    [ "$status" -eq 0 ]
    [ "$output" = "" ]
}

# =============================================================================
# Edge cases
# =============================================================================

@test "fold_targets: single flat file returns it as-is" {
    run fold_all ".bashrc"
    [ "$status" -eq 0 ]
    local lines
    mapfile -t lines <<< "$output"
    [ "${#lines[@]}" -eq 1 ]
    [ "${lines[0]}" = ".bashrc" ]
}

@test "fold_targets: expected output for discovery example" {
    # The exact example from the design doc
    run fold_all --barrier=.config \
        ".config/nvim/init.lua" ".config/nvim/lua/plugins.lua" \
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

@test "fold_targets: symlink-only subdirectory does not block folding" {
    # Simulates systemd's *.target.wants dirs that contain only symlinks
    # to system-installed services. These should not block the parent from
    # folding since scan_package (find -type f) never sees them.
    create_pkg_files \
        "systemd/user/foo.service" "systemd/user/bar.service"

    # Create a subdirectory with only a symlink (no regular files)
    mkdir -p "$TEST_PKG/systemd/user/default.target.wants"
    ln -s /etc/systemd/user/snap.service "$TEST_PKG/systemd/user/default.target.wants/snap.service"

    run stow_sh::fold_targets "$TEST_PKG" -- \
        "systemd/user/foo.service" "systemd/user/bar.service"
    [ "$status" -eq 0 ]
    # systemd/user should fold — default.target.wants has no regular files
    [[ "$output" == *"systemd"* ]]
    # Should be a single fold point, not individual files
    local lines
    mapfile -t lines <<< "$output"
    [ "${#lines[@]}" -eq 1 ]
    [ "${lines[0]}" = "systemd" ]
}

@test "fold_targets: empty subdirectory does not block folding" {
    # An empty subdirectory should not block the parent from folding
    create_pkg_files "a/f1" "a/f2"

    # Create an empty subdirectory
    mkdir -p "$TEST_PKG/a/empty"

    run stow_sh::fold_targets "$TEST_PKG" -- "a/f1" "a/f2"
    [ "$status" -eq 0 ]
    local lines
    mapfile -t lines <<< "$output"
    [ "${#lines[@]}" -eq 1 ]
    [ "${lines[0]}" = "a" ]
}
