# Always true — preserves file extensions in annotated paths
# Example: script.conf##extension.sh
stow_sh::condition::extension() {
    return 0
}
