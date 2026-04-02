# True if running inside WSL
# Example: file##wsl, file##!wsl
stow_sh::condition::wsl() {
    stow_sh::log debug 3 "Checking for WSL environment"
    if [[ ! -f /proc/version ]]; then
        return 1
    fi
    grep -qi 'microsoft\|wsl' /proc/version 2> /dev/null
}
