# True if executable is in $PATH
# Example: file##exe.nvim, file##exe.docker
stow_sh::condition::exe() {
    local name="$1"
    stow_sh::log debug 3 "Checking for executable '$name' in PATH"
    command -v "$name" > /dev/null 2>&1
}
