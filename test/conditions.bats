#!/usr/bin/env bats
# SPDX-License-Identifier: MIT
# Copyright (c) 2025 David Kristiansen

setup() {
    export STOW_ROOT="$BATS_TEST_DIRNAME/.."
    source "$BATS_TEST_DIRNAME/../src/log.sh"
    source "$BATS_TEST_DIRNAME/../src/conditions.sh"
    stow_sh::load_condition_plugins
}

# --- stow_sh::has_annotation ---

@test "has_annotation returns 0 for annotated filename" {
    run stow_sh::has_annotation "file##os.linux"
    [ "$status" -eq 0 ]
}

@test "has_annotation returns 1 for plain filename" {
    run stow_sh::has_annotation "file.txt"
    [ "$status" -eq 1 ]
}

@test "has_annotation returns 0 for annotated path segment" {
    run stow_sh::has_annotation "dir##docker/file.txt"
    [ "$status" -eq 0 ]
}

# --- stow_sh::any_has_annotation ---

@test "any_has_annotation returns 0 when one path has ##" {
    run stow_sh::any_has_annotation "foo.txt" "bar##os.linux" "baz.sh"
    [ "$status" -eq 0 ]
}

@test "any_has_annotation returns 1 when no paths have ##" {
    run stow_sh::any_has_annotation "foo.txt" "bar.sh" "baz/qux.conf"
    [ "$status" -eq 1 ]
}

# --- stow_sh::extract_conditions ---

@test "extract_conditions returns condition string" {
    run stow_sh::extract_conditions "file##os.linux,shell.bash"
    [ "$status" -eq 0 ]
    [ "$output" = "os.linux,shell.bash" ]
}

@test "extract_conditions handles negated conditions" {
    run stow_sh::extract_conditions "file##!docker"
    [ "$status" -eq 0 ]
    [ "$output" = "!docker" ]
}

@test "extract_conditions returns empty for plain path" {
    run stow_sh::extract_conditions "file.txt"
    [ "$status" -eq 0 ]
    [ "$output" = "" ]
}

@test "extract_conditions uses basename only" {
    run stow_sh::extract_conditions "dir##os.linux/file##shell.bash"
    [ "$status" -eq 0 ]
    [ "$output" = "shell.bash" ]
}

# --- stow_sh::sanitize_path ---

@test "sanitize_path strips single annotation" {
    run stow_sh::sanitize_path "file##os.linux"
    [ "$status" -eq 0 ]
    [ "$output" = "file" ]
}

@test "sanitize_path strips multiple annotations in path" {
    run stow_sh::sanitize_path "foo##os.linux/bar##wm.sway"
    [ "$status" -eq 0 ]
    [ "$output" = "foo/bar" ]
}

@test "sanitize_path passes through plain paths unchanged" {
    run stow_sh::sanitize_path "foo/bar/baz.txt"
    [ "$status" -eq 0 ]
    [ "$output" = "foo/bar/baz.txt" ]
}

@test "sanitize_path handles mixed annotated and plain segments" {
    run stow_sh::sanitize_path ".config/mise/conf.d/20-desktop.toml##!docker"
    [ "$status" -eq 0 ]
    [ "$output" = ".config/mise/conf.d/20-desktop.toml" ]
}

# --- stow_sh::check_conditions ---

@test "check_conditions returns 0 for plain path (no conditions)" {
    run stow_sh::check_conditions "file.txt"
    [ "$status" -eq 0 ]
}

@test "check_conditions returns 0 for exe condition when command exists" {
    run stow_sh::check_conditions "file##exe.bash"
    [ "$status" -eq 0 ]
}

@test "check_conditions returns 1 for exe condition when command missing" {
    run stow_sh::check_conditions "file##exe.nonexistent_binary_xyz_999"
    [ "$status" -eq 1 ]
}

@test "check_conditions returns 0 for negated condition that fails" {
    # !exe.nonexistent → condition fails → negation makes it pass
    run stow_sh::check_conditions "file##!exe.nonexistent_binary_xyz_999"
    [ "$status" -eq 0 ]
}

@test "check_conditions returns 1 for negated condition that passes" {
    # !exe.bash → condition passes → negation makes it fail
    run stow_sh::check_conditions "file##!exe.bash"
    [ "$status" -eq 1 ]
}

@test "check_conditions returns 1 for unknown condition type" {
    run stow_sh::check_conditions "file##unknown.value"
    [ "$status" -eq 1 ]
}

@test "check_conditions handles comma-separated conditions (all pass)" {
    run stow_sh::check_conditions "file##exe.bash,extension.sh"
    [ "$status" -eq 0 ]
}

@test "check_conditions fails if any condition in comma list fails" {
    run stow_sh::check_conditions "file##exe.bash,exe.nonexistent_binary_xyz_999"
    [ "$status" -eq 1 ]
}

@test "check_conditions returns 0 for docker negation outside docker" {
    # We're not inside docker (no /.dockerenv), so !docker should pass
    if [[ -f /.dockerenv ]]; then
        skip "Running inside Docker — cannot test !docker"
    fi
    run stow_sh::check_conditions "20-desktop.toml##!docker"
    [ "$status" -eq 0 ]
}

# --- stow_sh::condition::extension ---

@test "condition::extension always returns 0" {
    run stow_sh::condition::extension
    [ "$status" -eq 0 ]
}

# --- stow_sh::condition::no ---

@test "condition::no always returns 1" {
    run stow_sh::condition::no
    [ "$status" -eq 1 ]
}

@test "check_conditions skips file annotated with ##no" {
    run stow_sh::check_conditions "lazy-lock.json##no"
    [ "$status" -eq 1 ]
}

@test "check_conditions deploys file annotated with ##!no (negated)" {
    run stow_sh::check_conditions "important.json##!no"
    [ "$status" -eq 0 ]
}

# --- stow_sh::condition::shell ---

@test "condition::shell matches current shell" {
    local expected
    expected="$(basename "$SHELL")"
    run stow_sh::condition::shell "$expected"
    [ "$status" -eq 0 ]
}

@test "condition::shell rejects non-matching shell" {
    run stow_sh::condition::shell "nonexistent_shell_xyz"
    [ "$status" -eq 1 ]
}

# --- stow_sh::condition::exe ---

@test "condition::exe returns 0 for existing command" {
    run stow_sh::condition::exe "bash"
    [ "$status" -eq 0 ]
}

@test "condition::exe returns 1 for missing command" {
    run stow_sh::condition::exe "nonexistent_binary_xyz_999"
    [ "$status" -eq 1 ]
}

# --- stow_sh::load_condition_plugins ---

@test "load_condition_plugins loads custom condition from XDG dir" {
    local tmpdir
    tmpdir="$(mktemp -d)"
    mkdir -p "$tmpdir/stow.sh/conditions"

    cat > "$tmpdir/stow.sh/conditions/greeting.sh" <<'PLUGIN'
stow_sh::condition::greeting() {
    [[ "$1" == "hello" ]]
}
PLUGIN

    XDG_CONFIG_HOME="$tmpdir" stow_sh::load_condition_plugins

    # The plugin should now be callable
    run stow_sh::condition::greeting "hello"
    [ "$status" -eq 0 ]

    run stow_sh::condition::greeting "goodbye"
    [ "$status" -eq 1 ]

    rm -rf "$tmpdir"
}

@test "load_condition_plugins makes custom condition usable via check_conditions" {
    local tmpdir
    tmpdir="$(mktemp -d)"
    mkdir -p "$tmpdir/stow.sh/conditions"

    cat > "$tmpdir/stow.sh/conditions/testcond.sh" <<'PLUGIN'
stow_sh::condition::testcond() {
    [[ "$1" == "yes" ]]
}
PLUGIN

    XDG_CONFIG_HOME="$tmpdir" stow_sh::load_condition_plugins

    # Use it through the full check_conditions pipeline
    run stow_sh::check_conditions "file##testcond.yes"
    [ "$status" -eq 0 ]

    run stow_sh::check_conditions "file##testcond.no"
    [ "$status" -eq 1 ]

    # Negation should work too
    run stow_sh::check_conditions "file##!testcond.no"
    [ "$status" -eq 0 ]

    rm -rf "$tmpdir"
}

@test "load_condition_plugins succeeds silently when dir does not exist" {
    local tmpdir
    tmpdir="$(mktemp -d)"
    # Don't create the conditions dir
    run bash -c "source '$BATS_TEST_DIRNAME/../src/log.sh'; source '$BATS_TEST_DIRNAME/../src/conditions.sh'; XDG_CONFIG_HOME='$tmpdir' stow_sh::load_condition_plugins"
    [ "$status" -eq 0 ]
    rm -rf "$tmpdir"
}

@test "load_condition_plugins ignores non-.sh files" {
    local tmpdir
    tmpdir="$(mktemp -d)"
    mkdir -p "$tmpdir/stow.sh/conditions"

    # .txt file should be ignored
    cat > "$tmpdir/stow.sh/conditions/notes.txt" <<'FILE'
stow_sh::condition::shouldnotload() { return 0; }
FILE

    XDG_CONFIG_HOME="$tmpdir" stow_sh::load_condition_plugins

    # The function should NOT have been loaded
    run stow_sh::check_conditions "file##shouldnotload"
    [ "$status" -eq 1 ]

    rm -rf "$tmpdir"
}
