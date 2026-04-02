#!/usr/bin/env bash
# SPDX-License-Identifier: MIT
# Copyright (c) 2025 David Kristiansen

# bin/stow.sh — CLI entrypoint
#
# Resolves STOW_ROOT to the project directory and exec's into the main
# orchestrator. This file is the user-facing command; it should be
# symlinked or added to $PATH.
#
# No dependencies (bootstraps STOW_ROOT for all other modules).

set -euo pipefail

STOW_ROOT="$(cd "$(dirname "$(readlink -f "${BASH_SOURCE[0]}")")/.." && pwd)"

exec "${STOW_ROOT}/src/main.sh" "$@"
