#!/usr/bin/env bash
# SPDX-License-Identifier: MIT
# Copyright (c) 2025 David Kristiansen

# update_toc.sh — regenerate the table of contents in README.md.
#
# Replaces the block between <!--toc:start--> and <!--toc:end--> with a TOC
# built from the markdown headings (## through ######), skipping fenced code
# blocks and the TOC block itself. Idempotent. Run via: make toc
#
# Usage: scripts/update_toc.sh [README.md]

set -euo pipefail

README="${1:-README.md}"
TOC_START="<!--toc:start-->"
TOC_END="<!--toc:end-->"

[[ -f "$README" ]] || {
    echo >&2 "update_toc: '$README' not found"
    exit 1
}
grep -qF "$TOC_START" "$README" || {
    echo >&2 "update_toc: '$TOC_START' marker not found in $README"
    exit 1
}
grep -qF "$TOC_END" "$README" || {
    echo >&2 "update_toc: '$TOC_END' marker not found in $README"
    exit 1
}

# Convert heading text to a GitHub-compatible anchor slug.
stow_sh::slug() {
    local text="$1"
    # Strip inline markdown: **bold**, *italic*, `code`, [text](url).
    # The backticks below are literal regex characters, not command
    # substitution — single quotes are intentional.
    # shellcheck disable=SC2016
    text="$(printf '%s' "$text" | sed -E \
        -e 's/\*\*([^*]+)\*\*/\1/g' \
        -e 's/\*([^*]+)\*/\1/g' \
        -e 's/`([^`]+)`/\1/g' \
        -e 's/\[([^]]+)\]\([^)]+\)/\1/g')"
    text="${text,,}" # lowercase
    # Drop everything except word chars, spaces and hyphens; spaces → hyphens.
    printf '%s' "$text" | sed -E -e 's/[^a-z0-9 _-]//g' -e 's/[[:space:]]+/-/g'
}

# Emit the TOC (one entry per line) from README's headings.
stow_sh::generate_toc() {
    local in_fence=false in_toc=false line
    while IFS= read -r line; do
        # Skip the existing TOC block so it never indexes itself.
        [[ "$line" == "$TOC_START"* ]] && {
            in_toc=true
            continue
        }
        [[ "$line" == "$TOC_END"* ]] && {
            in_toc=false
            continue
        }
        $in_toc && continue

        # Track fenced code blocks — ``` toggles in/out.
        if [[ "$line" == '```'* ]]; then
            if $in_fence; then in_fence=false; else in_fence=true; fi
            continue
        fi
        $in_fence && continue

        [[ "$line" =~ ^(#{2,6})[[:space:]]+(.+)$ ]] || continue
        local hashes="${BASH_REMATCH[1]}" text="${BASH_REMATCH[2]}"
        local level=${#hashes} indent="" n
        for ((n = 2; n < level; n++)); do indent+="  "; done
        printf '%s- [%s](#%s)\n' "$indent" "$text" "$(stow_sh::slug "$text")"
    done < "$README"
}

original="$(cat "$README")"

toc_file="$(mktemp)"
trap 'rm -f "$toc_file"' EXIT
stow_sh::generate_toc > "$toc_file"

# Rewrite the file: keep the markers, replace everything between them.
awk -v start="$TOC_START" -v end="$TOC_END" -v tocfile="$toc_file" '
    index($0, start) { print; while ((getline l < tocfile) > 0) print l; close(tocfile); skip = 1; next }
    index($0, end)   { skip = 0; print; next }
    skip             { next }
    { print }
' "$README" > "$README.tmp"
mv "$README.tmp" "$README"

if [[ "$(cat "$README")" != "$original" ]]; then
    echo "Updated TOC in $README"
else
    echo "TOC already up to date"
fi
