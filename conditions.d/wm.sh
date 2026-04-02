# Alias for exe — check if a window manager binary is available
# Example: file##wm.sway, file##wm.i3
stow_sh::condition::wm() {
    stow_sh::condition::exe "$1"
}
