# SPDX-License-Identifier: MIT
# Copyright (c) 2025 David Kristiansen

# scan.sh — find symlink candidates inside stow packages

stow_sh::scan_package() {
    local pkg_dir="$1"

    stow_sh::log debug 2 "Scanning package directory: '$pkg_dir'"

    if [[ ! -d "$pkg_dir" ]]; then
        stow_sh::log error "Package directory '$pkg_dir' not found or is not a directory"
        return 1
    fi

    # Find all files one level down or deeper (directories are excluded;
    # the fold phase reconstructs directory structure from file paths)
    find "$pkg_dir" -mindepth 1 -type f -print
}
