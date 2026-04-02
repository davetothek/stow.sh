#!/usr/bin/env bats
# SPDX-License-Identifier: MIT
# Copyright (c) 2025 David Kristiansen

# Tests for src/stow.sh — stow_package and unstow_package

setup() {
    source "$BATS_TEST_DIRNAME/../src/log.sh"
    source "$BATS_TEST_DIRNAME/../src/args.sh"
    source "$BATS_TEST_DIRNAME/../src/conditions.sh"
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
    [[ "$output" == *"Already stowed"* ]] || [[ "$output" == "" ]]
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
    [[ "$output" == *"WOULD remove"* ]]
    [[ "$output" == *"WOULD link"* ]]
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
