#!/usr/bin/env bats
# SPDX-License-Identifier: MIT
# Copyright (c) 2025 David Kristiansen

# Tests for src/stow.sh — stow_package and unstow_package

setup() {
    source "$BATS_TEST_DIRNAME/../src/log.sh"
    source "$BATS_TEST_DIRNAME/../src/args.sh"
    source "$BATS_TEST_DIRNAME/../src/conditions.sh"
    source "$BATS_TEST_DIRNAME/../src/dotfiles.sh"
    source "$BATS_TEST_DIRNAME/../src/stow.sh"

    # Load built-in condition plugins
    export STOW_ROOT="$BATS_TEST_DIRNAME/.."
    stow_sh::load_condition_plugins

    # Create a tmpdir for each test
    TEST_DIR="$(mktemp -d)"
    PKG_DIR="$TEST_DIR/source/mypkg"
    TARGET_DIR="$TEST_DIR/target"
    mkdir -p "$PKG_DIR" "$TARGET_DIR"
}

teardown() {
    rm -rf "$TEST_DIR"
}

# =============================================================================
# stow_package — basic symlink creation
# =============================================================================

@test "stow_package creates symlink for a flat file" {
    echo "content" > "$PKG_DIR/.bashrc"

    run stow_sh::stow_package "$PKG_DIR" "$TARGET_DIR" ".bashrc"
    [ "$status" -eq 0 ]
    [ -L "$TARGET_DIR/.bashrc" ]
    [ "$(readlink -f "$TARGET_DIR/.bashrc")" = "$(readlink -f "$PKG_DIR/.bashrc")" ]
}

@test "stow_package creates symlink for a directory (fold point)" {
    mkdir -p "$PKG_DIR/.config/nvim/lua"
    echo "init" > "$PKG_DIR/.config/nvim/init.lua"
    echo "plugins" > "$PKG_DIR/.config/nvim/lua/plugins.lua"

    run stow_sh::stow_package "$PKG_DIR" "$TARGET_DIR" ".config/nvim"
    [ "$status" -eq 0 ]
    [ -L "$TARGET_DIR/.config/nvim" ]
    [ "$(readlink -f "$TARGET_DIR/.config/nvim")" = "$(readlink -f "$PKG_DIR/.config/nvim")" ]
    # Parent .config should be a real directory, not a symlink
    [ -d "$TARGET_DIR/.config" ]
    [ ! -L "$TARGET_DIR/.config" ]
}

@test "stow_package creates parent directories as needed" {
    mkdir -p "$PKG_DIR/.config/mise/conf.d"
    echo "core" > "$PKG_DIR/.config/mise/conf.d/00-core.toml"

    run stow_sh::stow_package "$PKG_DIR" "$TARGET_DIR" ".config/mise/conf.d/00-core.toml"
    [ "$status" -eq 0 ]
    [ -L "$TARGET_DIR/.config/mise/conf.d/00-core.toml" ]
    [ -d "$TARGET_DIR/.config/mise/conf.d" ]
    [ ! -L "$TARGET_DIR/.config/mise/conf.d" ]
}

@test "stow_package handles multiple targets" {
    echo "bashrc" > "$PKG_DIR/.bashrc"
    mkdir -p "$PKG_DIR/.config/nvim"
    echo "init" > "$PKG_DIR/.config/nvim/init.lua"

    run stow_sh::stow_package "$PKG_DIR" "$TARGET_DIR" ".bashrc" ".config/nvim"
    [ "$status" -eq 0 ]
    [ -L "$TARGET_DIR/.bashrc" ]
    [ -L "$TARGET_DIR/.config/nvim" ]
}

@test "stow_package skips already-stowed targets" {
    echo "content" > "$PKG_DIR/.bashrc"
    ln -s "$PKG_DIR/.bashrc" "$TARGET_DIR/.bashrc"

    run stow_sh::stow_package "$PKG_DIR" "$TARGET_DIR" ".bashrc"
    [ "$status" -eq 0 ]
    [[ "$output" == *"Already stowed"* ]] || [[ "$output" == *"already stowed"* ]] || [[ "$output" == "" ]]
    [ -L "$TARGET_DIR/.bashrc" ]
}

@test "stow_package returns error on source not found" {
    run stow_sh::stow_package "$PKG_DIR" "$TARGET_DIR" "nonexistent"
    [ "$status" -eq 1 ]
}

# =============================================================================
# stow_package — annotation handling
# =============================================================================

@test "stow_package strips ## annotation from link name" {
    mkdir -p "$PKG_DIR/.config/mise/conf.d"
    echo "core" > "$PKG_DIR/.config/mise/conf.d/20-desktop.toml##extension"

    run stow_sh::stow_package "$PKG_DIR" "$TARGET_DIR" \
        ".config/mise/conf.d/20-desktop.toml##extension"
    [ "$status" -eq 0 ]
    # Link should use sanitized name (no ##extension)
    [ -L "$TARGET_DIR/.config/mise/conf.d/20-desktop.toml" ]
    [ "$(readlink -f "$TARGET_DIR/.config/mise/conf.d/20-desktop.toml")" = \
      "$(readlink -f "$PKG_DIR/.config/mise/conf.d/20-desktop.toml##extension")" ]
}

@test "stow_package skips file when condition fails" {
    echo "content" > "$PKG_DIR/file##exe.this_command_definitely_does_not_exist_xyz"

    run stow_sh::stow_package "$PKG_DIR" "$TARGET_DIR" \
        "file##exe.this_command_definitely_does_not_exist_xyz"
    [ "$status" -eq 0 ]
    # File should NOT be linked — condition failed
    [ ! -e "$TARGET_DIR/file" ]
    [ ! -L "$TARGET_DIR/file" ]
}

@test "stow_package deploys file when condition passes" {
    # exe.bash should pass (bash is in PATH)
    echo "content" > "$PKG_DIR/file##exe.bash"

    run stow_sh::stow_package "$PKG_DIR" "$TARGET_DIR" "file##exe.bash"
    [ "$status" -eq 0 ]
    # Sanitized name "file" should exist as a symlink
    [ -L "$TARGET_DIR/file" ]
}

@test "stow_package handles negated condition" {
    echo "content" > "$PKG_DIR/file##!exe.this_command_definitely_does_not_exist_xyz"

    run stow_sh::stow_package "$PKG_DIR" "$TARGET_DIR" \
        "file##!exe.this_command_definitely_does_not_exist_xyz"
    [ "$status" -eq 0 ]
    # Negated condition for missing command should pass → file deployed
    [ -L "$TARGET_DIR/file" ]
}

# =============================================================================
# stow_package — conflict handling
# =============================================================================

@test "stow_package errors on conflict with existing file" {
    echo "pkg" > "$PKG_DIR/.bashrc"
    echo "existing" > "$TARGET_DIR/.bashrc"

    run stow_sh::stow_package "$PKG_DIR" "$TARGET_DIR" ".bashrc"
    [ "$status" -eq 1 ]
    [[ "$output" == *"Conflict"* ]]
    # Original file should be untouched
    [ "$(cat "$TARGET_DIR/.bashrc")" = "existing" ]
}

@test "stow_package errors on conflict with wrong symlink" {
    echo "pkg" > "$PKG_DIR/.bashrc"
    ln -s "/some/other/path" "$TARGET_DIR/.bashrc"

    run stow_sh::stow_package "$PKG_DIR" "$TARGET_DIR" ".bashrc"
    [ "$status" -eq 1 ]
    [[ "$output" == *"Conflict"* ]]
}

@test "stow_package --force overwrites conflicting symlink" {
    _stow_sh_force=true
    echo "pkg" > "$PKG_DIR/.bashrc"
    ln -s "/some/other/path" "$TARGET_DIR/.bashrc"

    run stow_sh::stow_package "$PKG_DIR" "$TARGET_DIR" ".bashrc"
    [ "$status" -eq 0 ]
    [ -L "$TARGET_DIR/.bashrc" ]
    [ "$(readlink -f "$TARGET_DIR/.bashrc")" = "$(readlink -f "$PKG_DIR/.bashrc")" ]
}

@test "stow_package --force overwrites conflicting file" {
    _stow_sh_force=true
    echo "pkg" > "$PKG_DIR/.bashrc"
    echo "existing" > "$TARGET_DIR/.bashrc"

    run stow_sh::stow_package "$PKG_DIR" "$TARGET_DIR" ".bashrc"
    [ "$status" -eq 0 ]
    [ -L "$TARGET_DIR/.bashrc" ]
    [ "$(readlink -f "$TARGET_DIR/.bashrc")" = "$(readlink -f "$PKG_DIR/.bashrc")" ]
}

@test "stow_package --adopt moves existing file into package" {
    _stow_sh_adopt=true
    echo "user content" > "$TARGET_DIR/.bashrc"
    echo "pkg content" > "$PKG_DIR/.bashrc"

    run stow_sh::stow_package "$PKG_DIR" "$TARGET_DIR" ".bashrc"
    [ "$status" -eq 0 ]
    # The existing file should have been moved into the package
    [ "$(cat "$PKG_DIR/.bashrc")" = "user content" ]
    # And a symlink should now exist
    [ -L "$TARGET_DIR/.bashrc" ]
    [ "$(readlink -f "$TARGET_DIR/.bashrc")" = "$(readlink -f "$PKG_DIR/.bashrc")" ]
}

# =============================================================================
# stow_package — dry-run mode
# =============================================================================

@test "stow_package --dry-run does not create symlinks" {
    _stow_sh_dry_run=true
    echo "content" > "$PKG_DIR/.bashrc"

    run stow_sh::stow_package "$PKG_DIR" "$TARGET_DIR" ".bashrc"
    [ "$status" -eq 0 ]
    [[ "$output" == *"WOULD link"* ]]
    # No actual symlink should be created
    [ ! -e "$TARGET_DIR/.bashrc" ]
    [ ! -L "$TARGET_DIR/.bashrc" ]
}

@test "stow_package --dry-run reports conflict resolution with --force" {
    _stow_sh_dry_run=true
    _stow_sh_force=true
    echo "pkg" > "$PKG_DIR/.bashrc"
    ln -s "/some/other/path" "$TARGET_DIR/.bashrc"

    run stow_sh::stow_package "$PKG_DIR" "$TARGET_DIR" ".bashrc"
    [ "$status" -eq 0 ]
    [[ "$output" == *"WOULD force"* ]]
    # Original symlink should be untouched
    [ "$(readlink "$TARGET_DIR/.bashrc")" = "/some/other/path" ]
}

@test "stow_package --dry-run reports adopt" {
    _stow_sh_dry_run=true
    _stow_sh_adopt=true
    echo "user content" > "$TARGET_DIR/.bashrc"
    echo "pkg content" > "$PKG_DIR/.bashrc"

    run stow_sh::stow_package "$PKG_DIR" "$TARGET_DIR" ".bashrc"
    [ "$status" -eq 0 ]
    [[ "$output" == *"WOULD adopt"* ]]
    # Nothing should actually change
    [ "$(cat "$TARGET_DIR/.bashrc")" = "user content" ]
    [ "$(cat "$PKG_DIR/.bashrc")" = "pkg content" ]
}

# =============================================================================
# unstow_package — basic symlink removal
# =============================================================================

@test "unstow_package removes symlink pointing to package" {
    echo "content" > "$PKG_DIR/.bashrc"
    ln -s "$PKG_DIR/.bashrc" "$TARGET_DIR/.bashrc"

    run stow_sh::unstow_package "$PKG_DIR" "$TARGET_DIR" ".bashrc"
    [ "$status" -eq 0 ]
    [ ! -e "$TARGET_DIR/.bashrc" ]
    [ ! -L "$TARGET_DIR/.bashrc" ]
}

@test "unstow_package removes directory symlink" {
    mkdir -p "$PKG_DIR/.config/nvim"
    echo "init" > "$PKG_DIR/.config/nvim/init.lua"
    mkdir -p "$TARGET_DIR/.config"
    ln -s "$PKG_DIR/.config/nvim" "$TARGET_DIR/.config/nvim"

    run stow_sh::unstow_package "$PKG_DIR" "$TARGET_DIR" ".config/nvim"
    [ "$status" -eq 0 ]
    [ ! -e "$TARGET_DIR/.config/nvim" ]
    [ ! -L "$TARGET_DIR/.config/nvim" ]
}

@test "unstow_package cleans up empty parent directories" {
    mkdir -p "$PKG_DIR/.config/mise/conf.d"
    echo "core" > "$PKG_DIR/.config/mise/conf.d/00-core.toml"
    mkdir -p "$TARGET_DIR/.config/mise/conf.d"
    ln -s "$PKG_DIR/.config/mise/conf.d/00-core.toml" "$TARGET_DIR/.config/mise/conf.d/00-core.toml"

    run stow_sh::unstow_package "$PKG_DIR" "$TARGET_DIR" ".config/mise/conf.d/00-core.toml"
    [ "$status" -eq 0 ]
    [ ! -e "$TARGET_DIR/.config/mise/conf.d/00-core.toml" ]
    # Empty dirs should be cleaned up
    [ ! -d "$TARGET_DIR/.config/mise/conf.d" ]
    [ ! -d "$TARGET_DIR/.config/mise" ]
    [ ! -d "$TARGET_DIR/.config" ]
}

@test "unstow_package does not remove non-empty parent directories" {
    mkdir -p "$PKG_DIR/.config/nvim"
    echo "init" > "$PKG_DIR/.config/nvim/init.lua"
    mkdir -p "$TARGET_DIR/.config"
    ln -s "$PKG_DIR/.config/nvim" "$TARGET_DIR/.config/nvim"
    echo "other" > "$TARGET_DIR/.config/other.conf"

    run stow_sh::unstow_package "$PKG_DIR" "$TARGET_DIR" ".config/nvim"
    [ "$status" -eq 0 ]
    [ ! -e "$TARGET_DIR/.config/nvim" ]
    # .config should remain (has other.conf)
    [ -d "$TARGET_DIR/.config" ]
    [ -f "$TARGET_DIR/.config/other.conf" ]
}

@test "unstow_package handles already-unstowed target" {
    echo "content" > "$PKG_DIR/.bashrc"
    # No symlink exists — already unstowed

    run stow_sh::unstow_package "$PKG_DIR" "$TARGET_DIR" ".bashrc"
    [ "$status" -eq 0 ]
}

@test "unstow_package refuses to remove symlink pointing elsewhere" {
    echo "content" > "$PKG_DIR/.bashrc"
    ln -s "/some/other/.bashrc" "$TARGET_DIR/.bashrc"

    run stow_sh::unstow_package "$PKG_DIR" "$TARGET_DIR" ".bashrc"
    [ "$status" -eq 1 ]
    [[ "$output" == *"Cannot unstow"* ]]
    # Symlink should be untouched
    [ -L "$TARGET_DIR/.bashrc" ]
}

@test "unstow_package refuses to remove non-symlink" {
    echo "content" > "$PKG_DIR/.bashrc"
    echo "real file" > "$TARGET_DIR/.bashrc"

    run stow_sh::unstow_package "$PKG_DIR" "$TARGET_DIR" ".bashrc"
    [ "$status" -eq 1 ]
    [[ "$output" == *"not a symlink"* ]]
    # File should be untouched
    [ "$(cat "$TARGET_DIR/.bashrc")" = "real file" ]
}

# =============================================================================
# unstow_package — annotation handling
# =============================================================================

@test "unstow_package handles annotated targets (sanitized link name)" {
    mkdir -p "$PKG_DIR/.config/mise/conf.d"
    echo "content" > "$PKG_DIR/.config/mise/conf.d/20-desktop.toml##extension"
    mkdir -p "$TARGET_DIR/.config/mise/conf.d"
    ln -s "$PKG_DIR/.config/mise/conf.d/20-desktop.toml##extension" \
        "$TARGET_DIR/.config/mise/conf.d/20-desktop.toml"

    run stow_sh::unstow_package "$PKG_DIR" "$TARGET_DIR" \
        ".config/mise/conf.d/20-desktop.toml##extension"
    [ "$status" -eq 0 ]
    [ ! -e "$TARGET_DIR/.config/mise/conf.d/20-desktop.toml" ]
}

# =============================================================================
# unstow_package — dry-run mode
# =============================================================================

@test "unstow_package --dry-run does not remove symlinks" {
    _stow_sh_dry_run=true
    echo "content" > "$PKG_DIR/.bashrc"
    ln -s "$PKG_DIR/.bashrc" "$TARGET_DIR/.bashrc"

    run stow_sh::unstow_package "$PKG_DIR" "$TARGET_DIR" ".bashrc"
    [ "$status" -eq 0 ]
    [[ "$output" == *"WOULD unlink"* ]]
    # Symlink should still exist
    [ -L "$TARGET_DIR/.bashrc" ]
}

# =============================================================================
# stow_package — auto-unfold (fold point vs existing real directory)
# =============================================================================

@test "stow_package auto-unfolds fold point when target is a real directory" {
    # Package has a fold point (directory)
    mkdir -p "$PKG_DIR/.config/nvim/lua"
    echo "init" > "$PKG_DIR/.config/nvim/init.lua"
    echo "plugins" > "$PKG_DIR/.config/nvim/lua/plugins.lua"

    # Target already has .config/nvim as a real directory (e.g. app-created files)
    mkdir -p "$TARGET_DIR/.config/nvim"
    echo "app data" > "$TARGET_DIR/.config/nvim/shada"

    # Stow the fold point — should auto-unfold and link children
    run stow_sh::stow_package "$PKG_DIR" "$TARGET_DIR" ".config/nvim"
    [ "$status" -eq 0 ]

    # init.lua should be an individual symlink (file)
    [ -L "$TARGET_DIR/.config/nvim/init.lua" ]
    [ "$(readlink -f "$TARGET_DIR/.config/nvim/init.lua")" = "$(readlink -f "$PKG_DIR/.config/nvim/init.lua")" ]

    # lua/ should be a directory symlink (folded — doesn't exist at target)
    [ -L "$TARGET_DIR/.config/nvim/lua" ]
    [ "$(readlink -f "$TARGET_DIR/.config/nvim/lua")" = "$(readlink -f "$PKG_DIR/.config/nvim/lua")" ]
    # Files inside should be accessible through the directory symlink
    [ -e "$TARGET_DIR/.config/nvim/lua/plugins.lua" ]

    # Existing app data should be untouched
    [ -f "$TARGET_DIR/.config/nvim/shada" ]
    [ "$(cat "$TARGET_DIR/.config/nvim/shada")" = "app data" ]

    # .config/nvim should still be a real directory, not a symlink
    [ -d "$TARGET_DIR/.config/nvim" ]
    [ ! -L "$TARGET_DIR/.config/nvim" ]
}

@test "stow_package auto-unfold handles already-stowed files inside real directory" {
    mkdir -p "$PKG_DIR/.config/nvim"
    echo "init" > "$PKG_DIR/.config/nvim/init.lua"

    # Target has the directory AND the file is already correctly symlinked
    mkdir -p "$TARGET_DIR/.config/nvim"
    ln -s "$PKG_DIR/.config/nvim/init.lua" "$TARGET_DIR/.config/nvim/init.lua"

    run stow_sh::stow_package "$PKG_DIR" "$TARGET_DIR" ".config/nvim"
    [ "$status" -eq 0 ]
    # Should succeed without error — file already stowed
    [ -L "$TARGET_DIR/.config/nvim/init.lua" ]
}

@test "stow_package auto-unfold --dry-run reports individual links" {
    _stow_sh_dry_run=true
    mkdir -p "$PKG_DIR/.config/nvim"
    echo "init" > "$PKG_DIR/.config/nvim/init.lua"

    mkdir -p "$TARGET_DIR/.config/nvim"
    echo "app data" > "$TARGET_DIR/.config/nvim/shada"

    run stow_sh::stow_package "$PKG_DIR" "$TARGET_DIR" ".config/nvim"
    [ "$status" -eq 0 ]
    [[ "$output" == *"WOULD link"* ]]
    # No actual symlinks should be created
    [ ! -L "$TARGET_DIR/.config/nvim/init.lua" ]
}

@test "stow_package auto-unfold errors on file conflict inside directory" {
    mkdir -p "$PKG_DIR/.config/nvim"
    echo "pkg init" > "$PKG_DIR/.config/nvim/init.lua"

    # Target has a real file at the same path (not a symlink)
    mkdir -p "$TARGET_DIR/.config/nvim"
    echo "existing init" > "$TARGET_DIR/.config/nvim/init.lua"

    run stow_sh::stow_package "$PKG_DIR" "$TARGET_DIR" ".config/nvim"
    [ "$status" -eq 1 ]
    [[ "$output" == *"Conflict"* ]]
    # Original file should be untouched
    [ "$(cat "$TARGET_DIR/.config/nvim/init.lua")" = "existing init" ]
}

@test "stow_package auto-unfold with --force overwrites file conflict inside directory" {
    _stow_sh_force=true
    mkdir -p "$PKG_DIR/.config/nvim"
    echo "pkg init" > "$PKG_DIR/.config/nvim/init.lua"

    mkdir -p "$TARGET_DIR/.config/nvim"
    echo "existing init" > "$TARGET_DIR/.config/nvim/init.lua"

    run stow_sh::stow_package "$PKG_DIR" "$TARGET_DIR" ".config/nvim"
    [ "$status" -eq 0 ]
    [ -L "$TARGET_DIR/.config/nvim/init.lua" ]
    [ "$(readlink -f "$TARGET_DIR/.config/nvim/init.lua")" = "$(readlink -f "$PKG_DIR/.config/nvim/init.lua")" ]
}

@test "stow_package still errors on file conflict (non-directory) without auto-unfold" {
    # Both source and target are files — should NOT auto-unfold
    echo "pkg" > "$PKG_DIR/.bashrc"
    echo "existing" > "$TARGET_DIR/.bashrc"

    run stow_sh::stow_package "$PKG_DIR" "$TARGET_DIR" ".bashrc"
    [ "$status" -eq 1 ]
    [[ "$output" == *"Conflict"* ]]
}

# =============================================================================
# unstow_package — auto-unfold (fold point vs existing real directory)
# =============================================================================

@test "unstow_package auto-unfolds when target is a real directory with individual links" {
    mkdir -p "$PKG_DIR/.config/nvim/lua"
    echo "init" > "$PKG_DIR/.config/nvim/init.lua"
    echo "plugins" > "$PKG_DIR/.config/nvim/lua/plugins.lua"

    # Target is a real directory with child symlinks (as created by auto-unfold stow):
    # init.lua is a file symlink, lua/ is a directory symlink (folded child)
    mkdir -p "$TARGET_DIR/.config/nvim"
    ln -s "$PKG_DIR/.config/nvim/init.lua" "$TARGET_DIR/.config/nvim/init.lua"
    ln -s "$PKG_DIR/.config/nvim/lua" "$TARGET_DIR/.config/nvim/lua"
    echo "app data" > "$TARGET_DIR/.config/nvim/shada"

    run stow_sh::unstow_package "$PKG_DIR" "$TARGET_DIR" ".config/nvim"
    [ "$status" -eq 0 ]

    # Symlinks should be removed
    [ ! -L "$TARGET_DIR/.config/nvim/init.lua" ]
    [ ! -L "$TARGET_DIR/.config/nvim/lua" ]

    # App data should be untouched
    [ -f "$TARGET_DIR/.config/nvim/shada" ]
    [ "$(cat "$TARGET_DIR/.config/nvim/shada")" = "app data" ]
}

@test "unstow_package auto-unfold cleans up empty subdirectories" {
    mkdir -p "$PKG_DIR/.config/nvim/lua"
    echo "init" > "$PKG_DIR/.config/nvim/init.lua"
    echo "plugins" > "$PKG_DIR/.config/nvim/lua/plugins.lua"

    # Target has only our symlinks (no app data) — lua is a dir symlink
    mkdir -p "$TARGET_DIR/.config/nvim"
    ln -s "$PKG_DIR/.config/nvim/init.lua" "$TARGET_DIR/.config/nvim/init.lua"
    ln -s "$PKG_DIR/.config/nvim/lua" "$TARGET_DIR/.config/nvim/lua"

    run stow_sh::unstow_package "$PKG_DIR" "$TARGET_DIR" ".config/nvim"
    [ "$status" -eq 0 ]

    # All symlinks should be removed
    [ ! -L "$TARGET_DIR/.config/nvim/init.lua" ]
    [ ! -L "$TARGET_DIR/.config/nvim/lua" ]
    # nvim/ should be cleaned up (empty after removing symlinks)
    [ ! -d "$TARGET_DIR/.config/nvim" ]
}

@test "unstow_package auto-unfold --dry-run reports individual unlinks" {
    _stow_sh_dry_run=true
    mkdir -p "$PKG_DIR/.config/nvim"
    echo "init" > "$PKG_DIR/.config/nvim/init.lua"

    mkdir -p "$TARGET_DIR/.config/nvim"
    ln -s "$PKG_DIR/.config/nvim/init.lua" "$TARGET_DIR/.config/nvim/init.lua"

    run stow_sh::unstow_package "$PKG_DIR" "$TARGET_DIR" ".config/nvim"
    [ "$status" -eq 0 ]
    [[ "$output" == *"WOULD unlink"* ]]
    # Symlink should still exist
    [ -L "$TARGET_DIR/.config/nvim/init.lua" ]
}

# =============================================================================
# auto-unfold — child directory folding
# =============================================================================

@test "stow_package auto-unfold folds child dirs that don't exist at target" {
    # Package has two subdirectories inside the fold point
    mkdir -p "$PKG_DIR/.config/opencode/agents"
    mkdir -p "$PKG_DIR/.config/opencode/themes"
    echo "review" > "$PKG_DIR/.config/opencode/agents/review.md"
    echo "docs" > "$PKG_DIR/.config/opencode/agents/docs.md"
    echo "dark" > "$PKG_DIR/.config/opencode/themes/dark.json"
    echo "config" > "$PKG_DIR/.config/opencode/opencode.json"

    # Target has .config/opencode as a real directory with app-generated files
    mkdir -p "$TARGET_DIR/.config/opencode"
    echo "lockfile" > "$TARGET_DIR/.config/opencode/bun.lock"

    run stow_sh::stow_package "$PKG_DIR" "$TARGET_DIR" ".config/opencode"
    [ "$status" -eq 0 ]

    # agents/ and themes/ should be directory symlinks (folded — don't exist at target)
    [ -L "$TARGET_DIR/.config/opencode/agents" ]
    [ -L "$TARGET_DIR/.config/opencode/themes" ]
    [ "$(readlink -f "$TARGET_DIR/.config/opencode/agents")" = "$(readlink -f "$PKG_DIR/.config/opencode/agents")" ]
    [ "$(readlink -f "$TARGET_DIR/.config/opencode/themes")" = "$(readlink -f "$PKG_DIR/.config/opencode/themes")" ]

    # Files inside should be accessible through directory symlinks
    [ -e "$TARGET_DIR/.config/opencode/agents/review.md" ]
    [ -e "$TARGET_DIR/.config/opencode/agents/docs.md" ]
    [ -e "$TARGET_DIR/.config/opencode/themes/dark.json" ]

    # opencode.json should be an individual file symlink
    [ -L "$TARGET_DIR/.config/opencode/opencode.json" ]

    # App data should be untouched
    [ -f "$TARGET_DIR/.config/opencode/bun.lock" ]
}

@test "stow_package auto-unfold recursively unfolds child dirs that exist at target" {
    # Package has nested structure
    mkdir -p "$PKG_DIR/.config/opencode/agents"
    mkdir -p "$PKG_DIR/.config/opencode/themes"
    echo "review" > "$PKG_DIR/.config/opencode/agents/review.md"
    echo "dark" > "$PKG_DIR/.config/opencode/themes/dark.json"
    echo "config" > "$PKG_DIR/.config/opencode/opencode.json"

    # Target has .config/opencode AND agents/ as real directories
    mkdir -p "$TARGET_DIR/.config/opencode/agents"
    echo "custom" > "$TARGET_DIR/.config/opencode/agents/custom.md"
    echo "lockfile" > "$TARGET_DIR/.config/opencode/bun.lock"

    run stow_sh::stow_package "$PKG_DIR" "$TARGET_DIR" ".config/opencode"
    [ "$status" -eq 0 ]

    # agents/ should remain a real directory (exists at target) — recursively auto-unfolded
    [ -d "$TARGET_DIR/.config/opencode/agents" ]
    [ ! -L "$TARGET_DIR/.config/opencode/agents" ]
    [ -L "$TARGET_DIR/.config/opencode/agents/review.md" ]

    # themes/ should be a directory symlink (doesn't exist at target)
    [ -L "$TARGET_DIR/.config/opencode/themes" ]

    # opencode.json is an individual file symlink
    [ -L "$TARGET_DIR/.config/opencode/opencode.json" ]

    # Existing files untouched
    [ -f "$TARGET_DIR/.config/opencode/agents/custom.md" ]
    [ "$(cat "$TARGET_DIR/.config/opencode/agents/custom.md")" = "custom" ]
    [ -f "$TARGET_DIR/.config/opencode/bun.lock" ]
}

@test "stow_package auto-unfold handles dotfiles inside directory" {
    mkdir -p "$PKG_DIR/.gnupg"
    echo "pinentry" > "$PKG_DIR/.gnupg/gpg-agent.conf"
    echo "hidden" > "$PKG_DIR/.gnupg/.gpg-hidden"

    mkdir -p "$TARGET_DIR/.gnupg"
    echo "secret" > "$TARGET_DIR/.gnupg/trustdb.gpg"

    run stow_sh::stow_package "$PKG_DIR" "$TARGET_DIR" ".gnupg"
    [ "$status" -eq 0 ]

    # Both regular and dotfiles should be symlinked
    [ -L "$TARGET_DIR/.gnupg/gpg-agent.conf" ]
    [ -L "$TARGET_DIR/.gnupg/.gpg-hidden" ]
    # Secrets untouched
    [ -f "$TARGET_DIR/.gnupg/trustdb.gpg" ]
}

@test "unstow_package auto-unfold removes folded child dirs and file symlinks" {
    mkdir -p "$PKG_DIR/.config/opencode/agents"
    mkdir -p "$PKG_DIR/.config/opencode/themes"
    echo "review" > "$PKG_DIR/.config/opencode/agents/review.md"
    echo "dark" > "$PKG_DIR/.config/opencode/themes/dark.json"
    echo "config" > "$PKG_DIR/.config/opencode/opencode.json"

    # Set up target as auto-unfold stow would create it:
    # agents/ and themes/ are directory symlinks, opencode.json is a file symlink
    mkdir -p "$TARGET_DIR/.config/opencode"
    ln -s "$PKG_DIR/.config/opencode/agents" "$TARGET_DIR/.config/opencode/agents"
    ln -s "$PKG_DIR/.config/opencode/themes" "$TARGET_DIR/.config/opencode/themes"
    ln -s "$PKG_DIR/.config/opencode/opencode.json" "$TARGET_DIR/.config/opencode/opencode.json"
    echo "lockfile" > "$TARGET_DIR/.config/opencode/bun.lock"

    run stow_sh::unstow_package "$PKG_DIR" "$TARGET_DIR" ".config/opencode"
    [ "$status" -eq 0 ]

    # All stow-created symlinks removed
    [ ! -L "$TARGET_DIR/.config/opencode/agents" ]
    [ ! -L "$TARGET_DIR/.config/opencode/themes" ]
    [ ! -L "$TARGET_DIR/.config/opencode/opencode.json" ]

    # App data untouched
    [ -f "$TARGET_DIR/.config/opencode/bun.lock" ]
}

# ============================================================
# Ancestor fold point detection during unstow
# ============================================================

@test "unstow_package detects ancestor fold point for individual files" {
    # Simulate: stow created .config -> pkg/.config (fold point),
    # but unstow is called with individual file targets (no-fold mode)
    mkdir -p "$PKG_DIR/.config/nvim"
    echo "init" > "$PKG_DIR/.config/nvim/init.lua"

    # Create the fold-point directory symlink manually
    ln -s "$PKG_DIR/.config" "$TARGET_DIR/.config"

    # Unstow with individual file target — should detect ancestor symlink
    run stow_sh::unstow_package "$PKG_DIR" "$TARGET_DIR" ".config/nvim/init.lua"
    [ "$status" -eq 0 ]

    # The ancestor fold point should be removed
    [ ! -e "$TARGET_DIR/.config" ]
}

@test "unstow_package ancestor detection handles multiple files under same fold point" {
    # When multiple files share the same ancestor fold point,
    # the first removes it and the rest see "already unstowed"
    mkdir -p "$PKG_DIR/.config/nvim/lua"
    echo "init" > "$PKG_DIR/.config/nvim/init.lua"
    echo "plugins" > "$PKG_DIR/.config/nvim/lua/plugins.lua"

    # Create the fold-point directory symlink
    ln -s "$PKG_DIR/.config" "$TARGET_DIR/.config"

    # Unstow with multiple individual file targets
    run stow_sh::unstow_package "$PKG_DIR" "$TARGET_DIR" \
        ".config/nvim/init.lua" ".config/nvim/lua/plugins.lua"
    [ "$status" -eq 0 ]

    # The ancestor fold point should be removed
    [ ! -e "$TARGET_DIR/.config" ]
}

@test "stow_package keeps an ancestor fold point that is still planned" {
    # The target list holds the fold point, so the run keeps it. Each file
    # below it is already stowed through the fold point.
    mkdir -p "$PKG_DIR/.config/nvim"
    echo "init" > "$PKG_DIR/.config/nvim/init.lua"

    # Create the fold-point directory symlink (as if stowed previously)
    ln -s "$PKG_DIR/.config" "$TARGET_DIR/.config"

    run stow_sh::stow_package "$PKG_DIR" "$TARGET_DIR" \
        ".config" ".config/nvim/init.lua"
    [ "$status" -eq 0 ]
    # Ancestor fold point should still be there (not unfolded, not duplicated)
    [ -L "$TARGET_DIR/.config" ]
    [ "$(readlink -f "$TARGET_DIR/.config")" = "$(readlink -f "$PKG_DIR/.config")" ]
}

# ============================================================
# Stale fold point re-evaluation
# ============================================================
#
# A fold point becomes stale when an earlier run folded a directory and the
# current run does not resolve that directory as a fold point. The usual
# cause is a file that the filter removes, such as a gitignored file. A fold
# point that stays serves that file from inside the package.

@test "stow_package unfolds a stale fold point and evicts unplanned files" {
    mkdir -p "$PKG_DIR/.appdir"
    git -C "$PKG_DIR" init -q
    echo "cfg" > "$PKG_DIR/.appdir/config.toml"
    echo "local" > "$PKG_DIR/.appdir/local.conf"

    # An earlier run folded the whole directory
    ln -s "$PKG_DIR/.appdir" "$TARGET_DIR/.appdir"

    # This run resolves config.toml only. The filter removed local.conf.
    run stow_sh::stow_package "$PKG_DIR" "$TARGET_DIR" ".appdir/config.toml"
    [ "$status" -eq 0 ]

    # A real directory and a per-file link replace the fold point
    [ -d "$TARGET_DIR/.appdir" ] && [ ! -L "$TARGET_DIR/.appdir" ]
    [ -L "$TARGET_DIR/.appdir/config.toml" ]
    [ "$(readlink -f "$TARGET_DIR/.appdir/config.toml")" = "$(readlink -f "$PKG_DIR/.appdir/config.toml")" ]

    # The run moves the unplanned file out of the package to the target
    [ -f "$TARGET_DIR/.appdir/local.conf" ] && [ ! -L "$TARGET_DIR/.appdir/local.conf" ]
    [ "$(cat "$TARGET_DIR/.appdir/local.conf")" = "local" ]
    [ ! -e "$PKG_DIR/.appdir/local.conf" ]
}

@test "stow_package stale unfold recurses into subdirectories" {
    mkdir -p "$PKG_DIR/.appdir/sub"
    git -C "$PKG_DIR" init -q
    echo "cfg" > "$PKG_DIR/.appdir/sub/config.toml"
    echo "state" > "$PKG_DIR/.appdir/sub/state.db"
    echo "log" > "$PKG_DIR/.appdir/app.log"

    ln -s "$PKG_DIR/.appdir" "$TARGET_DIR/.appdir"

    run stow_sh::stow_package "$PKG_DIR" "$TARGET_DIR" ".appdir/sub/config.toml"
    [ "$status" -eq 0 ]

    # Both levels become real directories
    [ -d "$TARGET_DIR/.appdir" ] && [ ! -L "$TARGET_DIR/.appdir" ]
    [ -d "$TARGET_DIR/.appdir/sub" ] && [ ! -L "$TARGET_DIR/.appdir/sub" ]
    [ -L "$TARGET_DIR/.appdir/sub/config.toml" ]

    # The run moves the unplanned files at both levels
    [ -f "$TARGET_DIR/.appdir/app.log" ] && [ ! -L "$TARGET_DIR/.appdir/app.log" ]
    [ -f "$TARGET_DIR/.appdir/sub/state.db" ] && [ ! -L "$TARGET_DIR/.appdir/sub/state.db" ]
    [ ! -e "$PKG_DIR/.appdir/app.log" ]
    [ ! -e "$PKG_DIR/.appdir/sub/state.db" ]
}

@test "stow_package stale unfold evicts an unplanned directory whole" {
    mkdir -p "$PKG_DIR/.appdir/cache/inner"
    git -C "$PKG_DIR" init -q
    echo "cfg" > "$PKG_DIR/.appdir/config.toml"
    echo "blob" > "$PKG_DIR/.appdir/cache/inner/blob.bin"

    ln -s "$PKG_DIR/.appdir" "$TARGET_DIR/.appdir"

    run stow_sh::stow_package "$PKG_DIR" "$TARGET_DIR" ".appdir/config.toml"
    [ "$status" -eq 0 ]

    # The plan holds nothing under cache/, so the directory moves as a unit
    [ -d "$TARGET_DIR/.appdir/cache/inner" ] && [ ! -L "$TARGET_DIR/.appdir/cache" ]
    [ "$(cat "$TARGET_DIR/.appdir/cache/inner/blob.bin")" = "blob" ]
    [ ! -e "$PKG_DIR/.appdir/cache" ]
}

@test "stow_package stale unfold keeps a planned fold point inside it" {
    mkdir -p "$PKG_DIR/.appdir/sub"
    git -C "$PKG_DIR" init -q
    echo "cfg" > "$PKG_DIR/.appdir/sub/config.toml"
    echo "local" > "$PKG_DIR/.appdir/local.conf"

    ln -s "$PKG_DIR/.appdir" "$TARGET_DIR/.appdir"

    # .appdir/sub is still foldable. Only .appdir became stale.
    run stow_sh::stow_package "$PKG_DIR" "$TARGET_DIR" ".appdir/sub"
    [ "$status" -eq 0 ]

    [ -d "$TARGET_DIR/.appdir" ] && [ ! -L "$TARGET_DIR/.appdir" ]
    # The run links the inner fold point and does not unfold it
    [ -L "$TARGET_DIR/.appdir/sub" ]
    [ "$(readlink -f "$TARGET_DIR/.appdir/sub")" = "$(readlink -f "$PKG_DIR/.appdir/sub")" ]
    [ ! -e "$PKG_DIR/.appdir/local.conf" ]
    [ -f "$TARGET_DIR/.appdir/local.conf" ]
}

@test "stow_package stale unfold reports one unfold for many files" {
    mkdir -p "$PKG_DIR/.appdir"
    git -C "$PKG_DIR" init -q
    echo "a" > "$PKG_DIR/.appdir/a.toml"
    echo "b" > "$PKG_DIR/.appdir/b.toml"
    echo "local" > "$PKG_DIR/.appdir/local.conf"

    ln -s "$PKG_DIR/.appdir" "$TARGET_DIR/.appdir"

    run stow_sh::stow_package "$PKG_DIR" "$TARGET_DIR" \
        ".appdir/a.toml" ".appdir/b.toml"
    [ "$status" -eq 0 ]
    [ "$(grep -c "unfold" <<< "$output")" -eq 1 ]
    [ -L "$TARGET_DIR/.appdir/a.toml" ]
    [ -L "$TARGET_DIR/.appdir/b.toml" ]
    [ -f "$TARGET_DIR/.appdir/local.conf" ]
}

@test "stow_package --dry-run reports a stale unfold without touching anything" {
    _stow_sh_dry_run=true
    mkdir -p "$PKG_DIR/.appdir"
    git -C "$PKG_DIR" init -q
    echo "cfg" > "$PKG_DIR/.appdir/config.toml"
    echo "local" > "$PKG_DIR/.appdir/local.conf"

    ln -s "$PKG_DIR/.appdir" "$TARGET_DIR/.appdir"

    run stow_sh::stow_package "$PKG_DIR" "$TARGET_DIR" ".appdir/config.toml"
    [ "$status" -eq 0 ]
    [[ "$output" == *"WOULD unfold"* ]]
    [[ "$output" == *"WOULD evict"* ]]

    # Nothing on disk changes
    [ -L "$TARGET_DIR/.appdir" ]
    [ -f "$PKG_DIR/.appdir/local.conf" ]
}

@test "stow_package stale unfold translates dot- names under --dotfiles" {
    _stow_sh_dotfiles=true
    mkdir -p "$PKG_DIR/dot-appdir"
    git -C "$PKG_DIR" init -q
    echo "cfg" > "$PKG_DIR/dot-appdir/config.toml"
    echo "local" > "$PKG_DIR/dot-appdir/local.conf"

    ln -s "$PKG_DIR/dot-appdir" "$TARGET_DIR/.appdir"

    run stow_sh::stow_package "$PKG_DIR" "$TARGET_DIR" "dot-appdir/config.toml"
    [ "$status" -eq 0 ]

    [ -d "$TARGET_DIR/.appdir" ] && [ ! -L "$TARGET_DIR/.appdir" ]
    [ -L "$TARGET_DIR/.appdir/config.toml" ]
    [ -f "$TARGET_DIR/.appdir/local.conf" ]
    [ ! -e "$PKG_DIR/dot-appdir/local.conf" ]
}

@test "stow_package stale unfold refuses to evict a tracked file" {
    mkdir -p "$PKG_DIR/.appdir"
    git -C "$PKG_DIR" init -q
    echo "cfg" > "$PKG_DIR/.appdir/config.toml"
    echo "doc" > "$PKG_DIR/.appdir/notes.md"
    git -C "$PKG_DIR" add -A
    git -C "$PKG_DIR" -c user.email=t@t -c user.name=t commit -qm init

    ln -s "$PKG_DIR/.appdir" "$TARGET_DIR/.appdir"

    # The plan excludes notes.md, but git tracks it — a transient filter,
    # not application state. The move must not happen.
    run stow_sh::stow_package "$PKG_DIR" "$TARGET_DIR" ".appdir/config.toml"
    [ "$status" -eq 1 ]
    [[ "$output" == *"Refusing to evict"* ]]
    [ -f "$PKG_DIR/.appdir/notes.md" ]
}

@test "stow_package --no-evict keeps a stale fold point and warns" {
    _stow_sh_evict=false
    mkdir -p "$PKG_DIR/.appdir"
    git -C "$PKG_DIR" init -q
    echo "cfg" > "$PKG_DIR/.appdir/config.toml"
    echo "local" > "$PKG_DIR/.appdir/local.conf"

    ln -s "$PKG_DIR/.appdir" "$TARGET_DIR/.appdir"

    run stow_sh::stow_package "$PKG_DIR" "$TARGET_DIR" ".appdir/config.toml"
    [ "$status" -eq 0 ]
    [[ "$output" == *"Stale fold point kept"* ]]

    # Nothing moves, and the fold point stays
    [ -L "$TARGET_DIR/.appdir" ]
    [ -f "$PKG_DIR/.appdir/local.conf" ]
}

@test "stow_package keeps a stale fold point when the package is outside git" {
    mkdir -p "$PKG_DIR/.appdir"
    echo "cfg" > "$PKG_DIR/.appdir/config.toml"
    echo "local" > "$PKG_DIR/.appdir/local.conf"

    ln -s "$PKG_DIR/.appdir" "$TARGET_DIR/.appdir"

    # No git work tree — stow.sh cannot classify the files, so it holds
    run stow_sh::stow_package "$PKG_DIR" "$TARGET_DIR" ".appdir/config.toml"
    [ "$status" -eq 0 ]
    [[ "$output" == *"outside a git work tree"* ]]
    [ -L "$TARGET_DIR/.appdir" ]
    [ -f "$PKG_DIR/.appdir/local.conf" ]
}

@test "stow_package links correctly through a symlinked intermediate dir" {
    # A pre-existing symlinked dir under the target (e.g. a user's
    # ~/.config -> elsewhere) disables the pure-bash relative-path fast
    # path in __create_link; the realpath fallback must still produce a
    # link that resolves to the package file.
    mkdir -p "$PKG_DIR/.config/app"
    echo "content" > "$PKG_DIR/.config/app/conf.toml"

    # target/.config is a symlink pointing OUTSIDE the package
    mkdir -p "$TEST_DIR/elsewhere"
    ln -s "$TEST_DIR/elsewhere" "$TARGET_DIR/.config"

    run stow_sh::stow_package "$PKG_DIR" "$TARGET_DIR" ".config/app/conf.toml"
    [ "$status" -eq 0 ]
    [ -L "$TARGET_DIR/.config/app/conf.toml" ]
    [ "$(cat "$TARGET_DIR/.config/app/conf.toml")" = "content" ]
    [ "$(readlink -f "$TARGET_DIR/.config/app/conf.toml")" = "$(readlink -f "$PKG_DIR/.config/app/conf.toml")" ]

    # Re-stow must detect "already stowed" through the same fallback
    run stow_sh::stow_package "$PKG_DIR" "$TARGET_DIR" ".config/app/conf.toml"
    [ "$status" -eq 0 ]
}
