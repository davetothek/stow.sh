# SPDX-License-Identifier: MIT
# Copyright (c) 2025 David Kristiansen

# os — true if the OS name from /etc/os-release matches the argument
#
# Reads the NAME= field from /etc/os-release, strips quotes, and
# compares case-insensitively (both sides lowercased).
#
# Usage: file##os.linux, file##os.arch

stow_sh::condition::os() {
    local name="$1"
    stow_sh::log debug 3 "Checking OS equals '$name'"

    if [[ ! -f /etc/os-release ]]; then
        stow_sh::log debug 2 "No /etc/os-release found"
        return 1
    fi

    local os
    os=$(grep -E "^NAME=" /etc/os-release) || return 1
    os="${os#*=}"
    os="${os//\"/}"
    os="${os,,}"
    [[ "$os" == "$name" ]]
}
