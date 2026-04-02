# True if running inside Docker (/.dockerenv exists)
# Example: file##docker, file##!docker
stow_sh::condition::docker() {
    stow_sh::log debug 3 "Checking for Docker environment"
    [[ -f /.dockerenv ]]
}
