#!/usr/bin/env bats
# SPDX-License-Identifier: MIT
# Copyright (c) 2025 David Kristiansen
#
# Integration tests for stow.sh — end-to-end tests via bin/stow.sh entrypoint.
# Each test creates a fresh tmpdir with source/target dirs and runs the full
# pipeline: parse → scan → filter → fold → stow/unstow.

STOW_SH="$BATS_TEST_DIRNAME/../bin/stow.sh"

setup() {
    TEST_DIR="$(mktemp -d)"
    SOURCE_DIR="$TEST_DIR/dotfiles"
    TARGET_DIR="$TEST_DIR/home"
    mkdir -p "$SOURCE_DIR" "$TARGET_DIR"
}

teardown() {
    rm -rf "$TEST_DIR"
}

# ============================================================
# Basic stow operations
# ============================================================

@test "integration: stow flat files" {
    local pkg="$SOURCE_DIR/pkg"
    mkdir -p "$pkg"
    echo "content" > "$pkg/.bashrc"
    echo "content" > "$pkg/.profile"

    run "$STOW_SH" -G --no-xdg -d "$SOURCE_DIR" -t "$TARGET_DIR" -S pkg
    [ "$status" -eq 0 ]
    [ -L "$TARGET_DIR/.bashrc" ]
    [ -L "$TARGET_DIR/.profile" ]
    [ "$(readlink -f "$TARGET_DIR/.bashrc")" = "$(readlink -f "$pkg/.bashrc")" ]
}

@test "integration: stow nested files creates parent dirs" {
    local pkg="$SOURCE_DIR/pkg"
    mkdir -p "$pkg/.config/nvim/lua"
    echo "init" > "$pkg/.config/nvim/init.lua"
    echo "plugins" > "$pkg/.config/nvim/lua/plugins.lua"

    run "$STOW_SH" -G --no-xdg --no-folding -d "$SOURCE_DIR" -t "$TARGET_DIR" -S pkg
    [ "$status" -eq 0 ]
    [ -L "$TARGET_DIR/.config/nvim/init.lua" ]
    [ -L "$TARGET_DIR/.config/nvim/lua/plugins.lua" ]
    # Parent dirs should be real directories, not symlinks
    [ -d "$TARGET_DIR/.config" ] && [ ! -L "$TARGET_DIR/.config" ]
    [ -d "$TARGET_DIR/.config/nvim" ] && [ ! -L "$TARGET_DIR/.config/nvim" ]
}

@test "integration: stow with directory folding" {
    local pkg="$SOURCE_DIR/pkg"
    mkdir -p "$pkg/.config/nvim/lua"
    echo "init" > "$pkg/.config/nvim/init.lua"
    echo "plugins" > "$pkg/.config/nvim/lua/plugins.lua"

    run "$STOW_SH" -G --no-xdg -d "$SOURCE_DIR" -t "$TARGET_DIR" -S pkg
    [ "$status" -eq 0 ]
    # With folding, .config should be a single symlink (no barriers, no annotations)
    [ -L "$TARGET_DIR/.config" ]
    [ "$(readlink -f "$TARGET_DIR/.config")" = "$(readlink -f "$pkg/.config")" ]
}

@test "integration: stow with --no-folding creates individual links" {
    local pkg="$SOURCE_DIR/pkg"
    mkdir -p "$pkg/.config/nvim"
    echo "init" > "$pkg/.config/nvim/init.lua"

    run "$STOW_SH" -G --no-xdg --no-folding -d "$SOURCE_DIR" -t "$TARGET_DIR" -S pkg
    [ "$status" -eq 0 ]
    # .config should be a real directory, not a symlink
    [ -d "$TARGET_DIR/.config" ] && [ ! -L "$TARGET_DIR/.config" ]
    [ -L "$TARGET_DIR/.config/nvim/init.lua" ]
}

# ============================================================
# XDG fold barriers
# ============================================================

@test "integration: XDG barrier prevents folding at .config" {
    local pkg="$SOURCE_DIR/pkg"
    mkdir -p "$pkg/.config/nvim/lua"
    echo "init" > "$pkg/.config/nvim/init.lua"
    echo "plugins" > "$pkg/.config/nvim/lua/plugins.lua"

    # Set XDG_CONFIG_HOME to TARGET_DIR/.config so .config becomes a barrier
    XDG_CONFIG_HOME="$TARGET_DIR/.config" \
        run "$STOW_SH" -G -d "$SOURCE_DIR" -t "$TARGET_DIR" -S pkg
    [ "$status" -eq 0 ]
    # .config must be a real directory (barrier), not a symlink
    [ -d "$TARGET_DIR/.config" ] && [ ! -L "$TARGET_DIR/.config" ]
    # But .config/nvim can be folded (child of barrier)
    [ -L "$TARGET_DIR/.config/nvim" ]
    [ "$(readlink -f "$TARGET_DIR/.config/nvim")" = "$(readlink -f "$pkg/.config/nvim")" ]
}

@test "integration: --no-xdg ignores XDG barriers" {
    local pkg="$SOURCE_DIR/pkg"
    mkdir -p "$pkg/.config/nvim"
    echo "init" > "$pkg/.config/nvim/init.lua"

    # Even with XDG_CONFIG_HOME set, --no-xdg disables barriers
    XDG_CONFIG_HOME="$TARGET_DIR/.config" \
        run "$STOW_SH" -G --no-xdg -d "$SOURCE_DIR" -t "$TARGET_DIR" -S pkg
    [ "$status" -eq 0 ]
    # .config should be folded into a symlink since barriers are disabled
    [ -L "$TARGET_DIR/.config" ]
}

@test "integration: XDG barrier with .local/share subtree" {
    local pkg="$SOURCE_DIR/pkg"
    mkdir -p "$pkg/.local/share/nvim/site"
    echo "data" > "$pkg/.local/share/nvim/site/plugin.vim"
    mkdir -p "$pkg/.local/bin"
    echo "#!/bin/sh" > "$pkg/.local/bin/mytool"

    XDG_DATA_HOME="$TARGET_DIR/.local/share" \
    XDG_BIN_HOME="$TARGET_DIR/.local/bin" \
        run "$STOW_SH" -G -d "$SOURCE_DIR" -t "$TARGET_DIR" -S pkg
    [ "$status" -eq 0 ]
    # .local must be a real dir (ancestor of barriers)
    [ -d "$TARGET_DIR/.local" ] && [ ! -L "$TARGET_DIR/.local" ]
    # .local/share must be a real dir (barrier itself)
    [ -d "$TARGET_DIR/.local/share" ] && [ ! -L "$TARGET_DIR/.local/share" ]
    # .local/share/nvim can be folded (child of barrier)
    [ -L "$TARGET_DIR/.local/share/nvim" ]
    # .local/bin is a barrier, so it must be a real dir; its contents are individual
    [ -d "$TARGET_DIR/.local/bin" ] && [ ! -L "$TARGET_DIR/.local/bin" ]
    [ -L "$TARGET_DIR/.local/bin/mytool" ]
}

# ============================================================
# Conditional dotfiles (## annotations)
# ============================================================

@test "integration: annotation strips ## from link name" {
    local pkg="$SOURCE_DIR/pkg"
    mkdir -p "$pkg"
    echo "content" > "$pkg/.bashrc##shell.bash"

    # Use a shell that is bash so the condition passes
    SHELL="/bin/bash" \
        run "$STOW_SH" -G --no-xdg -d "$SOURCE_DIR" -t "$TARGET_DIR" -S pkg
    [ "$status" -eq 0 ]
    # Link should use sanitized name (no ##)
    [ -L "$TARGET_DIR/.bashrc" ]
    [ "$(readlink -f "$TARGET_DIR/.bashrc")" = "$(readlink -f "$pkg/.bashrc##shell.bash")" ]
    # The raw annotated name should NOT exist
    [ ! -e "$TARGET_DIR/.bashrc##shell.bash" ]
}

@test "integration: annotation skips file when condition fails" {
    local pkg="$SOURCE_DIR/pkg"
    mkdir -p "$pkg"
    echo "content" > "$pkg/.zshrc##shell.zsh"
    echo "always" > "$pkg/.profile"

    # Use bash as shell, so shell.zsh condition fails
    SHELL="/bin/bash" \
        run "$STOW_SH" -G --no-xdg -d "$SOURCE_DIR" -t "$TARGET_DIR" -S pkg
    [ "$status" -eq 0 ]
    # .profile should be stowed (no condition)
    [ -L "$TARGET_DIR/.profile" ]
    # .zshrc should NOT be stowed (condition failed)
    [ ! -e "$TARGET_DIR/.zshrc" ]
    [ ! -e "$TARGET_DIR/.zshrc##shell.zsh" ]
}

@test "integration: negated annotation deploys when condition is false" {
    local pkg="$SOURCE_DIR/pkg"
    mkdir -p "$pkg"
    echo "content" > "$pkg/.config##!docker"

    # We're (almost certainly) not in Docker
    run "$STOW_SH" -G --no-xdg -d "$SOURCE_DIR" -t "$TARGET_DIR" -S pkg
    [ "$status" -eq 0 ]
    [ -L "$TARGET_DIR/.config" ]
}

@test "integration: annotation blocks directory folding" {
    local pkg="$SOURCE_DIR/pkg"
    mkdir -p "$pkg/.config/mise/conf.d"
    echo "core" > "$pkg/.config/mise/conf.d/00-core.toml"
    echo "desktop" > "$pkg/.config/mise/conf.d/20-desktop.toml##!docker"
    echo "main" > "$pkg/.config/mise/config.toml"

    run "$STOW_SH" -G --no-xdg -d "$SOURCE_DIR" -t "$TARGET_DIR" -S pkg
    [ "$status" -eq 0 ]
    # .config/mise cannot be folded because it has an annotated descendant
    [ -d "$TARGET_DIR/.config" ] && [ ! -L "$TARGET_DIR/.config" ]
    [ -d "$TARGET_DIR/.config/mise" ] && [ ! -L "$TARGET_DIR/.config/mise" ]
    # Individual files should be symlinked
    [ -L "$TARGET_DIR/.config/mise/config.toml" ]
    [ -L "$TARGET_DIR/.config/mise/conf.d/00-core.toml" ]
    # The annotated file should be deployed with sanitized name (assuming !docker passes)
    [ -L "$TARGET_DIR/.config/mise/conf.d/20-desktop.toml" ]
}

@test "integration: exe condition with existing command" {
    local pkg="$SOURCE_DIR/pkg"
    mkdir -p "$pkg"
    # 'ls' exists on all systems
    echo "content" > "$pkg/.tool##exe.ls"

    run "$STOW_SH" -G --no-xdg -d "$SOURCE_DIR" -t "$TARGET_DIR" -S pkg
    [ "$status" -eq 0 ]
    [ -L "$TARGET_DIR/.tool" ]
}

@test "integration: exe condition with missing command" {
    local pkg="$SOURCE_DIR/pkg"
    mkdir -p "$pkg"
    echo "content" > "$pkg/.tool##exe.totally_nonexistent_command_xyz123"

    run "$STOW_SH" -G --no-xdg -d "$SOURCE_DIR" -t "$TARGET_DIR" -S pkg
    [ "$status" -eq 0 ]
    [ ! -e "$TARGET_DIR/.tool" ]
}

# ============================================================
# Unstow operations (-D)
# ============================================================

@test "integration: unstow removes symlinks" {
    local pkg="$SOURCE_DIR/pkg"
    mkdir -p "$pkg"
    echo "content" > "$pkg/.bashrc"
    echo "content" > "$pkg/.profile"

    # First stow
    "$STOW_SH" -G --no-xdg -d "$SOURCE_DIR" -t "$TARGET_DIR" -S pkg
    [ -L "$TARGET_DIR/.bashrc" ]
    [ -L "$TARGET_DIR/.profile" ]

    # Then unstow
    run "$STOW_SH" -G --no-xdg -d "$SOURCE_DIR" -t "$TARGET_DIR" -D pkg
    [ "$status" -eq 0 ]
    [ ! -e "$TARGET_DIR/.bashrc" ]
    [ ! -e "$TARGET_DIR/.profile" ]
}

@test "integration: unstow removes directory symlinks (fold points)" {
    local pkg="$SOURCE_DIR/pkg"
    mkdir -p "$pkg/.config/nvim"
    echo "init" > "$pkg/.config/nvim/init.lua"

    # Stow with folding
    "$STOW_SH" -G --no-xdg -d "$SOURCE_DIR" -t "$TARGET_DIR" -S pkg
    [ -L "$TARGET_DIR/.config" ]

    # Unstow
    run "$STOW_SH" -G --no-xdg -d "$SOURCE_DIR" -t "$TARGET_DIR" -D pkg
    [ "$status" -eq 0 ]
    [ ! -e "$TARGET_DIR/.config" ]
}

@test "integration: unstow cleans up empty parent directories" {
    local pkg="$SOURCE_DIR/pkg"
    mkdir -p "$pkg/.config/app"
    echo "config" > "$pkg/.config/app/settings.toml"

    # Stow without folding so we get individual links and real dirs
    "$STOW_SH" -G --no-xdg --no-folding -d "$SOURCE_DIR" -t "$TARGET_DIR" -S pkg
    [ -L "$TARGET_DIR/.config/app/settings.toml" ]

    # Unstow
    run "$STOW_SH" -G --no-xdg --no-folding -d "$SOURCE_DIR" -t "$TARGET_DIR" -D pkg
    [ "$status" -eq 0 ]
    [ ! -e "$TARGET_DIR/.config/app/settings.toml" ]
    # Empty parent dirs should be cleaned up
    [ ! -d "$TARGET_DIR/.config/app" ]
    [ ! -d "$TARGET_DIR/.config" ]
}

# ============================================================
# Restow operations (-R)
# ============================================================

@test "integration: restow refreshes symlinks" {
    local pkg="$SOURCE_DIR/pkg"
    mkdir -p "$pkg"
    echo "v1" > "$pkg/.bashrc"

    # Initial stow
    "$STOW_SH" -G --no-xdg -d "$SOURCE_DIR" -t "$TARGET_DIR" -S pkg
    [ -L "$TARGET_DIR/.bashrc" ]

    # Modify the package and restow
    echo "v2" > "$pkg/.profile"
    run "$STOW_SH" -G --no-xdg -d "$SOURCE_DIR" -t "$TARGET_DIR" -R pkg
    [ "$status" -eq 0 ]
    # Both files should be stowed
    [ -L "$TARGET_DIR/.bashrc" ]
    [ -L "$TARGET_DIR/.profile" ]
}

# ============================================================
# Dry-run mode (-n)
# ============================================================

@test "integration: dry-run does not create symlinks" {
    local pkg="$SOURCE_DIR/pkg"
    mkdir -p "$pkg"
    echo "content" > "$pkg/.bashrc"

    run "$STOW_SH" -G --no-xdg -n -d "$SOURCE_DIR" -t "$TARGET_DIR" -S pkg
    [ "$status" -eq 0 ]
    [ ! -e "$TARGET_DIR/.bashrc" ]
    # Output should contain WOULD messages
    [[ "$output" == *"WOULD"* ]]
}

@test "integration: dry-run unstow does not remove symlinks" {
    local pkg="$SOURCE_DIR/pkg"
    mkdir -p "$pkg"
    echo "content" > "$pkg/.bashrc"

    # First actually stow
    "$STOW_SH" -G --no-xdg -d "$SOURCE_DIR" -t "$TARGET_DIR" -S pkg
    [ -L "$TARGET_DIR/.bashrc" ]

    # Dry-run unstow
    run "$STOW_SH" -G --no-xdg -n -d "$SOURCE_DIR" -t "$TARGET_DIR" -D pkg
    [ "$status" -eq 0 ]
    # Symlink should still exist
    [ -L "$TARGET_DIR/.bashrc" ]
    [[ "$output" == *"WOULD"* ]]
}

# ============================================================
# Force mode (-f)
# ============================================================

@test "integration: force overwrites conflicting file" {
    local pkg="$SOURCE_DIR/pkg"
    mkdir -p "$pkg"
    echo "from-pkg" > "$pkg/.bashrc"

    # Create a conflicting file in target
    echo "existing" > "$TARGET_DIR/.bashrc"

    run "$STOW_SH" -G --no-xdg -f -d "$SOURCE_DIR" -t "$TARGET_DIR" -S pkg
    [ "$status" -eq 0 ]
    [ -L "$TARGET_DIR/.bashrc" ]
    [ "$(readlink -f "$TARGET_DIR/.bashrc")" = "$(readlink -f "$pkg/.bashrc")" ]
}

@test "integration: force overwrites conflicting symlink" {
    local pkg="$SOURCE_DIR/pkg"
    mkdir -p "$pkg"
    echo "from-pkg" > "$pkg/.bashrc"

    # Create a conflicting symlink in target
    ln -s /dev/null "$TARGET_DIR/.bashrc"

    run "$STOW_SH" -G --no-xdg -f -d "$SOURCE_DIR" -t "$TARGET_DIR" -S pkg
    [ "$status" -eq 0 ]
    [ -L "$TARGET_DIR/.bashrc" ]
    [ "$(readlink -f "$TARGET_DIR/.bashrc")" = "$(readlink -f "$pkg/.bashrc")" ]
}

@test "integration: without force, conflict causes error" {
    local pkg="$SOURCE_DIR/pkg"
    mkdir -p "$pkg"
    echo "from-pkg" > "$pkg/.bashrc"

    # Create a conflicting file
    echo "existing" > "$TARGET_DIR/.bashrc"

    run "$STOW_SH" -G --no-xdg -d "$SOURCE_DIR" -t "$TARGET_DIR" -S pkg
    [ "$status" -eq 1 ]
    # The conflicting file should still be the original
    [ ! -L "$TARGET_DIR/.bashrc" ]
    [ "$(cat "$TARGET_DIR/.bashrc")" = "existing" ]
}

@test "integration: force refuses to delete a real directory" {
    local pkg="$SOURCE_DIR/pkg"
    mkdir -p "$pkg"
    echo "from-pkg" > "$pkg/foo"

    # Target has a real, populated directory where a file wants to go.
    mkdir -p "$TARGET_DIR/foo"
    echo "precious" > "$TARGET_DIR/foo/keep.txt"

    run "$STOW_SH" -G --no-xdg -f -d "$SOURCE_DIR" -t "$TARGET_DIR" -S pkg
    [ "$status" -eq 1 ]
    # The real directory and its contents must be untouched.
    [ -d "$TARGET_DIR/foo" ] && [ ! -L "$TARGET_DIR/foo" ]
    [ "$(cat "$TARGET_DIR/foo/keep.txt")" = "precious" ]
}

# ============================================================
# Atomicity — conflict pre-flight (all-or-nothing)
# ============================================================

@test "integration: conflict aborts with zero changes (no partial apply)" {
    local pkg="$SOURCE_DIR/pkg"
    mkdir -p "$pkg"
    echo "A" > "$pkg/aaa"   # would-be-clean link
    echo "Z" > "$pkg/zzz"   # conflicts with a real file below

    echo "existing" > "$TARGET_DIR/zzz"

    run "$STOW_SH" -G --no-xdg -d "$SOURCE_DIR" -t "$TARGET_DIR" -S pkg
    [ "$status" -eq 1 ]
    # The non-conflicting link must NOT have been created — the whole run
    # aborts before touching the filesystem.
    [ ! -e "$TARGET_DIR/aaa" ]
    # The conflicting file is left exactly as it was.
    [ ! -L "$TARGET_DIR/zzz" ]
    [ "$(cat "$TARGET_DIR/zzz")" = "existing" ]
}

@test "integration: a conflict in one package blocks all packages" {
    mkdir -p "$SOURCE_DIR/clean" "$SOURCE_DIR/dirty"
    echo "ok" > "$SOURCE_DIR/clean/good"
    echo "x" > "$SOURCE_DIR/dirty/bad"

    # Only the second package conflicts.
    echo "existing" > "$TARGET_DIR/bad"

    run "$STOW_SH" -G --no-xdg -d "$SOURCE_DIR" -t "$TARGET_DIR" -S clean dirty
    [ "$status" -eq 1 ]
    # The clean package must not be applied either — abort is global.
    [ ! -e "$TARGET_DIR/good" ]
    [ "$(cat "$TARGET_DIR/bad")" = "existing" ]
}

@test "integration: force directory-refusal is atomic (no partial apply)" {
    local pkg="$SOURCE_DIR/pkg"
    mkdir -p "$pkg"
    echo "A" > "$pkg/aaa"
    echo "from-pkg" > "$pkg/foo"

    mkdir -p "$TARGET_DIR/foo"
    echo "precious" > "$TARGET_DIR/foo/keep.txt"

    run "$STOW_SH" -G --no-xdg -f -d "$SOURCE_DIR" -t "$TARGET_DIR" -S pkg
    [ "$status" -eq 1 ]
    # Pre-flight catches the directory refusal, so the clean link is not made.
    [ ! -e "$TARGET_DIR/aaa" ]
    [ -d "$TARGET_DIR/foo" ] && [ ! -L "$TARGET_DIR/foo" ]
    [ "$(cat "$TARGET_DIR/foo/keep.txt")" = "precious" ]
}

# ============================================================
# Adopt mode (--adopt)
# ============================================================

@test "integration: adopt moves existing file into package" {
    local pkg="$SOURCE_DIR/pkg"
    mkdir -p "$pkg"
    echo "placeholder" > "$pkg/.bashrc"

    # Create a file in target that should be adopted
    echo "custom-content" > "$TARGET_DIR/.bashrc"

    run "$STOW_SH" -G --no-xdg --adopt -d "$SOURCE_DIR" -t "$TARGET_DIR" -S pkg
    [ "$status" -eq 0 ]
    # Target should now be a symlink
    [ -L "$TARGET_DIR/.bashrc" ]
    # The package file should have the target's content (adopted)
    [ "$(cat "$pkg/.bashrc")" = "custom-content" ]
}

# ============================================================
# Multiple packages
# ============================================================

@test "integration: stow multiple packages" {
    mkdir -p "$SOURCE_DIR/bash"
    echo "bashrc" > "$SOURCE_DIR/bash/.bashrc"
    mkdir -p "$SOURCE_DIR/vim"
    echo "vimrc" > "$SOURCE_DIR/vim/.vimrc"

    run "$STOW_SH" -G --no-xdg -d "$SOURCE_DIR" -t "$TARGET_DIR" -S bash vim
    [ "$status" -eq 0 ]
    [ -L "$TARGET_DIR/.bashrc" ]
    [ -L "$TARGET_DIR/.vimrc" ]
}

@test "integration: unstow one of multiple stowed packages" {
    mkdir -p "$SOURCE_DIR/bash"
    echo "bashrc" > "$SOURCE_DIR/bash/.bashrc"
    mkdir -p "$SOURCE_DIR/vim"
    echo "vimrc" > "$SOURCE_DIR/vim/.vimrc"

    # Stow both
    "$STOW_SH" -G --no-xdg -d "$SOURCE_DIR" -t "$TARGET_DIR" -S bash vim

    # Unstow only vim
    run "$STOW_SH" -G --no-xdg -d "$SOURCE_DIR" -t "$TARGET_DIR" -D vim
    [ "$status" -eq 0 ]
    [ -L "$TARGET_DIR/.bashrc" ]
    [ ! -e "$TARGET_DIR/.vimrc" ]
}

# ============================================================
# Ignore patterns
# ============================================================

@test "integration: regex ignore excludes matching files" {
    local pkg="$SOURCE_DIR/pkg"
    mkdir -p "$pkg"
    echo "keep" > "$pkg/.bashrc"
    echo "skip" > "$pkg/README.md"
    echo "skip" > "$pkg/LICENSE"

    run "$STOW_SH" -G --no-xdg -d "$SOURCE_DIR" -t "$TARGET_DIR" \
        -i 'README\.md' -i 'LICENSE' -S pkg
    [ "$status" -eq 0 ]
    [ -L "$TARGET_DIR/.bashrc" ]
    [ ! -e "$TARGET_DIR/README.md" ]
    [ ! -e "$TARGET_DIR/LICENSE" ]
}

@test "integration: glob ignore excludes matching files" {
    local pkg="$SOURCE_DIR/pkg"
    mkdir -p "$pkg"
    echo "keep" > "$pkg/.bashrc"
    echo "skip" > "$pkg/notes.txt"
    echo "skip" > "$pkg/todo.txt"

    run "$STOW_SH" -G --no-xdg -d "$SOURCE_DIR" -t "$TARGET_DIR" \
        -I '*.txt' -S pkg
    [ "$status" -eq 0 ]
    [ -L "$TARGET_DIR/.bashrc" ]
    [ ! -e "$TARGET_DIR/notes.txt" ]
    [ ! -e "$TARGET_DIR/todo.txt" ]
}

# ============================================================
# Error cases
# ============================================================

@test "integration: missing package directory causes error" {
    run "$STOW_SH" -G --no-xdg -d "$SOURCE_DIR" -t "$TARGET_DIR" -S nonexistent
    [ "$status" -ne 0 ]
}

@test "integration: empty source dir uses self-stow mode (no-op)" {
    # Create an empty source dir with no subdirectories and no files
    local empty_src="$TEST_DIR/empty_src"
    mkdir -p "$empty_src"

    # Should succeed (self-stow mode activates) but produce no symlinks
    run "$STOW_SH" -G --no-xdg -d "$empty_src" -t "$TARGET_DIR"
    [ "$status" -eq 0 ]
}

# ============================================================
# Idempotency
# ============================================================

@test "integration: stowing twice is idempotent" {
    local pkg="$SOURCE_DIR/pkg"
    mkdir -p "$pkg"
    echo "content" > "$pkg/.bashrc"

    "$STOW_SH" -G --no-xdg -d "$SOURCE_DIR" -t "$TARGET_DIR" -S pkg
    run "$STOW_SH" -G --no-xdg -d "$SOURCE_DIR" -t "$TARGET_DIR" -S pkg
    [ "$status" -eq 0 ]
    [ -L "$TARGET_DIR/.bashrc" ]
}

@test "integration: unstowing twice is idempotent" {
    local pkg="$SOURCE_DIR/pkg"
    mkdir -p "$pkg"
    echo "content" > "$pkg/.bashrc"

    "$STOW_SH" -G --no-xdg -d "$SOURCE_DIR" -t "$TARGET_DIR" -S pkg
    "$STOW_SH" -G --no-xdg -d "$SOURCE_DIR" -t "$TARGET_DIR" -D pkg
    run "$STOW_SH" -G --no-xdg -d "$SOURCE_DIR" -t "$TARGET_DIR" -D pkg
    [ "$status" -eq 0 ]
    [ ! -e "$TARGET_DIR/.bashrc" ]
}

# ============================================================
# Self-stow mode (source dir is the package)
# ============================================================

@test "integration: self-stow mode stows source dir directly into target" {
    # Simulate ~/.dotfiles structure: source dir IS the package
    local dotfiles="$TEST_DIR/dotfiles"
    mkdir -p "$dotfiles/.config/nvim"
    echo "bashrc" > "$dotfiles/.bashrc"
    echo "init" > "$dotfiles/.config/nvim/init.lua"

    # No -S flag, no subdirectory packages — triggers self-stow
    run "$STOW_SH" -G --no-xdg -d "$dotfiles" -t "$TARGET_DIR"
    [ "$status" -eq 0 ]
    [ -L "$TARGET_DIR/.bashrc" ]
    # With folding on and no barriers, .config should be folded
    [ -L "$TARGET_DIR/.config" ]
}

@test "integration: self-stow with ignore patterns" {
    local dotfiles="$TEST_DIR/dotfiles"
    mkdir -p "$dotfiles"
    echo "bashrc" > "$dotfiles/.bashrc"
    echo "readme" > "$dotfiles/README.md"
    echo "bootstrap" > "$dotfiles/bootstrap"

    run "$STOW_SH" -G --no-xdg -d "$dotfiles" -t "$TARGET_DIR" \
        -i 'README\.md' -i 'bootstrap'
    [ "$status" -eq 0 ]
    [ -L "$TARGET_DIR/.bashrc" ]
    [ ! -e "$TARGET_DIR/README.md" ]
    [ ! -e "$TARGET_DIR/bootstrap" ]
}

@test "integration: self-stow with annotations and XDG barriers" {
    local dotfiles="$TEST_DIR/dotfiles"
    mkdir -p "$dotfiles/.config/nvim"
    mkdir -p "$dotfiles/.config/mise/conf.d"
    echo "init" > "$dotfiles/.config/nvim/init.lua"
    echo "core" > "$dotfiles/.config/mise/conf.d/00-core.toml"
    echo "desktop" > "$dotfiles/.config/mise/conf.d/20-desktop.toml##!docker"
    echo "bashrc" > "$dotfiles/.bashrc"

    XDG_CONFIG_HOME="$TARGET_DIR/.config" \
        run "$STOW_SH" -G -d "$dotfiles" -t "$TARGET_DIR"
    [ "$status" -eq 0 ]
    [ -L "$TARGET_DIR/.bashrc" ]
    [ -d "$TARGET_DIR/.config" ] && [ ! -L "$TARGET_DIR/.config" ]
    [ -L "$TARGET_DIR/.config/nvim" ]
    [ -d "$TARGET_DIR/.config/mise" ] && [ ! -L "$TARGET_DIR/.config/mise" ]
    [ -L "$TARGET_DIR/.config/mise/conf.d/00-core.toml" ]
    [ -L "$TARGET_DIR/.config/mise/conf.d/20-desktop.toml" ]
}

# ============================================================
# Directory-level condition propagation
# ============================================================

@test "integration: ##no on directory skips all files inside" {
    local dotfiles="$TEST_DIR/dotfiles"
    mkdir -p "$dotfiles/.local/lib/stow.sh##no/src"
    mkdir -p "$dotfiles/.config/nvim"
    echo "main" > "$dotfiles/.local/lib/stow.sh##no/src/main.sh"
    echo "readme" > "$dotfiles/.local/lib/stow.sh##no/README.md"
    echo "init" > "$dotfiles/.config/nvim/init.lua"
    echo "bashrc" > "$dotfiles/.bashrc"

    run "$STOW_SH" -G --no-xdg -d "$dotfiles" -t "$TARGET_DIR"
    [ "$status" -eq 0 ]
    [ -L "$TARGET_DIR/.bashrc" ]
    [ -L "$TARGET_DIR/.config" ]
    # Everything under stow.sh##no should be skipped
    [ ! -e "$TARGET_DIR/.local/lib/stow.sh/src/main.sh" ]
    [ ! -e "$TARGET_DIR/.local/lib/stow.sh/README.md" ]
    [ ! -e "$TARGET_DIR/.local/lib/stow.sh" ]
}

@test "integration: condition on directory passes deploys files inside" {
    local pkg="$SOURCE_DIR/pkg"
    mkdir -p "$pkg/tools##exe.ls"
    echo "config" > "$pkg/tools##exe.ls/config.toml"
    echo "bashrc" > "$pkg/.bashrc"

    run "$STOW_SH" -G --no-xdg -d "$SOURCE_DIR" -t "$TARGET_DIR" -S pkg
    [ "$status" -eq 0 ]
    [ -L "$TARGET_DIR/.bashrc" ]
    # ls exists, so tools##exe.ls condition passes — directory folds into
    # a single symlink (annotated dir with clean children is a fold point)
    [ -L "$TARGET_DIR/tools" ]
    [ -e "$TARGET_DIR/tools/config.toml" ]
}

@test "integration: annotated directory ##no folds and skips as one unit" {
    local pkg="$SOURCE_DIR/pkg"
    mkdir -p "$pkg/.local/lib/stow.sh##no/src"
    echo "main" > "$pkg/.local/lib/stow.sh##no/src/main.sh"
    echo "fold" > "$pkg/.local/lib/stow.sh##no/src/fold.sh"
    echo "readme" > "$pkg/.local/lib/stow.sh##no/README.md"
    echo "bashrc" > "$pkg/.bashrc"

    run "$STOW_SH" -G --no-xdg -d "$SOURCE_DIR" -t "$TARGET_DIR" -S pkg
    [ "$status" -eq 0 ]
    [ -L "$TARGET_DIR/.bashrc" ]
    # stow.sh##no folds but condition fails — nothing deployed under .local/lib/stow.sh
    [ ! -e "$TARGET_DIR/.local/lib/stow.sh" ]
    [ ! -e "$TARGET_DIR/.local/lib/stow.sh/src/main.sh" ]
}

@test "integration: annotated directory condition passes creates directory symlink" {
    local pkg="$SOURCE_DIR/pkg"
    mkdir -p "$pkg/.config/zsh##exe.ls"
    echo "zshrc" > "$pkg/.config/zsh##exe.ls/.zshrc"
    echo "p10k" > "$pkg/.config/zsh##exe.ls/.p10k.zsh"
    echo "bashrc" > "$pkg/.bashrc"

    XDG_CONFIG_HOME="$TARGET_DIR/.config" \
        run "$STOW_SH" -G -d "$SOURCE_DIR" -t "$TARGET_DIR" -S pkg
    [ "$status" -eq 0 ]
    [ -L "$TARGET_DIR/.bashrc" ]
    # zsh##exe.ls folds into a single directory symlink (ls exists)
    [ -L "$TARGET_DIR/.config/zsh" ]
    [ -e "$TARGET_DIR/.config/zsh/.zshrc" ]
    [ -e "$TARGET_DIR/.config/zsh/.p10k.zsh" ]
    # .config must be a real dir (barrier)
    [ -d "$TARGET_DIR/.config" ] && [ ! -L "$TARGET_DIR/.config" ]
}

@test "integration: directory ## and file ## both stripped from symlink names" {
    local pkg="$SOURCE_DIR/pkg"
    mkdir -p "$pkg/.config/systemd##!docker/user"
    echo "[Unit]" > "$pkg/.config/systemd##!docker/user/gammastep@.service##exe.true"
    echo "[Unit]" > "$pkg/.config/systemd##!docker/user/kanshi.service##exe.ls"
    echo "[Unit]" > "$pkg/.config/systemd##!docker/user/swayidle.service##wm.ls"

    XDG_CONFIG_HOME="$TARGET_DIR/.config" \
        run "$STOW_SH" -G -d "$SOURCE_DIR" -t "$TARGET_DIR" -S pkg
    [ "$status" -eq 0 ]

    # .config/systemd/user must be a real dir (unfold forced by child annotations)
    [ -d "$TARGET_DIR/.config/systemd/user" ] && [ ! -L "$TARGET_DIR/.config/systemd/user" ]

    # Symlinks should have ## stripped from BOTH directory and file names
    [ -L "$TARGET_DIR/.config/systemd/user/gammastep@.service" ]
    [ -L "$TARGET_DIR/.config/systemd/user/kanshi.service" ]
    [ -L "$TARGET_DIR/.config/systemd/user/swayidle.service" ]

    # The raw annotated names must NOT exist on disk
    [ ! -e "$TARGET_DIR/.config/systemd##!docker" ]
    [ ! -e "$TARGET_DIR/.config/systemd/user/gammastep@.service##exe.true" ]
    [ ! -e "$TARGET_DIR/.config/systemd/user/kanshi.service##exe.ls" ]
}

@test "integration: directory ## and file ## skips when file condition fails" {
    local pkg="$SOURCE_DIR/pkg"
    mkdir -p "$pkg/.config/systemd##!docker/user"
    # exe.nonexistent_xyz will fail
    echo "[Unit]" > "$pkg/.config/systemd##!docker/user/nope.service##exe.nonexistent_xyz"
    # exe.ls will pass
    echo "[Unit]" > "$pkg/.config/systemd##!docker/user/yes.service##exe.ls"

    XDG_CONFIG_HOME="$TARGET_DIR/.config" \
        run "$STOW_SH" -G -d "$SOURCE_DIR" -t "$TARGET_DIR" -S pkg
    [ "$status" -eq 0 ]

    # yes.service deployed (both !docker and exe.ls pass)
    [ -L "$TARGET_DIR/.config/systemd/user/yes.service" ]
    # nope.service skipped (exe.nonexistent_xyz fails)
    [ ! -e "$TARGET_DIR/.config/systemd/user/nope.service" ]
    [ ! -e "$TARGET_DIR/.config/systemd/user/nope.service##exe.nonexistent_xyz" ]
}

@test "integration: unstow annotated directory fold point" {
    local pkg="$SOURCE_DIR/pkg"
    mkdir -p "$pkg/tools##exe.ls"
    echo "config" > "$pkg/tools##exe.ls/config.toml"

    # Stow first
    run "$STOW_SH" -G --no-xdg -d "$SOURCE_DIR" -t "$TARGET_DIR" -S pkg
    [ "$status" -eq 0 ]
    [ -L "$TARGET_DIR/tools" ]

    # Unstow
    run "$STOW_SH" -G --no-xdg -d "$SOURCE_DIR" -t "$TARGET_DIR" -D pkg
    [ "$status" -eq 0 ]
    [ ! -e "$TARGET_DIR/tools" ]
}

# ============================================================
# Real-world scenario: mixed package with annotations + XDG
# ============================================================

@test "integration: real-world dotfiles package with annotations and XDG" {
    local pkg="$SOURCE_DIR/dotfiles"
    mkdir -p "$pkg/.config/nvim/lua"
    mkdir -p "$pkg/.config/mise/conf.d"
    mkdir -p "$pkg/.local/bin"

    echo "init" > "$pkg/.config/nvim/init.lua"
    echo "plugins" > "$pkg/.config/nvim/lua/plugins.lua"
    echo "core" > "$pkg/.config/mise/conf.d/00-core.toml"
    echo "desktop" > "$pkg/.config/mise/conf.d/20-desktop.toml##!docker"
    echo "config" > "$pkg/.config/mise/config.toml"
    echo "#!/bin/sh" > "$pkg/.local/bin/mytool"
    echo "bashrc" > "$pkg/.bashrc"

    XDG_CONFIG_HOME="$TARGET_DIR/.config" \
    XDG_BIN_HOME="$TARGET_DIR/.local/bin" \
    SHELL="/bin/bash" \
        run "$STOW_SH" -G -d "$SOURCE_DIR" -t "$TARGET_DIR" -S dotfiles
    [ "$status" -eq 0 ]

    # Flat file
    [ -L "$TARGET_DIR/.bashrc" ]

    # .config is a barrier (must be real dir)
    [ -d "$TARGET_DIR/.config" ] && [ ! -L "$TARGET_DIR/.config" ]

    # .config/nvim is a clean subtree (no annotations) — should be folded
    [ -L "$TARGET_DIR/.config/nvim" ]

    # .config/mise has annotated descendant — cannot be folded
    [ -d "$TARGET_DIR/.config/mise" ] && [ ! -L "$TARGET_DIR/.config/mise" ]
    [ -L "$TARGET_DIR/.config/mise/config.toml" ]
    [ -L "$TARGET_DIR/.config/mise/conf.d/00-core.toml" ]
    # Annotated file deployed with sanitized name (assuming !docker passes)
    [ -L "$TARGET_DIR/.config/mise/conf.d/20-desktop.toml" ]

    # .local/bin is a barrier (must be real dir)
    [ -d "$TARGET_DIR/.local/bin" ] && [ ! -L "$TARGET_DIR/.local/bin" ]
    [ -L "$TARGET_DIR/.local/bin/mytool" ]
}

# ============================================================
# Auto-unfold (fold point vs existing real directory)
# ============================================================

@test "integration: auto-unfold when target directory already exists" {
    local pkg="$SOURCE_DIR/pkg"
    mkdir -p "$pkg/.config/nvim/lua"
    echo "init" > "$pkg/.config/nvim/init.lua"
    echo "plugins" > "$pkg/.config/nvim/lua/plugins.lua"

    # Pre-create .config/nvim as a real directory with app-generated files
    mkdir -p "$TARGET_DIR/.config/nvim"
    echo "app data" > "$TARGET_DIR/.config/nvim/shada"

    # Stow — folding would normally create .config/nvim symlink,
    # but auto-unfold should kick in since it's a real directory
    XDG_CONFIG_HOME="$TARGET_DIR/.config" \
        run "$STOW_SH" -G -d "$SOURCE_DIR" -t "$TARGET_DIR" -S pkg
    [ "$status" -eq 0 ]

    # .config/nvim should remain a real directory
    [ -d "$TARGET_DIR/.config/nvim" ] && [ ! -L "$TARGET_DIR/.config/nvim" ]

    # init.lua should be an individual file symlink
    [ -L "$TARGET_DIR/.config/nvim/init.lua" ]

    # lua/ should be a directory symlink (folded child — doesn't exist at target)
    [ -L "$TARGET_DIR/.config/nvim/lua" ]
    [ -e "$TARGET_DIR/.config/nvim/lua/plugins.lua" ]

    # App data should be untouched
    [ -f "$TARGET_DIR/.config/nvim/shada" ]
    [ "$(cat "$TARGET_DIR/.config/nvim/shada")" = "app data" ]
}

@test "integration: auto-unfold stow then unstow cleans up individual links" {
    local pkg="$SOURCE_DIR/pkg"
    mkdir -p "$pkg/.config/app/sub"
    echo "conf1" > "$pkg/.config/app/config.toml"
    echo "conf2" > "$pkg/.config/app/sub/extra.toml"

    # Pre-create target with app-generated files
    mkdir -p "$TARGET_DIR/.config/app"
    echo "app state" > "$TARGET_DIR/.config/app/state.db"

    # Stow (auto-unfold) — sub/ becomes a directory symlink (doesn't exist at target)
    XDG_CONFIG_HOME="$TARGET_DIR/.config" \
        run "$STOW_SH" -G -d "$SOURCE_DIR" -t "$TARGET_DIR" -S pkg
    [ "$status" -eq 0 ]
    [ -L "$TARGET_DIR/.config/app/config.toml" ]
    [ -L "$TARGET_DIR/.config/app/sub" ]
    [ -e "$TARGET_DIR/.config/app/sub/extra.toml" ]

    # Unstow (auto-unfold inverse)
    XDG_CONFIG_HOME="$TARGET_DIR/.config" \
        run "$STOW_SH" -G -d "$SOURCE_DIR" -t "$TARGET_DIR" -D pkg
    [ "$status" -eq 0 ]

    # Symlinks should be removed
    [ ! -L "$TARGET_DIR/.config/app/config.toml" ]
    [ ! -L "$TARGET_DIR/.config/app/sub" ]

    # App state should be untouched
    [ -f "$TARGET_DIR/.config/app/state.db" ]
    [ "$(cat "$TARGET_DIR/.config/app/state.db")" = "app state" ]
}

@test "integration: auto-unfold dry-run shows individual WOULD link messages" {
    local pkg="$SOURCE_DIR/pkg"
    mkdir -p "$pkg/.config/nvim"
    echo "init" > "$pkg/.config/nvim/init.lua"

    # Pre-create target directory
    mkdir -p "$TARGET_DIR/.config/nvim"
    echo "app data" > "$TARGET_DIR/.config/nvim/shada"

    XDG_CONFIG_HOME="$TARGET_DIR/.config" \
        run "$STOW_SH" -G -n -d "$SOURCE_DIR" -t "$TARGET_DIR" -S pkg
    [ "$status" -eq 0 ]
    [[ "$output" == *"WOULD link"* ]]
    # No actual symlinks
    [ ! -L "$TARGET_DIR/.config/nvim/init.lua" ]
}

@test "integration: auto-unfold is idempotent (stow twice)" {
    local pkg="$SOURCE_DIR/pkg"
    mkdir -p "$pkg/.config/nvim"
    echo "init" > "$pkg/.config/nvim/init.lua"

    mkdir -p "$TARGET_DIR/.config/nvim"
    echo "app data" > "$TARGET_DIR/.config/nvim/shada"

    # Stow once
    XDG_CONFIG_HOME="$TARGET_DIR/.config" \
        "$STOW_SH" -G -d "$SOURCE_DIR" -t "$TARGET_DIR" -S pkg

    # Stow again — should succeed (already stowed via auto-unfold)
    XDG_CONFIG_HOME="$TARGET_DIR/.config" \
        run "$STOW_SH" -G -d "$SOURCE_DIR" -t "$TARGET_DIR" -S pkg
    [ "$status" -eq 0 ]
    [ -L "$TARGET_DIR/.config/nvim/init.lua" ]
    [ -f "$TARGET_DIR/.config/nvim/shada" ]
}

@test "integration: real-world gnupg scenario (only gpg-agent.conf in dotfiles)" {
    local pkg="$SOURCE_DIR/pkg"
    mkdir -p "$pkg/.gnupg"
    echo "pinentry-program /usr/bin/pinentry-gnome3" > "$pkg/.gnupg/gpg-agent.conf"

    # Simulate existing ~/.gnupg with secrets
    mkdir -p "$TARGET_DIR/.gnupg/private-keys-v1.d"
    echo "secret" > "$TARGET_DIR/.gnupg/trustdb.gpg"
    echo "key" > "$TARGET_DIR/.gnupg/private-keys-v1.d/mykey.key"

    run "$STOW_SH" -G --no-xdg -d "$SOURCE_DIR" -t "$TARGET_DIR" -S pkg
    [ "$status" -eq 0 ]

    # .gnupg should remain a real directory (auto-unfolded)
    [ -d "$TARGET_DIR/.gnupg" ] && [ ! -L "$TARGET_DIR/.gnupg" ]

    # gpg-agent.conf should be symlinked
    [ -L "$TARGET_DIR/.gnupg/gpg-agent.conf" ]

    # Secrets should be untouched
    [ -f "$TARGET_DIR/.gnupg/trustdb.gpg" ]
    [ "$(cat "$TARGET_DIR/.gnupg/trustdb.gpg")" = "secret" ]
    [ -f "$TARGET_DIR/.gnupg/private-keys-v1.d/mykey.key" ]
}

# ============================================================
# .stowignore support
# ============================================================

@test "integration: .stowignore excludes matching files from stow" {
    local pkg="$SOURCE_DIR/pkg"
    mkdir -p "$pkg"
    echo "content" > "$pkg/.bashrc"
    echo "secret" > "$pkg/.secrets.baseline"
    echo "hooks" > "$pkg/.pre-commit-config.yaml"
    cat > "$pkg/.stowignore" <<'EOF'
*.baseline
.pre-commit-config.yaml
EOF

    run "$STOW_SH" -G --no-xdg -d "$SOURCE_DIR" -t "$TARGET_DIR" -S pkg
    [ "$status" -eq 0 ]
    [ -L "$TARGET_DIR/.bashrc" ]
    [ ! -e "$TARGET_DIR/.secrets.baseline" ]
    [ ! -e "$TARGET_DIR/.pre-commit-config.yaml" ]
    [ ! -e "$TARGET_DIR/.stowignore" ]
}

@test "integration: .stowignore file itself is never stowed" {
    local pkg="$SOURCE_DIR/pkg"
    mkdir -p "$pkg"
    echo "content" > "$pkg/.bashrc"
    echo "" > "$pkg/.stowignore"

    run "$STOW_SH" -G --no-xdg -d "$SOURCE_DIR" -t "$TARGET_DIR" -S pkg
    [ "$status" -eq 0 ]
    [ -L "$TARGET_DIR/.bashrc" ]
    [ ! -e "$TARGET_DIR/.stowignore" ]
}

@test "integration: .stowignore works with directory folding" {
    local pkg="$SOURCE_DIR/pkg"
    mkdir -p "$pkg/.config/nvim"
    echo "init" > "$pkg/.config/nvim/init.lua"
    echo "readme" > "$pkg/README.md"
    cat > "$pkg/.stowignore" <<'EOF'
README.md
EOF

    run "$STOW_SH" -G --no-xdg -d "$SOURCE_DIR" -t "$TARGET_DIR" -S pkg
    [ "$status" -eq 0 ]
    [ ! -e "$TARGET_DIR/README.md" ]
    # nvim should still be stowed (potentially folded)
    [ -e "$TARGET_DIR/.config/nvim/init.lua" ]
}

@test "integration: unstow with .stowignore only removes non-ignored files" {
    local pkg="$SOURCE_DIR/pkg"
    mkdir -p "$pkg"
    echo "content" > "$pkg/.bashrc"
    echo "secret" > "$pkg/.secrets.baseline"
    cat > "$pkg/.stowignore" <<'EOF'
*.baseline
EOF

    # Stow (only .bashrc should be symlinked)
    "$STOW_SH" -G --no-xdg -d "$SOURCE_DIR" -t "$TARGET_DIR" -S pkg
    [ -L "$TARGET_DIR/.bashrc" ]
    [ ! -e "$TARGET_DIR/.secrets.baseline" ]

    # Unstow
    run "$STOW_SH" -G --no-xdg -d "$SOURCE_DIR" -t "$TARGET_DIR" -D pkg
    [ "$status" -eq 0 ]
    [ ! -L "$TARGET_DIR/.bashrc" ]
}

# ============================================================
# User-facing report output
# ============================================================

@test "integration: stow produces visible report output on stdout" {
    local pkg="$SOURCE_DIR/pkg"
    mkdir -p "$pkg"
    echo "content" > "$pkg/.bashrc"

    run "$STOW_SH" -G --no-xdg -d "$SOURCE_DIR" -t "$TARGET_DIR" -S pkg
    [ "$status" -eq 0 ]
    [[ "$output" == *"stow pkg"* ]]
    [[ "$output" == *"+"* ]]
    [[ "$output" == *".bashrc"* ]]
}

@test "integration: unstow produces visible report output on stdout" {
    local pkg="$SOURCE_DIR/pkg"
    mkdir -p "$pkg"
    echo "content" > "$pkg/.bashrc"

    "$STOW_SH" -G --no-xdg -d "$SOURCE_DIR" -t "$TARGET_DIR" -S pkg

    run "$STOW_SH" -G --no-xdg -d "$SOURCE_DIR" -t "$TARGET_DIR" -D pkg
    [ "$status" -eq 0 ]
    [[ "$output" == *"unstow pkg"* ]]
    [[ "$output" == *"-"* ]]
    [[ "$output" == *".bashrc"* ]]
}

@test "integration: unstow of already-unstowed package succeeds silently" {
    local pkg="$SOURCE_DIR/pkg"
    mkdir -p "$pkg"
    echo "content" > "$pkg/.bashrc"

    # Never stowed, so unstow should succeed without per-file output
    run "$STOW_SH" -G --no-xdg -d "$SOURCE_DIR" -t "$TARGET_DIR" -D pkg
    [ "$status" -eq 0 ]
    # Should not contain link/unlink actions (only the package header)
    [[ "$output" != *".bashrc ->"* ]]
}

@test "integration: dry-run shows WOULD messages on stdout" {
    local pkg="$SOURCE_DIR/pkg"
    mkdir -p "$pkg"
    echo "content" > "$pkg/.bashrc"

    run "$STOW_SH" -G --no-xdg -n -d "$SOURCE_DIR" -t "$TARGET_DIR" -S pkg
    [ "$status" -eq 0 ]
    [[ "$output" == *"WOULD"* ]]
    [ ! -L "$TARGET_DIR/.bashrc" ]
}

# ============================================================
# -S/-D without packages defaults to self-stow
# ============================================================

@test "integration: -S without packages defaults to self-stow" {
    # Source dir has files directly (no subdirectories = self-stow)
    echo "content" > "$SOURCE_DIR/.bashrc"

    run "$STOW_SH" -G --no-xdg -d "$SOURCE_DIR" -t "$TARGET_DIR" -S
    [ "$status" -eq 0 ]
    [ -L "$TARGET_DIR/.bashrc" ]
    [ "$(readlink -f "$TARGET_DIR/.bashrc")" = "$(readlink -f "$SOURCE_DIR/.bashrc")" ]
}

@test "integration: -D without packages defaults to self-unstow" {
    echo "content" > "$SOURCE_DIR/.bashrc"

    # Stow first
    "$STOW_SH" -G --no-xdg -d "$SOURCE_DIR" -t "$TARGET_DIR" -S
    [ -L "$TARGET_DIR/.bashrc" ]

    # Unstow with bare -D
    run "$STOW_SH" -G --no-xdg -d "$SOURCE_DIR" -t "$TARGET_DIR" -D
    [ "$status" -eq 0 ]
    [ ! -e "$TARGET_DIR/.bashrc" ]
}

@test "integration: -R without packages defaults to self-restow" {
    echo "content" > "$SOURCE_DIR/.bashrc"

    # Stow first
    "$STOW_SH" -G --no-xdg -d "$SOURCE_DIR" -t "$TARGET_DIR" -S
    [ -L "$TARGET_DIR/.bashrc" ]

    # Restow with bare -R
    run "$STOW_SH" -G --no-xdg -d "$SOURCE_DIR" -t "$TARGET_DIR" -R
    [ "$status" -eq 0 ]
    [ -L "$TARGET_DIR/.bashrc" ]
    [ "$(readlink -f "$TARGET_DIR/.bashrc")" = "$(readlink -f "$SOURCE_DIR/.bashrc")" ]
}

# ============================================================
# Ancestor fold point detection during unstow
# ============================================================

@test "integration: unstow detects ancestor fold point with nested structure" {
    # Stow creates a fold point at .config (directory symlink),
    # then unstow with --no-fold resolves individual files and must
    # detect the ancestor fold point and remove it
    local pkg="$SOURCE_DIR/pkg"
    mkdir -p "$pkg/.config/nvim/lua"
    echo "init" > "$pkg/.config/nvim/init.lua"
    echo "plugins" > "$pkg/.config/nvim/lua/plugins.lua"

    # Stow with folding — creates .config -> pkg/.config
    "$STOW_SH" -G --no-xdg -d "$SOURCE_DIR" -t "$TARGET_DIR" -S pkg
    [ -L "$TARGET_DIR/.config" ]

    # Unstow — should detect the ancestor symlink and remove it
    run "$STOW_SH" -G --no-xdg -d "$SOURCE_DIR" -t "$TARGET_DIR" -D pkg
    [ "$status" -eq 0 ]
    [ ! -e "$TARGET_DIR/.config" ]
}

# ============================================================
# -D/-R without packages auto-discovers subdirs (regression)
# ============================================================

@test "integration: -D without packages auto-discovers and unstows all subdirs" {
    # Stow two packages via auto-discovery
    mkdir -p "$SOURCE_DIR/vim" "$SOURCE_DIR/bash"
    echo "vimrc" > "$SOURCE_DIR/vim/.vimrc"
    echo "bashrc" > "$SOURCE_DIR/bash/.bashrc"

    "$STOW_SH" -G -d "$SOURCE_DIR" -t "$TARGET_DIR"
    [ -L "$TARGET_DIR/.vimrc" ]
    [ -L "$TARGET_DIR/.bashrc" ]

    # Unstow with bare -D (no packages) — should auto-discover and remove all
    "$STOW_SH" -G -d "$SOURCE_DIR" -t "$TARGET_DIR" -D
    [ ! -e "$TARGET_DIR/.vimrc" ]
    [ ! -e "$TARGET_DIR/.bashrc" ]
}

@test "integration: -Dv without packages auto-discovers and unstows all subdirs" {
    # Same as above but with combined -Dv flag (the original bug report)
    mkdir -p "$SOURCE_DIR/vim" "$SOURCE_DIR/bash"
    echo "vimrc" > "$SOURCE_DIR/vim/.vimrc"
    echo "bashrc" > "$SOURCE_DIR/bash/.bashrc"

    "$STOW_SH" -G -d "$SOURCE_DIR" -t "$TARGET_DIR"
    [ -L "$TARGET_DIR/.vimrc" ]
    [ -L "$TARGET_DIR/.bashrc" ]

    # Unstow with -Dv — used to default to self-unstow (.) and miss everything
    "$STOW_SH" -G -d "$SOURCE_DIR" -t "$TARGET_DIR" -Dv
    [ ! -e "$TARGET_DIR/.vimrc" ]
    [ ! -e "$TARGET_DIR/.bashrc" ]
}

@test "integration: -R without packages auto-discovers and restows all subdirs" {
    mkdir -p "$SOURCE_DIR/vim"
    echo "vimrc" > "$SOURCE_DIR/vim/.vimrc"

    "$STOW_SH" -G -d "$SOURCE_DIR" -t "$TARGET_DIR"
    [ -L "$TARGET_DIR/.vimrc" ]

    # Add a new file and restow with bare -R
    echo "gvimrc" > "$SOURCE_DIR/vim/.gvimrc"
    "$STOW_SH" -G -d "$SOURCE_DIR" -t "$TARGET_DIR" -R
    [ -L "$TARGET_DIR/.vimrc" ]
    [ -L "$TARGET_DIR/.gvimrc" ]
}

# ============================================================
# Mutually exclusive flags
# ============================================================

@test "integration: --force and --adopt rejects with error" {
    local pkg="$SOURCE_DIR/pkg"
    mkdir -p "$pkg"
    echo "x" > "$pkg/file"
    run "$STOW_SH" -G -d "$SOURCE_DIR" -t "$TARGET_DIR" --force --adopt -S pkg
    [ "$status" -eq 1 ]
    [[ "$output" == *"mutually exclusive"* ]]
}

@test "integration: -g and -G rejects with error" {
    local pkg="$SOURCE_DIR/pkg"
    mkdir -p "$pkg"
    echo "x" > "$pkg/file"
    run "$STOW_SH" -g -G -d "$SOURCE_DIR" -t "$TARGET_DIR" -S pkg
    [ "$status" -eq 1 ]
    [[ "$output" == *"mutually exclusive"* ]]
}

# ============================================================
# Dotfiles mode (--dotfiles)
# ============================================================

@test "integration: --dotfiles links dot-bashrc as .bashrc" {
    local pkg="$SOURCE_DIR/pkg"
    mkdir -p "$pkg"
    echo "rc" > "$pkg/dot-bashrc"

    run "$STOW_SH" --dotfiles -G --no-xdg -d "$SOURCE_DIR" -t "$TARGET_DIR" -S pkg
    [ "$status" -eq 0 ]
    [ -L "$TARGET_DIR/.bashrc" ]
    [ "$(readlink -f "$TARGET_DIR/.bashrc")" = "$(readlink -f "$pkg/dot-bashrc")" ]
    # The un-translated name must NOT exist at the target.
    [ ! -e "$TARGET_DIR/dot-bashrc" ]
}

@test "integration: without --dotfiles, dot- names are left literal" {
    local pkg="$SOURCE_DIR/pkg"
    mkdir -p "$pkg"
    echo "rc" > "$pkg/dot-bashrc"

    run "$STOW_SH" -G --no-xdg -d "$SOURCE_DIR" -t "$TARGET_DIR" -S pkg
    [ "$status" -eq 0 ]
    [ -L "$TARGET_DIR/dot-bashrc" ]
    [ ! -e "$TARGET_DIR/.bashrc" ]
}

@test "integration: --dotfiles folds a whole dot- directory" {
    local pkg="$SOURCE_DIR/pkg"
    mkdir -p "$pkg/dot-vim/colors"
    echo "v" > "$pkg/dot-vim/vimrc"
    echo "c" > "$pkg/dot-vim/colors/theme.vim"

    run "$STOW_SH" --dotfiles -G --no-xdg -d "$SOURCE_DIR" -t "$TARGET_DIR" -S pkg
    [ "$status" -eq 0 ]
    # Whole directory folds to a single symlink named .vim
    [ -L "$TARGET_DIR/.vim" ]
    [ "$(readlink -f "$TARGET_DIR/.vim")" = "$(readlink -f "$pkg/dot-vim")" ]
}

@test "integration: --dotfiles respects XDG barriers (dot-config → real .config)" {
    local pkg="$SOURCE_DIR/pkg"
    mkdir -p "$pkg/dot-config/nvim/lua"
    echo "init" > "$pkg/dot-config/nvim/init.lua"
    echo "p" > "$pkg/dot-config/nvim/lua/plugins.lua"

    XDG_CONFIG_HOME="$TARGET_DIR/.config" \
        run "$STOW_SH" --dotfiles -G -d "$SOURCE_DIR" -t "$TARGET_DIR" -S pkg
    [ "$status" -eq 0 ]
    # .config stays a real directory (barrier), nvim folds beneath it.
    [ -d "$TARGET_DIR/.config" ] && [ ! -L "$TARGET_DIR/.config" ]
    [ -L "$TARGET_DIR/.config/nvim" ]
    [ "$(readlink -f "$TARGET_DIR/.config/nvim")" = "$(readlink -f "$pkg/dot-config/nvim")" ]
}

@test "integration: --dotfiles unstow removes translated links" {
    local pkg="$SOURCE_DIR/pkg"
    mkdir -p "$pkg/dot-vim"
    echo "rc" > "$pkg/dot-bashrc"
    echo "v" > "$pkg/dot-vim/vimrc"

    "$STOW_SH" --dotfiles -G --no-xdg -d "$SOURCE_DIR" -t "$TARGET_DIR" -S pkg
    [ -L "$TARGET_DIR/.bashrc" ]

    run "$STOW_SH" --dotfiles -G --no-xdg -d "$SOURCE_DIR" -t "$TARGET_DIR" -D pkg
    [ "$status" -eq 0 ]
    [ ! -e "$TARGET_DIR/.bashrc" ]
    [ ! -e "$TARGET_DIR/.vim" ]
}

@test "integration: --dotfiles restow refreshes translated links" {
    local pkg="$SOURCE_DIR/pkg"
    mkdir -p "$pkg"
    echo "rc" > "$pkg/dot-bashrc"

    "$STOW_SH" --dotfiles -G --no-xdg -d "$SOURCE_DIR" -t "$TARGET_DIR" -S pkg
    run "$STOW_SH" --dotfiles -G --no-xdg -d "$SOURCE_DIR" -t "$TARGET_DIR" -R pkg
    [ "$status" -eq 0 ]
    [ -L "$TARGET_DIR/.bashrc" ]
    [ "$(readlink -f "$TARGET_DIR/.bashrc")" = "$(readlink -f "$pkg/dot-bashrc")" ]
}

@test "integration: --dotfiles with ## annotation strips and translates" {
    local pkg="$SOURCE_DIR/pkg"
    mkdir -p "$pkg"
    # exe.bash is true (bash is on PATH), so this should deploy.
    echo "x" > "$pkg/dot-foo##exe.bash"

    run "$STOW_SH" --dotfiles -G --no-xdg -d "$SOURCE_DIR" -t "$TARGET_DIR" -S pkg
    [ "$status" -eq 0 ]
    [ -L "$TARGET_DIR/.foo" ]
    [ "$(readlink -f "$TARGET_DIR/.foo")" = "$(readlink -f "$pkg/dot-foo##exe.bash")" ]
}

@test "integration: --dotfiles auto-unfold into an existing real .config" {
    local pkg="$SOURCE_DIR/pkg"
    mkdir -p "$pkg/dot-config"
    echo "a" > "$pkg/dot-config/aaa"
    echo "b" > "$pkg/dot-config/bbb"
    # Pre-existing real .config dir at the target forces auto-unfold.
    mkdir -p "$TARGET_DIR/.config"
    echo "keep" > "$TARGET_DIR/.config/existing"

    run "$STOW_SH" --dotfiles -G --no-xdg -d "$SOURCE_DIR" -t "$TARGET_DIR" -S pkg
    [ "$status" -eq 0 ]
    # .config stays real; children are individually linked with translated names.
    [ -d "$TARGET_DIR/.config" ] && [ ! -L "$TARGET_DIR/.config" ]
    [ -L "$TARGET_DIR/.config/aaa" ]
    [ -L "$TARGET_DIR/.config/bbb" ]
    [ -f "$TARGET_DIR/.config/existing" ] && [ ! -L "$TARGET_DIR/.config/existing" ]
}
