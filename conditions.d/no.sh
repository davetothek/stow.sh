# SPDX-License-Identifier: MIT
# Copyright (c) 2025 David Kristiansen

# no — always false; files annotated with ##no are never deployed
#
# Useful for tracking files in the dotfiles repo that should not be
# symlinked into $HOME (e.g. lock files, caches, git submodules).
# When used on a directory segment, all files inside are skipped
# via condition propagation.
#
# Usage: file##no, dir##no/

stow_sh::condition::no() {
    return 1
}
