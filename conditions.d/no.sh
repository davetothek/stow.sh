# SPDX-License-Identifier: MIT
# Copyright (c) 2025 David Kristiansen

# no — always fails; files annotated with ##no are never deployed.
# Useful for tracking files in the dotfiles repo that should not
# be symlinked into $HOME (e.g. lock files, caches).

stow_sh::condition::no() {
    return 1
}
