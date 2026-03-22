#!/bin/bash
set -euo pipefail

TUI_URL="https://raw.githubusercontent.com/OhShabuShabu/dots/heads/main/atlas/tui-engine.sh"

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

install_gum() {
    if command -v gum &>/dev/null; then return; fi
    if [ "$DISTRO" = "arch" ]; then
        sudo pacman -S --needed --noconfirm gum
    elif [ "$DISTRO" = "fedora" ]; then
        sudo dnf install -y gum
    elif [ "$DISTRO" = "debian" ]; then
        sudo mkdir -p /etc/apt/keyrings
        curl -fsSL https://repo.charm.sh/apt/gpg.key | sudo gpg --dearmor -o /etc/apt/keyrings/charm.gpg
        echo "deb [signed-by=/etc/apt/keyrings/charm.gpg] https://repo.charm.sh/apt/ * *" | sudo tee /etc/apt/sources.list.d/charm.list
        sudo apt update && sudo apt install -y gum
    fi
}

log() { gum style --foreground 78 " [✓] $1"; }
warn() { gum style --foreground 214 " [!] $1"; }
info() { gum style --foreground 39 " [i] $1"; }

init_sudo() {
    info "Requesting sudo privileges..."
    sudo -v
    while true; do
        sudo -n true
        sleep 60
        kill -0 "$$" || exit
    done 2>/dev/null &
}

check_yay() {
    if [[ "$DISTRO" == "arch" ]]; then
        if ! command -v yay &>/dev/null; then
            info "Arch detected: Installing yay..."
            sudo pacman -S --needed --noconfirm base-devel git
            local tmpdir=$(mktemp -d)
            git clone https://aur.archlinux.org/yay.git "$tmpdir/yay"
            pushd "$tmpdir/yay" >/dev/null && makepkg -si --noconfirm && popd >/dev/null
            rm -rf "$tmpdir"
        fi
    fi
}

install_required() {
    info "Installing virtualization stack for $DISTRO..."
    case "$DISTRO" in
    "arch")
        local packages=(qemu-full virt-manager virt-viewer dnsmasq vde2 bridge-utils openbsd-netcat libvirt swtpm ovmf ebtables iptables-nft wget)
        gum spin --spinner dot --title "Installing Arch packages..." -- yay -S --needed --noconfirm "${packages[@]}"
        ;;
    "fedora")
        gum spin --spinner dot --title "Installing Fedora packages..." -- sudo dnf install -y @virtualization wget
        ;;
    "debian")
        local packages=(qemu-system-x86 libvirt-daemon-system libvirt-clients virt-manager bridge-utils ovmf swtpm wget)
        gum spin --spinner dot --title "Installing Debian/Ubuntu packages..." -- bash -c "sudo apt update && sudo apt install -y ${packages[*]}"
        ;;
    esac
}

enable_services() {
    info "Enabling libvirt services..."
    sudo systemctl enable --now libvirtd
    sudo virsh net-start default 2>/dev/null || true
    sudo virsh net-autostart default 2>/dev/null || true
    local groups=(libvirt libvirt-qemu kvm input disk)
    for grp in "${groups[@]}"; do
        sudo usermod -aG "$grp" "$USER" 2>/dev/null || true
    done
}

setup_firewall() {
    info "Configuring firewall rules..."
    if command -v firewall-cmd &>/dev/null; then
        sudo firewall-cmd --permanent --zone=libvirt --add-interface=virbr0 2>/dev/null || true
        sudo firewall-cmd --reload 2>/dev/null
    elif command -v ufw &>/dev/null; then
        sudo ufw allow in on virbr0 2>/dev/null
        sudo ufw allow out on virbr0 2>/dev/null
    fi
}

update_grub_iommu() {
    local grub_config="/etc/default/grub"
    [ ! -f "$grub_config" ] && return
    if ! grep -E "intel_iommu=on|amd_iommu=on" "$grub_config" >/dev/null; then
        local cpu_type=$(gum choose "Intel" "AMD" --header "Select CPU for IOMMU")
        local param="amd_iommu=on"
        [[ "$cpu_type" == "Intel" ]] && param="intel_iommu=on"
        sudo sed -i "/GRUB_CMDLINE_LINUX_DEFAULT=/ s/\"$/ $param\"/" "$grub_config"
        info "Updating GRUB configuration..."
        case "$DISTRO" in
        "arch") sudo grub-mkconfig -o /boot/grub/grub.cfg ;;
        "fedora") sudo grub2-mkconfig -o /boot/grub2/grub.cfg ;;
        "debian") command -v update-grub &>/dev/null && sudo update-grub || sudo grub-mkconfig -o /boot/grub/grub.cfg ;;
        esac
        log "IOMMU enabled."
    fi
}

declare -A OS_URLS=(
    ["Windows 11 | Latest Microsoft OS with modern UI and Snap layouts"]="https://dl.zerofs.link/dl/eyJhbGciOiJIUzI1NiIsInR5cCI6IkpXVCJ9.eyJidWNrZXQiOiJhc3NldHMtYW1zIiwia2V5Ijoib05xNVlUcml4ekJlZGtoRzJxZXl2cS80M2I3YzZkMDRmY2Q0ZDNhOGJjZjQ1NTA3MTlhOTI4ZiIsImZpbGVuYW1lIjoiZW4tdXNfd2luZG93c18xMV9jb25zdW1lcl9lZGl0aW9uc192ZXJzaW9uXzI1aDJfdXBkYXRlZF9tYXJjaF8yMDI2X3g2NF9kdmRfYTFjZjZjMzYuaXNvIiwicmVnaW9uIjoiZXUiLCJlbmRwb2ludCI6InMzLmV1LWNlbnRyYWwtMDAzLmJhY2tibGF6ZWIyLmNvbSIsImV4cCI6MTc3NDE2OTUzMSwia2V5X2I2NCI6InFEaXplTUhDcUJZQ1BHT2QzdzRWV2pZSGxoVVN3V2dTN2F5K29XSEliSlU9Iiwia2V5X21kNSI6Ijc4OEk3cnc5emU0MEJzRys2QmM2Rmc9PSJ9.BeeZj3sTxQRi3qfwptimTQhQfk4D4xA6QXkcrKDtuVQ"
    ["Windows 10 | Reliable and widely compatible legacy Microsoft OS"]="https://trashbytes.net/dl/4PTqqKt6mJB_wXE4cTujQS9rjIVQ3gFgH2fn9KJ8Nv7peYgPOL2wCgvB4-RFWQvBaWh113lFOpiUpHDOmMiEYJ6fqiwX48vbaSxyHQDW_widvtWxUqEvs8sOadPuPa79Q0VzPWVqYvohQQD-tCs6VBz3JZieOJ4HKTKGsbbmvCxPX2-F478osl1t_mvspZ7AXY6q7K7risgS?v=1774125334-E%2B%2BwUgVTiRw3aDfQghebvB9oTV52Wi7V%2Bcx%2FjATF%2FIo%3D"
    ["Arch Linux | Bleeding-edge rolling release for power users"]="https://geo.mirror.pkgbuild.com/iso/latest/archlinux-x86_64.iso"
    ["Ubuntu 24.04 | Most popular user-friendly Linux with 5-year LTS"]="https://releases.ubuntu.com/24.04/ubuntu-24.04.4-desktop-amd64.iso"
    ["Fedora 41 | Innovative workstation featuring the latest GNOME desktop"]="https://download.fedoraproject.org/pub/fedora/linux/releases/41/Workstation/x86_64/iso/Fedora-Workstation-Live-x86_64-41-1.4.iso"
    ["Linux Mint 22.3 | Familiar Cinnamon desktop, perfect for Windows converts"]="https://ftp.fau.de/mint/iso/stable/22.3/linuxmint-22.3-cinnamon-64bit.iso"
    ["Debian 12.13 | The rock-solid 'Universal OS' known for stability"]="https://ftp.thm.de/debian-cd/debian-12.13.0-amd64-DVD-1.iso"
    ["Manjaro 26.0 | User-friendly Arch-based distro with XFCE desktop"]="https://download.manjaro.org/xfce/26.0.3/manjaro-xfce-26.0.3-260228-linux618.iso"
    ["Kali Linux 2026.1 | Leading platform for penetration testing and security"]="https://ftp.riken.jp/Linux/kali-images/kali-weekly/kali-linux-2026-W12-installer-amd64.iso"
    ["Pop!_OS 24.04 LTS | Optimized for STEM and gaming with the COSMIC desktop"]="https://iso.pop-os.org/24.04/amd64/intel/1/pop-os_24.04_amd64_intel_1.iso"
)
VIRTIO_URL="https://fedorapeople.org/groups/virt/virtio-win/direct-downloads/archive-virtio/virtio-win-0.1.285-1/virtio-win-0.1.285.iso"

manage_isos() {
    local iso_dir="$HOME/Documents/Iso"
    mkdir -p "$iso_dir"
    local SELECTED_OS=$(gum choose "${!OS_URLS[@]}" --header "Choose OS ISO")
    local clean_name=$(echo "$SELECTED_OS" | cut -d'|' -f1 | xargs | tr '[:upper:]' '[:lower:]' | tr ' ' '_')
    local os_path="$iso_dir/${clean_name}.iso"

    if [[ ! -f "$os_path" ]]; then
        info "Downloading $SELECTED_OS..."
        wget -q --show-progress -O "$os_path" "${OS_URLS[$SELECTED_OS]}"
    fi

    if [[ "$SELECTED_OS" == *"Windows"* ]]; then
        if [[ ! -f "$iso_dir/virtio-win.iso" ]]; then
            info "Downloading VirtIO drivers for Windows..."
            wget -q --show-progress -O "$iso_dir/virtio-win.iso" "$VIRTIO_URL"
        fi
    fi

    sudo chmod 777 "$iso_dir"/*.iso
    export SELECTED_ISO_PATH="$os_path"
    export SELECTED_OS_NAME="$SELECTED_OS"
}

deploy_vm_from_xml() {
    if ! gum confirm "Deploy $SELECTED_OS_NAME?"; then return; fi
    local vm_name=$(gum input --placeholder "Enter VM Name")
    vm_name=${vm_name:-$(echo "$SELECTED_OS_NAME" | cut -d'|' -f1 | tr -d ' ' | tr '[:upper:]' '[:lower:]')}
    local xml_file="/tmp/${vm_name}.xml"
    local disk_path="/var/lib/libvirt/images/${vm_name}.qcow2"

    info "Fetching VM preset..."
    curl -fsSL https://raw.githubusercontent.com/OhShabuShabu/dots/refs/heads/main/vmpreset.xml -o "$xml_file"

    sed -i "s,<name>win10</name>,<name>$vm_name</name>,g" "$xml_file"
    sed -i "s,/var/lib/libvirt/images/win10.qcow2,$disk_path,g" "$xml_file"
    sed -i "s,/home/user/Documents/Iso/win10.iso,$SELECTED_ISO_PATH,g" "$xml_file"
    sed -i "s,/home/user/,$HOME/,g" "$xml_file"

    if [[ "$SELECTED_OS_NAME" != *"Windows"* ]]; then
        info "Non-Windows OS: Stripping VirtIO driver block from XML..."
        local match_line=$(grep -n "virtio-win.iso" "$xml_file" | cut -d: -f1 || true)
        if [[ -n "$match_line" ]]; then
            sed -i "$((match_line - 2)),$((match_line + 5))d" "$xml_file"
        fi
    fi

    if [ ! -f "$disk_path" ]; then
        info "Creating 100G virtual disk..."
        sudo qemu-img create -f qcow2 "$disk_path" 100G >/dev/null
        sudo chown libvirt-qemu:kvm "$disk_path" 2>/dev/null || true
    fi

    if virsh define "$xml_file"; then
        log "VM $vm_name defined successfully."
        rm -f "$xml_file"
        if gum confirm "Start VM now?"; then
            virsh start "$vm_name"
            log "VM started."
        fi
    fi
}

install_gum
if ! curl -fsSL "$TUI_URL" -o /tmp/tui-engine.sh; then exit 1; fi
source /tmp/tui-engine.sh
init_sudo
check_yay
install_required
enable_services
setup_firewall
update_grub_iommu
manage_isos
deploy_vm_from_xml
log "Setup complete. Please reboot for certain changes to take effect."
