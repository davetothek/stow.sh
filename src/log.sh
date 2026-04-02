#!/usr/bin/env bash
# SPDX-License-Identifier: MIT
# Copyright (c) 2025 David Kristiansen

_stow_sh_use_color=false
_stow_sh_debug_level=0

stow_sh::__supports_color() {
    [[ -t 1 ]] && tput colors &> /dev/null && [[ $(tput colors) -ge 8 ]]
}

stow_sh::log_setup() {
    local mode="${1:-auto}"
    _stow_sh_debug_level="${2:-0}"
    case "$mode" in
        always) _stow_sh_use_color=true ;;
        auto)   stow_sh::__supports_color && _stow_sh_use_color=true || true ;;
        never)  _stow_sh_use_color=false ;;
    esac
}

# ANSI color codes
_stow_sh__c_reset="\033[0m"
_stow_sh__c_debug="\033[36m"  # cyan
_stow_sh__c_info="\033[32m"   # green
_stow_sh__c_warn="\033[33m"   # yellow
_stow_sh__c_error="\033[31m"  # red

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
