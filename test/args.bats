#!/usr/bin/env bats
# SPDX-License-Identifier: MIT
# Copyright (c) 2025 David Kristiansen

# Helper: reset all args.sh state between tests.
# args.sh uses global variables, so we must re-source to get clean defaults.
setup() {
    # Source fresh copies — order matters: log first, then args
    source "$BATS_TEST_DIRNAME/../src/log.sh"
    source "$BATS_TEST_DIRNAME/../src/args.sh"

    # Disable git auto-detection by forcing --no-git in most tests
    # (we're inside a git repo, so auto-detect would trigger git validation)
}

# Helper to parse with git disabled (avoids git auto-detect side effects)
parse_no_git() {
    stow_sh::parse_args -G "$@"
}

# --- Simple flag tests ---

@test "parse_args: -f sets force mode" {
    parse_no_git -f -S pkg
    [[ "$(stow_sh::get_force)" == "true" ]]
}

@test "parse_args: --force sets force mode" {
    parse_no_git --force -S pkg
    [[ "$(stow_sh::get_force)" == "true" ]]
}

@test "parse_args: -n sets dry-run mode" {
    parse_no_git -n -S pkg
    [[ "$(stow_sh::get_dry_run)" == "true" ]]
}

@test "parse_args: --no sets dry-run mode" {
    parse_no_git --no -S pkg
    [[ "$(stow_sh::get_dry_run)" == "true" ]]
}

@test "parse_args: --adopt sets adopt mode" {
    parse_no_git --adopt -S pkg
    [[ "$_stow_sh_adopt" == "true" ]]
}

@test "parse_args: --no-folding disables folding" {
    parse_no_git --no-folding -S pkg
    stow_sh::is_folding_disabled
}

@test "parse_args: --no-xdg disables XDG mode" {
    parse_no_git --no-xdg -S pkg
    ! stow_sh::is_xdg_mode
}

@test "parse_args: XDG mode is on by default" {
    parse_no_git -S pkg
    stow_sh::is_xdg_mode
}

# --- Verbosity ---

@test "parse_args: -v increments debug level" {
    parse_no_git -v -S pkg
    [[ "$(stow_sh::get_debug)" == "1" ]]
}

@test "parse_args: -v -v increments debug level twice" {
    parse_no_git -v -v -S pkg
    [[ "$(stow_sh::get_debug)" == "2" ]]
}

@test "parse_args: --verbose=3 sets debug level directly" {
    parse_no_git --verbose=3 -S pkg
    [[ "$(stow_sh::get_debug)" == "3" ]]
}

@test "parse_args: --color=never sets color mode" {
    parse_no_git --color=never -S pkg
    [[ "$(stow_sh::get_color_mode)" == "never" ]]
}

# --- Stow targets ---

@test "parse_args: -S adds stow packages" {
    parse_no_git -S vim bash
    local -a pkgs
    mapfile -t pkgs < <(stow_sh::get_stow_packages)
    [[ ${#pkgs[@]} -eq 2 ]]
    [[ "${pkgs[0]}" == "vim" ]]
    [[ "${pkgs[1]}" == "bash" ]]
}

@test "parse_args: --stow adds stow packages" {
    parse_no_git --stow vim bash
    local -a pkgs
    mapfile -t pkgs < <(stow_sh::get_stow_packages)
    [[ ${#pkgs[@]} -eq 2 ]]
}

@test "parse_args: positional arg becomes stow package" {
    parse_no_git vim
    local -a pkgs
    mapfile -t pkgs < <(stow_sh::get_stow_packages)
    [[ "${pkgs[*]}" == *"vim"* ]]
}

# --- Unstow / Restow ---

@test "parse_args: -D adds unstow targets" {
    parse_no_git -D vim bash
    [[ "${_stow_sh_unstow_targets[0]}" == "vim" ]]
    [[ "${_stow_sh_unstow_targets[1]}" == "bash" ]]
}

@test "parse_args: -R adds restow targets" {
    parse_no_git -R vim
    [[ "${_stow_sh_restow_targets[0]}" == "vim" ]]
}

# --- Dir and target ---

@test "parse_args: -d sets source dir" {
    parse_no_git -d /tmp/dotfiles -S pkg
    [[ "$(stow_sh::get_dir)" == "/tmp/dotfiles" ]]
}

@test "parse_args: -t sets target dir" {
    parse_no_git -t /home/user -S pkg
    [[ "$(stow_sh::get_target)" == "/home/user" ]]
}

# --- Ignore patterns ---

@test "parse_args: -i adds regex ignore patterns" {
    parse_no_git -i 'README.*' 'LICENSE' -S pkg
    local -a pats
    mapfile -t pats < <(stow_sh::get_ignore)
    [[ ${#pats[@]} -eq 2 ]]
    [[ "${pats[0]}" == "README.*" ]]
    [[ "${pats[1]}" == "LICENSE" ]]
}

@test "parse_args: --ignore= adds regex ignore pattern" {
    parse_no_git --ignore='README.*' -S pkg
    local -a pats
    mapfile -t pats < <(stow_sh::get_ignore)
    [[ "${pats[0]}" == "README.*" ]]
}

@test "parse_args: -I adds glob ignore patterns" {
    parse_no_git -I '*.md' '*.txt' -S pkg
    local -a pats
    mapfile -t pats < <(stow_sh::get_ignore_glob)
    [[ ${#pats[@]} -eq 2 ]]
    [[ "${pats[0]}" == "*.md" ]]
}

@test "parse_args: --ignore-glob= adds glob ignore pattern" {
    parse_no_git --ignore-glob='*.bak' -S pkg
    local -a pats
    mapfile -t pats < <(stow_sh::get_ignore_glob)
    [[ "${pats[0]}" == "*.bak" ]]
}

# --- Defer / Override ---

@test "parse_args: --defer= adds defer pattern" {
    parse_no_git --defer=info -S pkg
    [[ "${_stow_sh_defer[0]}" == "info" ]]
}

@test "parse_args: --override= adds override pattern" {
    parse_no_git --override=info -S pkg
    [[ "${_stow_sh_override[0]}" == "info" ]]
}

# --- Short-flag expansion ---

@test "parse_args: combined short flags -fn expands to -f -n" {
    parse_no_git -fn -S pkg
    [[ "$(stow_sh::get_force)" == "true" ]]
    [[ "$(stow_sh::get_dry_run)" == "true" ]]
}

@test "parse_args: combined short flags -vvv gives debug level 3" {
    parse_no_git -vvv -S pkg
    [[ "$(stow_sh::get_debug)" == "3" ]]
}

# --- Git mode ---

@test "parse_args: -g enables git mode" {
    stow_sh::parse_args -g -S pkg
    [[ "$(stow_sh::get_git_mode)" == "true" ]]
}

@test "parse_args: -G disables git mode" {
    stow_sh::parse_args -G -S pkg
    [[ "$(stow_sh::get_git_mode)" == "false" ]]
}

# --- setup_paths ---

@test "setup_paths: defaults source to pwd" {
    parse_no_git -S pkg
    stow_sh::setup_paths
    [[ "$(stow_sh::get_source)" == "$(pwd)" ]]
}

@test "setup_paths: defaults target to parent of source" {
    parse_no_git -S pkg
    stow_sh::setup_paths
    [[ "$(stow_sh::get_target)" == "$(dirname "$(pwd)")" ]]
}

@test "setup_paths: uses -d for source" {
    parse_no_git -d /tmp -S pkg
    stow_sh::setup_paths
    [[ "$(stow_sh::get_source)" == "/tmp" ]]
}

@test "setup_paths: uses -t for target" {
    parse_no_git -t /tmp -S pkg
    stow_sh::setup_paths
    [[ "$(stow_sh::get_target)" == "/tmp" ]]
}
