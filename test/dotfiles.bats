#!/usr/bin/env bats
# SPDX-License-Identifier: MIT
# Copyright (c) 2025 David Kristiansen

setup() {
    source "$BATS_TEST_DIRNAME/../src/log.sh"
    source "$BATS_TEST_DIRNAME/../src/args.sh"
    source "$BATS_TEST_DIRNAME/../src/dotfiles.sh"
    _stow_sh_dotfiles=true
}

# --- translate: package name → link name (dot- → .) ---

@test "translate: leading dot- becomes ." {
    run stow_sh::dotfiles_translate "dot-bashrc"
    [ "$output" = ".bashrc" ]
}

@test "translate: per-component translation" {
    run stow_sh::dotfiles_translate "dot-config/nvim/dot-theme"
    [ "$output" = ".config/nvim/.theme" ]
}

@test "translate: only leading dot- of each component is translated" {
    run stow_sh::dotfiles_translate "dot-config/app-dot-name"
    [ "$output" = ".config/app-dot-name" ]
}

@test "translate: non-dot components are untouched" {
    run stow_sh::dotfiles_translate "vim/colors/theme.vim"
    [ "$output" = "vim/colors/theme.vim" ]
}

@test "translate: an already-dotted component is left as-is" {
    run stow_sh::dotfiles_translate "dot-config/.hidden"
    [ "$output" = ".config/.hidden" ]
}

@test "translate: no-op when --dotfiles is off" {
    _stow_sh_dotfiles=false
    run stow_sh::dotfiles_translate "dot-bashrc"
    [ "$output" = "dot-bashrc" ]
}

# --- untranslate: link name → package name (. → dot-) ---

@test "untranslate: leading . becomes dot-" {
    run stow_sh::dotfiles_untranslate ".config"
    [ "$output" = "dot-config" ]
}

@test "untranslate: per-component, only hidden components change" {
    run stow_sh::dotfiles_untranslate ".local/share"
    [ "$output" = "dot-local/share" ]
}

@test "untranslate: nested hidden component" {
    run stow_sh::dotfiles_untranslate ".config/.foo"
    [ "$output" = "dot-config/dot-foo" ]
}

@test "untranslate: leaves . and .. alone" {
    run stow_sh::dotfiles_untranslate "./.."
    [ "$output" = "./.." ]
}

@test "untranslate: no-op when --dotfiles is off" {
    _stow_sh_dotfiles=false
    run stow_sh::dotfiles_untranslate ".config"
    [ "$output" = ".config" ]
}

# --- round trip ---

@test "translate then untranslate is identity for dot- paths" {
    local link pkg
    link="$(stow_sh::dotfiles_translate "dot-config/nvim/dot-init")"
    pkg="$(stow_sh::dotfiles_untranslate "$link")"
    [ "$pkg" = "dot-config/nvim/dot-init" ]
}
