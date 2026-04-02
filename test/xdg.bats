#!/usr/bin/env bats
# SPDX-License-Identifier: MIT
# Copyright (c) 2025 David Kristiansen

setup() {
    source "$BATS_TEST_DIRNAME/../src/log.sh"
    source "$BATS_TEST_DIRNAME/../src/xdg.sh"
}

# --- compute_xdg_barriers ---

@test "compute_xdg_barriers returns .config when XDG_CONFIG_HOME is under target" {
    XDG_CONFIG_HOME="/home/user/.config" \
        run stow_sh::compute_xdg_barriers "/home/user"
    [ "$status" -eq 0 ]
    [[ "$output" == *".config"* ]]
}

@test "compute_xdg_barriers returns .local/share for XDG_DATA_HOME" {
    XDG_DATA_HOME="/home/user/.local/share" \
        run stow_sh::compute_xdg_barriers "/home/user"
    [ "$status" -eq 0 ]
    [[ "$output" == *".local/share"* ]]
}

@test "compute_xdg_barriers returns multiple barriers for multiple XDG vars" {
    XDG_CONFIG_HOME="/home/user/.config" \
    XDG_DATA_HOME="/home/user/.local/share" \
    XDG_CACHE_HOME="/home/user/.cache" \
        run stow_sh::compute_xdg_barriers "/home/user"
    [ "$status" -eq 0 ]
    [[ "$output" == *".config"* ]]
    [[ "$output" == *".local/share"* ]]
    [[ "$output" == *".cache"* ]]
}

@test "compute_xdg_barriers skips unset variables" {
    unset XDG_CONFIG_HOME XDG_DATA_HOME XDG_STATE_HOME XDG_CACHE_HOME XDG_BIN_HOME XDG_RUNTIME_DIR
    run stow_sh::compute_xdg_barriers "/home/user"
    [ "$status" -eq 0 ]
    [ "$output" = "" ]
}

@test "compute_xdg_barriers skips XDG dirs not under target" {
    XDG_CONFIG_HOME="/other/path/.config" \
    XDG_RUNTIME_DIR="/run/user/1000" \
        run stow_sh::compute_xdg_barriers "/home/user"
    [ "$status" -eq 0 ]
    [ "$output" = "" ]
}

@test "compute_xdg_barriers handles XDG_BIN_HOME" {
    XDG_BIN_HOME="/home/user/.local/bin" \
        run stow_sh::compute_xdg_barriers "/home/user"
    [ "$status" -eq 0 ]
    [[ "$output" == *".local/bin"* ]]
}

@test "compute_xdg_barriers handles XDG_STATE_HOME" {
    XDG_STATE_HOME="/home/user/.local/state" \
        run stow_sh::compute_xdg_barriers "/home/user"
    [ "$status" -eq 0 ]
    [[ "$output" == *".local/state"* ]]
}

@test "compute_xdg_barriers handles non-standard XDG paths" {
    XDG_CONFIG_HOME="/home/user/myconfig" \
        run stow_sh::compute_xdg_barriers "/home/user"
    [ "$status" -eq 0 ]
    [[ "$output" == *"myconfig"* ]]
}

@test "compute_xdg_barriers handles target with trailing slash" {
    XDG_CONFIG_HOME="/home/user/.config" \
        run stow_sh::compute_xdg_barriers "/home/user/"
    [ "$status" -eq 0 ]
    [[ "$output" == *".config"* ]]
}

@test "compute_xdg_barriers: real-world scenario with all common XDG vars" {
    XDG_CONFIG_HOME="/home/user/.config" \
    XDG_DATA_HOME="/home/user/.local/share" \
    XDG_STATE_HOME="/home/user/.local/state" \
    XDG_CACHE_HOME="/home/user/.cache" \
    XDG_BIN_HOME="/home/user/.local/bin" \
    XDG_RUNTIME_DIR="/run/user/1000" \
        run stow_sh::compute_xdg_barriers "/home/user"
    [ "$status" -eq 0 ]
    [[ "$output" == *".config"* ]]
    [[ "$output" == *".local/share"* ]]
    [[ "$output" == *".local/state"* ]]
    [[ "$output" == *".cache"* ]]
    [[ "$output" == *".local/bin"* ]]
    # XDG_RUNTIME_DIR is /run/... — not under /home/user, should be absent
    [[ "$output" != *"/run/"* ]]
}
