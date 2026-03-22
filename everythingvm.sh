#!/bin/bash

# set -e: Exit on error | -u: Exit on unset variables | -o pipefail: Catch errors in pipes
set -euo pipefail
export LIBVIRT_DEFAULT_URI='qemu:///system'
TUI_URL="https://raw.githubusercontent.com/OhShabuShabu/dots/heads/main/atlas/tui-engine.sh"

# --- Error Handling Helper ---
# A clean way to exit with a message using gum if available
error_exit() {
    local msg="$1"
    if command -v gum &>/dev/null; then
        gum style --foreground 196 "✖ Error: $msg"
    else
        echo "Error: $msg" >&2
    fi
    exit 1
}

detect_distro() {
    if [ -f /etc/arch-release ]; then
        echo "arch"
    elif [ -f /etc/fedora-release ]; then
        echo "fedora"
    elif [ -f /etc/debian_version ]; then
        echo "debian"
    else
        echo "unknown"
    fi
}

DISTRO=$(detect_distro)
[ "$DISTRO" = "unknown" ] && error_exit "Unsupported distribution detected."

install_gum() {
    command -v gum &>/dev/null && return
    echo "Installing 'gum' for TUI interface..."
    case "$DISTRO" in
    "arch") sudo pacman -S --needed --noconfirm gum >/dev/null ;;
    "fedora") sudo dnf install -y gum >/dev/null ;;
    "debian")
        sudo mkdir -p /etc/apt/keyrings
        curl -fsSL https://repo.charm.sh/apt/gpg.key | sudo gpg --dearmor -o /etc/apt/keyrings/charm.gpg
        echo "deb [signed-by=/etc/apt/keyrings/charm.gpg] https://repo.charm.sh/apt/ * *" | sudo tee /etc/apt/sources.list.d/charm.list >/dev/null
        sudo apt update >/dev/null && sudo apt install -y gum >/dev/null
        ;;
    esac
    command -v gum &>/dev/null || error_exit "Failed to install 'gum'. Please install it manually."
}

install_gum

log() { gum style --foreground 78 "[OK] $1"; }
info() { gum style --foreground 39 "[INFO] $1"; }

init_sudo() {
    info "Requesting sudo privileges..."
    sudo -v || error_exit "Sudo authentication failed."
}

fetch_iso() {
    local url="$1"
    local dest="$2"
    local wget_opts=("-q" "-O" "$dest")

    [[ "$DISTRO" == "fedora" ]] && wget_opts+=("--progress=bar:force") || wget_opts+=("--show-progress")

    if ! wget "${wget_opts[@]}" "$url"; then
        error_exit "Failed to download ISO from $url"
    fi
}

check_yay() {
    if [[ "$DISTRO" == "arch" ]] && ! command -v yay &>/dev/null; then
        gum spin --spinner line --title "Installing yay..." -- bash -c '
            sudo pacman -S --needed --noconfirm base-devel git >/dev/null 2>&1 || exit 1
            tmpdir=$(mktemp -d)
            git clone https://aur.archlinux.org/yay.git "$tmpdir/yay" >/dev/null 2>&1 || exit 1
            cd "$tmpdir/yay" && makepkg -si --noconfirm >/dev/null 2>&1 || exit 1
            rm -rf "$tmpdir"
        ' || error_exit "Failed to install 'yay' (AUR helper)."
    fi
}

install_required() {
    local status=0
    case "$DISTRO" in
    "arch")
        local pkgs=(qemu-full virt-manager virt-viewer dnsmasq vde2 bridge-utils openbsd-netcat libvirt swtpm ovmf ebtables iptables-nft wget)
        gum spin --spinner line --title "Installing virt stack (Arch)..." -- bash -c '
            for pkg in "${pkgs[@]}"; do
                if ! yay -S --needed --noconfirm "$pkg" >/dev/null 2>&1; then
                    error_exit "Failed to install $pkg"
                fi
            done
        '
        status=$?
        ;;
    "fedora")
        gum spin --spinner line --title "Installing virt stack (Fedora)..." -- sudo dnf install -y @virtualization wget >/dev/null 2>&1
        status=$?
        ;;
    "debian")
        local pkgs=(qemu-system-x86 libvirt-daemon-system libvirt-clients virt-manager bridge-utils ovmf swtpm wget)
        gum spin --spinner line --title "Updating apt..." -- sudo apt update >/dev/null 2>&1
        gum spin --spinner line --title "Installing virt stack (Debian)..." -- sudo apt install -y "${pkgs[@]}" >/dev/null 2>&1
        status=$?
        ;;
    esac

    [ $status -ne 0 ] && error_exit "Package installation failed."
    log "Virtualization stack installed."
}

enable_services() {
    gum spin --spinner line --title "Configuring services..." -- bash -c '
        sudo systemctl enable --now libvirtd >/dev/null 2>&1 || exit 1
        sudo virsh net-start default 2>/dev/null || true
        sudo virsh net-autostart default 2>/dev/null || true
        for grp in libvirt libvirt-qemu kvm input disk; do
            sudo usermod -aG "$grp" "$USER" 2>/dev/null || true
        done
    ' || error_exit "Failed to enable libvirtd service."
}

setup_firewall() {
    gum spin --spinner line --title "Setting firewall rules..." -- bash -c '
        if command -v firewall-cmd &>/dev/null; then
            sudo firewall-cmd --permanent --zone=libvirt --add-interface=virbr0 2>/dev/null || true
            sudo firewall-cmd --reload 2>/dev/null || true
        elif command -v ufw &>/dev/null; then
            sudo ufw allow in on virbr0 2>/dev/null || true
            sudo ufw allow out on virbr0 2>/dev/null || true
        fi
    '
}

update_grub_iommu() {
    local grub="/etc/default/grub"
    [ ! -f "$grub" ] && return
    if ! grep -E "intel_iommu=on|amd_iommu=on" "$grub" >/dev/null; then
        local cpu=$(gum choose "Intel" "AMD" --height 4 --header "Select CPU for IOMMU")
        local param=$([[ "$cpu" == "Intel" ]] && echo "intel_iommu=on" || echo "amd_iommu=on")

        gum spin --spinner line --title "Updating GRUB config..." -- bash -c "
            sudo sed -i '/GRUB_CMDLINE_LINUX_DEFAULT=/ s/\"$/ $param\"/' $grub || exit 1
            if [ '$DISTRO' = 'arch' ]; then sudo grub-mkconfig -o /boot/grub/grub.cfg
            elif [ '$DISTRO' = 'fedora' ]; then sudo grub2-mkconfig -o /boot/grub2/grub.cfg
            else command -v update-grub &>/dev/null && sudo update-grub || sudo grub-mkconfig -o /boot/grub/grub.cfg
            fi
        " >/dev/null 2>&1 || error_exit "Failed to update GRUB."
        log "IOMMU enabled ($cpu). Restart required later."
    fi
}

# (OS_URLS mapping stays the same as your source)
declare -A OS_URLS=(
    ["Windows 10"]="https://trashbytes.net/dl/4PTqqKt6mJB_wXE4cTujQS9rjIVQ3gFgH2fn9KJ8Nv7peYgPOL2wCgvB4-RFWQvBaWh113lFOpiUpHDOmMiEYJ6fqiwX48vbaSxyHQDW_widvtWxUqEvs8sOadPuPa79Q0VzPWVqYvohQQD-tCs6VBz3JZieOJ4HKTKGsbbmvCxPX2-F478osl1t_mvspZ7AXY6q7K7risgS?v=1774125334-E%2B%2BwUgVTiRw3aDfQghebvB9oTV52Wi7V%2Bcx%2FjATF%2FIo%3D"
    ["Arch Linux"]="https://geo.mirror.pkgbuild.com/iso/latest/archlinux-x86_64.iso"
    # ... rest of your URLs
)
VIRTIO_URL="https://fedorapeople.org/groups/virt/virtio-win/direct-downloads/archive-virtio/virtio-win-0.1.285-1/virtio-win-0.1.285.iso"

manage_isos() {
    local iso_dir="$HOME/Documents/Iso"
    mkdir -p "$iso_dir" || error_exit "Could not create ISO directory."

    local SELECTED_OS=$(gum choose "${!OS_URLS[@]}" --height 10 --header "Select Guest OS")
    [ -z "$SELECTED_OS" ] && exit 0 # Handle ESC/Cancel

    local clean_name=$(echo "$SELECTED_OS" | cut -d'|' -f1 | xargs | tr '[:upper:]' '[:lower:]' | tr ' ' '_')
    local os_path="$iso_dir/${clean_name}.iso"

    if [[ ! -f "$os_path" ]]; then
        info "Fetching $clean_name ISO..."
        fetch_iso "${OS_URLS[$SELECTED_OS]}" "$os_path"
    fi

    if [[ "$SELECTED_OS" == *"Windows"* ]] && [[ ! -f "$iso_dir/virtio-win.iso" ]]; then
        info "Fetching VirtIO drivers..."
        fetch_iso "$VIRTIO_URL" "$iso_dir/virtio-win.iso"
    fi

    # Fix permissions so libvirt-qemu user can read them
    sudo chmod 644 "$iso_dir"/*.iso
    sudo chown root:root "$iso_dir"/*.iso # or adjust to your system's libvirt user

    export SELECTED_ISO_PATH="$os_path"
    export SELECTED_OS_NAME="$SELECTED_OS"
}

deploy_vm_from_xml() {
    gum confirm "Deploy ${SELECTED_OS_NAME% | *}?" || return
    local default_name=$(echo "${SELECTED_OS_NAME% | *}" | tr ' ' '_' | tr '[:upper:]' '[:lower:]')
    local vm_name=$(gum input --placeholder "VM Name" --value "$default_name")
    local xml_file="/tmp/${vm_name}.xml"
    local disk_path="/var/lib/libvirt/images/${vm_name}.qcow2"

    gum spin --spinner line --title "Fetching XML preset..." -- curl -fsSL https://raw.githubusercontent.com/OhShabuShabu/dots/refs/heads/main/vmpreset.xml -o "$xml_file" || error_exit "Failed to download VM preset."

    # Process XML
    sed -i -e '/<uuid>.*<\/uuid>/d' \
        -e "s/machine='[^']*'/machine='q35'/g" \
        -e "s,<name>win10</name>,<name>$vm_name</name>,g" \
        -e "s,/var/lib/libvirt/images/win10.qcow2,$disk_path,g" \
        -e "s,/home/user/Documents/Iso/win10.iso,$SELECTED_ISO_PATH,g" \
        -e "s,/home/user/,$HOME/,g" "$xml_file"

    # Remove VirtIO line for non-windows
    if [[ "$SELECTED_OS_NAME" != *"Windows"* ]]; then
        sed -i '/virtio-win.iso/d' "$xml_file" # Simplified removal
    fi

    if [ ! -f "$disk_path" ]; then
        gum spin --spinner line --title "Allocating 100G disk..." -- sudo qemu-img create -f qcow2 "$disk_path" 100G >/dev/null || error_exit "Disk allocation failed."
        # Crucial for Debian/Ubuntu: QEMU runs as a specific user
        sudo chown libvirt-qemu:kvm "$disk_path" 2>/dev/null || sudo chown qemu:qemu "$disk_path" 2>/dev/null || true
    fi

    if virsh -c qemu:///system define "$xml_file" >/dev/null; then
        rm -f "$xml_file"
        log "VM '$vm_name' defined successfully."
        if gum confirm "Start $vm_name now?"; then
            virsh -c qemu:///system start "$vm_name" || error_exit "Could not start VM."
            log "VM started."
        fi
    else
        error_exit "Failed to define VM. Check XML syntax or libvirtd status."
    fi
}

# --- Main Logic ---
if ! curl -fsSL "$TUI_URL" -o /tmp/tui-engine.sh; then
    error_exit "Could not download TUI engine."
fi
source /tmp/tui-engine.sh

init_sudo
check_yay
install_required
enable_services
setup_firewall
update_grub_iommu
manage_isos
deploy_vm_from_xml

gum style --border normal --margin "1" --padding "1" --border-foreground 78 "Atlas Setup Complete."
