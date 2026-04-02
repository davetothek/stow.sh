# SPDX-License-Identifier: MIT
# Copyright (c) 2025 David Kristiansen

# log.sh — logging framework with color and debug levels
#
# All log output goes to stderr so it never interferes with stdout data
# (e.g. resolved target lists piped between functions). Debug messages
# are gated by a numeric verbosity level set at startup.
#
# No dependencies.

# Module state — color and verbosity are configured once via log_setup.
_stow_sh_use_color=false
_stow_sh_debug_level=0

# Check if the terminal supports at least 8 colors.
#
# Returns: 0 if color is supported, 1 otherwise
stow_sh::__supports_color() {
    [[ -t 1 ]] && tput colors &> /dev/null && [[ $(tput colors) -ge 8 ]]
}

# Configure the logging subsystem.
#
# Usage: stow_sh::log_setup <color_mode> [debug_level]
#   color_mode — "always", "auto", or "never"
#   debug_level — numeric verbosity (0 = off, higher = more verbose)
stow_sh::log_setup() {
    local mode="${1:-auto}"
    _stow_sh_debug_level="${2:-0}"
    case "$mode" in
        always) _stow_sh_use_color=true ;;
        auto)   stow_sh::__supports_color && _stow_sh_use_color=true || true ;;
        never)  _stow_sh_use_color=false ;;
    esac
}

# ANSI color codes for each log level.
_stow_sh__c_reset="\033[0m"
_stow_sh__c_debug="\033[36m"  # cyan
_stow_sh__c_info="\033[32m"   # green
_stow_sh__c_warn="\033[33m"   # yellow
_stow_sh__c_error="\033[31m"  # red

# Emit a log message to stderr.
#
# Debug messages require a numeric level after the "debug" keyword;
# the message is only printed if that level is at or below the current
# verbosity setting.
#
# Usage: stow_sh::log <level> [debug_level] <message...>
#   level — "debug", "info", "warn", or "error"
stow_sh::log() {
    local level="$1"
    shift

    local debug=0
    if [[ "$level" == "debug" ]]; then
        debug="$1"
        shift
        if ((debug > _stow_sh_debug_level)); then   return; fi
    fi

    local message="$*"
    local prefix=""
    local color=""

    case "$level" in
        debug)
            prefix="[DEB]"
            color="$_stow_sh__c_debug"
        ;;
        info)
            prefix="[INF]"
            color="$_stow_sh__c_info"
        ;;
        warn)
            prefix="[WAR]"
            color="$_stow_sh__c_warn"
        ;;
        error)
            prefix="[ERR]"
            color="$_stow_sh__c_error"
        ;;
        *)     prefix="[LOG]" ;;
    esac

    if [[ "$_stow_sh_use_color" == true ]]; then
        printf "%b %s\n" "${color}${prefix}${_stow_sh__c_reset}" "$message" >&2
    else
        printf "%s %s\n" "$prefix" "$message" >&2
    fi
}
