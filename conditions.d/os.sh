# Match OS name from /etc/os-release (lowercased)
# Example: file##os.linux
stow_sh::condition::os() {
    local name="$1"
    stow_sh::log debug 3 "Checking OS equals '$name'"

    if [[ ! -f /etc/os-release ]]; then
        stow_sh::log debug 2 "No /etc/os-release found"
        return 1
    fi

    local os
    os=$(grep -E "^NAME=" /etc/os-release) || return 1
    os="${os#*=}"
    os="${os//\"/}"
    os="${os,,}"
    [[ "$os" == "$name" ]]
}
