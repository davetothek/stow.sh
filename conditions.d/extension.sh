# SPDX-License-Identifier: MIT
# Copyright (c) 2025 David Kristiansen

# extension — always true; preserves file extensions in annotated paths
#
# Useful when a file's real extension would be misinterpreted by another
# tool. The ## annotation keeps the extension in the source filename
# while the condition always passes.
#
# Usage: script.conf##extension.sh

stow_sh::condition::extension() {
    return 0
}
