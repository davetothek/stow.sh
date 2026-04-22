# SPDX-License-Identifier: MIT
# Copyright (c) 2025 David Kristiansen

# laptop — true if the system has a battery (portable machine)
#
# Checks for /sys/class/power_supply/BAT* which is present on laptops.
#
# Usage: file##laptop, dir##laptop/

stow_sh::condition::laptop() {
    local bat
    for bat in /sys/class/power_supply/BAT*; do
        [[ -d "$bat" ]] && return 0
    done
    return 1
}
