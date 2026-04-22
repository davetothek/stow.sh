# SPDX-License-Identifier: MIT
# Copyright (c) 2025 David Kristiansen

# desktop — true if the system has no battery (stationary machine)
#
# Inverse of the laptop condition. Returns true when no
# /sys/class/power_supply/BAT* directory exists.
#
# Usage: file##desktop, dir##desktop/

stow_sh::condition::desktop() {
    local bat
    for bat in /sys/class/power_supply/BAT*; do
        [[ -d "$bat" ]] && return 1
    done
    return 0
}
