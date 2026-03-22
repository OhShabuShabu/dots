run_tui_installer() {
    local cmd=() cats=() selected=() item cat var apps

    while [[ "$1" != "--" && -n "$1" ]]; do
        cmd+=("$1")
        shift
    done
    shift
    cats=("$@")
    while true; do
        cat=$(gum choose --header "Selected: ${#selected[@]}" "${cats[@]}" "INSTALL" "EXIT")
        [[ $? -eq 130 || "$cat" == "EXIT" ]] && return 1
        [[ "$cat" == "INSTALL" ]] && { [[ ${#selected[@]} -gt 0 ]] && break || continue; }

        var=$(echo "$cat" | tr '[:lower:]' '[:upper:]' | tr ' ' '_')
        local -n apps="$var"

        for item in $(gum choose --no-limit "${apps[@]}"); do
            [[ " ${selected[*]} " != *" $item "* ]] && selected+=("$item")
        done
    done
    gum spin --spinner dot --title "Installing..." -- "${cmd[@]}" "${selected[@]}"
}
ask() {
    local msg="$1"
    shift
    gum confirm "$msg" && {
        echo "--> Running: $*"
        "$@"
    } || echo "Skipped."
}
check_deps() {
    for dep in gum "$1"; do
        command -v "$dep" >/dev/null || {
            echo "Error: '$dep' is missing."
            return 1
        }
    done
}
