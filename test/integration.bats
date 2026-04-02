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
