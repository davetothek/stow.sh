# Match default shell basename
# Example: file##shell.bash, file##shell.zsh
stow_sh::condition::shell() {
    local name="$1"
    stow_sh::log debug 3 "Checking current shell matches '$name'"

    if [[ -z "${SHELL:-}" ]]; then
        stow_sh::condition::exe "$name"
        return $?
    fi
    [[ "$(basename "$SHELL")" == "$name" ]]
}
