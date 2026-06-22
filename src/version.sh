# SPDX-License-Identifier: MIT
# Copyright (c) 2025 David Kristiansen

# shellcheck shell=bash

# version.sh — version constant
#
# Single source of truth for the stow.sh version string.
# No dependencies.

# Read by args.sh (--version / --help). shellcheck can't see cross-module use.
# shellcheck disable=SC2034
STOW_SH_VERSION="0.16.1"
