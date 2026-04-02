# SPDX-License-Identifier: MIT
# Copyright (c) 2025 David Kristiansen

# shell — true if the default shell ($SHELL) matches the argument
#
# Compares the basename of $SHELL against the given name. If $SHELL is
# unset, falls back to checking if the shell binary exists in $PATH
# via the exe condition.
#
# Usage: file##shell.bash, file##shell.zsh

stow_sh::condition::shell() {
    local name="$1"
    stow_sh::log debug 3 "Checking current shell matches '$name'"

    if [[ -z "${SHELL:-}" ]]; then
        stow_sh::condition::exe "$name"
        return $?
    fi
    [[ "$(basename "$SHELL")" == "$name" ]]
}
