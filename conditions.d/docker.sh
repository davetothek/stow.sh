# SPDX-License-Identifier: MIT
# Copyright (c) 2025 David Kristiansen

# docker — true if running inside a Docker container
#
# Checks for the presence of /.dockerenv, which Docker creates in every
# container at startup.
#
# Usage: file##docker, file##!docker

stow_sh::condition::docker() {
    stow_sh::log debug 3 "Checking for Docker environment"
    [[ -f /.dockerenv ]]
}
