#!/usr/bin/env bats
# SPDX-License-Identifier: MIT
# Copyright (c) 2025 David Kristiansen

setup() {
    source "$BATS_TEST_DIRNAME/../src/log.sh"
    source "$BATS_TEST_DIRNAME/../src/scan.sh"

    # Create a temporary package directory for testing
    TEST_PKG="$(mktemp -d)"
    mkdir -p "$TEST_PKG/sub/deep"
    touch "$TEST_PKG/file1.txt"
    touch "$TEST_PKG/file2.txt"
    touch "$TEST_PKG/sub/file3.txt"
    touch "$TEST_PKG/sub/deep/file4.txt"
}

teardown() {
    rm -rf "$TEST_PKG"
}

@test "scan_package returns all files recursively" {
    run stow_sh::scan_package "$TEST_PKG"
    [ "$status" -eq 0 ]
    # Should find: file1.txt, file2.txt, sub/file3.txt, sub/deep/file4.txt
    [[ "$output" == *"file1.txt"* ]]
    [[ "$output" == *"file2.txt"* ]]
    [[ "$output" == *"sub/file3.txt"* ]]
    [[ "$output" == *"sub/deep/file4.txt"* ]]
}

@test "scan_package returns only files, not directories" {
    run stow_sh::scan_package "$TEST_PKG"
    [ "$status" -eq 0 ]
    # Directories themselves should NOT appear in output
    while IFS= read -r line; do
        [[ -f "$line" ]]
    done <<< "$output"
}

@test "scan_package returns full paths" {
    run stow_sh::scan_package "$TEST_PKG"
    [ "$status" -eq 0 ]
    # Every line should start with the package dir path
    while IFS= read -r line; do
        [[ "$line" == "$TEST_PKG/"* ]]
    done <<< "$output"
}

@test "scan_package fails on non-existent directory" {
    run stow_sh::scan_package "/nonexistent/path"
    [ "$status" -eq 1 ]
}

@test "scan_package handles empty directory" {
    local empty_dir="$(mktemp -d)"
    run stow_sh::scan_package "$empty_dir"
    [ "$status" -eq 0 ]
    [ "$output" = "" ]
    rm -rf "$empty_dir"
}

@test "scan_package handles dotfiles" {
    touch "$TEST_PKG/.hidden"
    mkdir -p "$TEST_PKG/.config/app"
    touch "$TEST_PKG/.config/app/config.toml"

    run stow_sh::scan_package "$TEST_PKG"
    [ "$status" -eq 0 ]
    [[ "$output" == *".hidden"* ]]
    [[ "$output" == *".config/app/config.toml"* ]]
}

@test "scan_package handles annotated filenames" {
    touch "$TEST_PKG/file##os.linux"
    mkdir -p "$TEST_PKG/dir##shell.bash"
    touch "$TEST_PKG/dir##shell.bash/inner"

    run stow_sh::scan_package "$TEST_PKG"
    [ "$status" -eq 0 ]
    [[ "$output" == *"file##os.linux"* ]]
    [[ "$output" == *"dir##shell.bash"* ]]
    [[ "$output" == *"dir##shell.bash/inner"* ]]
}

@test "scan_package handles spaces in filenames" {
    touch "$TEST_PKG/file with spaces.txt"
    mkdir -p "$TEST_PKG/dir with spaces"
    touch "$TEST_PKG/dir with spaces/inner file.txt"

    run stow_sh::scan_package "$TEST_PKG"
    [ "$status" -eq 0 ]
    [[ "$output" == *"file with spaces.txt"* ]]
    [[ "$output" == *"dir with spaces/inner file.txt"* ]]
}
