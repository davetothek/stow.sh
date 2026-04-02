# SPDX-License-Identifier: MIT
# Copyright (c) 2025 David Kristiansen

# scan.sh — package directory scanner
#
# Recursively finds all regular files inside a stow package directory.
# Directories are not emitted — the fold phase reconstructs directory
# structure from the flat file list.
#
# Depends on: log.sh

# Scan a package directory and output all file paths.
#
# Usage: stow_sh::scan_package /absolute/path/to/package
# Output: one absolute file path per line
stow_sh::scan_package() {
    local pkg_dir="$1"

    stow_sh::log debug 2 "Scanning package directory: '$pkg_dir'"

    if [[ ! -d "$pkg_dir" ]]; then
        stow_sh::log error "Package directory '$pkg_dir' not found or is not a directory"
        return 1
    fi

    # Only regular files — directories are excluded; the fold phase
    # reconstructs directory structure from file paths.
    find "$pkg_dir" -mindepth 1 -type f -print
}
