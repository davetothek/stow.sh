# SPDX-License-Identifier: MIT
# Copyright (c) 2025 David Kristiansen

# shellcheck shell=bash

# dotfiles.sh — GNU Stow-style "dotfiles" name translation.
#
# With --dotfiles, a package entry whose basename begins with "dot-" is
# stowed as if it began with ".". The translation is applied per path
# component, so "dot-config/nvim/dot-theme" links as ".config/nvim/.theme".
# The package keeps the "dot-" names (so they aren't hidden in the repo);
# only the link name on the target side is translated.
#
# Two directions:
#   translate   — package name → link name   ("dot-foo" → ".foo")
#   untranslate — link name → package name    (".foo"   → "dot-foo")
#
# untranslate is used to map target-relative fold barriers (e.g. ".config")
# onto the package directory that actually holds them ("dot-config").
#
# Both are no-ops unless --dotfiles is active, so callers can apply them
# unconditionally.
#
# Depends on: args.sh (is_dotfiles)

# Var-returning core for dotfiles_translate: sets _stow_sh_dtrans.
#
# Avoids the subshell fork of $(dotfiles_translate ...) — critical in the
# per-target hot loops of stow/unstow.
#
# Usage: stow_sh::__dotfiles_translate_var "dot-config/nvim"
#        echo "$_stow_sh_dtrans"
stow_sh::__dotfiles_translate_var() {
    _stow_sh_dtrans="$1"
    stow_sh::is_dotfiles || return 0
    # Fast path: nothing to translate
    [[ "$_stow_sh_dtrans" == *dot-* ]] || return 0

    local -a segs
    local IFS='/'
    read -r -a segs <<< "$_stow_sh_dtrans"

    local out="" seg
    for seg in "${segs[@]}"; do
        [[ "$seg" == dot-* ]] && seg=".${seg#dot-}"
        out+="$seg/"
    done
    _stow_sh_dtrans="${out%/}"
}

# Translate a package-relative path to its link name (dot- → .).
#
# Usage: stow_sh::dotfiles_translate "dot-config/nvim"
# Output: ".config/nvim"
stow_sh::dotfiles_translate() {
    stow_sh::__dotfiles_translate_var "$1"
    printf '%s' "$_stow_sh_dtrans"
}

# Translate a link-relative path back to its package name (. → dot-).
#
# Usage: stow_sh::dotfiles_untranslate ".config/nvim"
# Output: "dot-config/nvim"
stow_sh::dotfiles_untranslate() {
    local path="$1"
    stow_sh::is_dotfiles || {
        printf '%s' "$path"
        return 0
    }

    local -a segs
    local IFS='/'
    read -r -a segs <<< "$path"

    local out="" seg
    for seg in "${segs[@]}"; do
        if [[ "$seg" == .* && "$seg" != "." && "$seg" != ".." ]]; then
            seg="dot-${seg#.}"
        fi
        out+="$seg/"
    done
    printf '%s' "${out%/}"
}
