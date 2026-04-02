# SPDX-License-Identifier: MIT
# Copyright (c) 2025 David Kristiansen

# exe — true if an executable is found in $PATH
#
# The argument after the dot is the binary name to look for.
#
# Usage: file##exe.nvim, file##exe.docker

stow_sh::condition::exe() {
    local name="$1"
    stow_sh::log debug 3 "Checking for executable '$name' in PATH"
    command -v "$name" > /dev/null 2>&1
}
