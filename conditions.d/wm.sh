# SPDX-License-Identifier: MIT
# Copyright (c) 2025 David Kristiansen

# wm — alias for exe; true if a window manager binary is in $PATH
#
# Semantically distinct from exe to make dotfile annotations more
# readable (##wm.sway vs ##exe.sway), but delegates to the same check.
#
# Usage: file##wm.sway, file##wm.i3

stow_sh::condition::wm() {
    stow_sh::condition::exe "$1"
}
