# SPDX-License-Identifier: MIT
# Copyright (c) 2025 David Kristiansen

# shellcheck shell=bash

# container — true if running inside any container runtime
#
# Broader than `docker`: checks the marker files Docker and Podman create,
# plus the $container environment variable set by Podman, systemd-nspawn
# and LXC.
#
# Usage: file##container, file##!container

stow_sh::condition::container() {
    stow_sh::log debug 3 "Checking for container environment"
    [[ -f /.dockerenv ]] && return 0        # docker
    [[ -f /run/.containerenv ]] && return 0 # podman
    [[ -n ${container:-} ]] && return 0     # podman, systemd-nspawn, lxc
    return 1
}
