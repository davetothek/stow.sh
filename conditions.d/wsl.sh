# SPDX-License-Identifier: MIT
# Copyright (c) 2025 David Kristiansen

# wsl — true if running inside Windows Subsystem for Linux
#
# Checks /proc/version for "microsoft" or "wsl" (case-insensitive).
#
# Usage: file##wsl, file##!wsl

stow_sh::condition::wsl() {
    stow_sh::log debug 3 "Checking for WSL environment"
    if [[ ! -f /proc/version ]]; then
        return 1
    fi
    grep -qi 'microsoft\|wsl' /proc/version 2> /dev/null
}
