#!/bin/bash
# install_virtmanager.sh -
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

    echo " [i] Installing 'gum' for TUI support..."
    case "$DISTRO" in
    "arch") sudo pacman -S --needed --noconfirm gum ;;
    "fedora") sudo dnf install -y gum ;;
    "debian")
        sudo mkdir -p /etc/apt/keyrings
        curl -fsSL https://repo.charm.sh/apt/gpg.key | sudo gpg --dearmor -o /etc/apt/keyrings/charm.gpg
        echo "deb [signed-by=/etc/apt/keyrings/charm.gpg] https://repo.charm.sh/apt/ * *" | sudo tee /etc/apt/sources.list.d/charm.list
        sudo apt update && sudo apt install -y gum
        ;;
    *)
        echo "Unsupported distro for auto-gum install."
        exit 1
        ;;
    esac
}
init_sudo() {
    echo " [i] sudo privileges are required."
    sudo -v
    while true; do
        sudo -n true
        sleep 60
        kill -0 "$$" || exit
    done 2>/dev/null &
}

# --- Logic: ONLY use yay if Arch is detected ---
check_yay() {
    if [[ "$DISTRO" == "arch" ]]; then
        if ! command -v yay &>/dev/null; then
            echo " [i] Arch detected: Installing 'yay' for AUR support..."
            sudo pacman -S --needed --noconfirm base-devel git
            local tmpdir
            tmpdir=$(mktemp -d)
            git clone https://aur.archlinux.org/yay.git "$tmpdir/yay"
            pushd "$tmpdir/yay" >/dev/null && makepkg -si --noconfirm && popd >/dev/null
            rm -rf "$tmpdir"
        fi
    fi
}

install_required() {
    case "$DISTRO" in
    "arch")
        local packages=(qemu-full virt-manager virt-viewer dnsmasq vde2 bridge-utils openbsd-netcat libvirt swtpm ovmf ebtables iptables-nft wget)
        gum spin --spinner dot --title "Installing for Arch (via yay)..." -- yay -S --needed --noconfirm "${packages[@]}"
        ;;
    "fedora")
        gum spin --spinner dot --title "Installing for Fedora (via dnf)..." -- sudo dnf install -y @virtualization wget
        ;;
    "debian")
        local packages=(qemu-system-x86 libvirt-daemon-system libvirt-clients virt-manager bridge-utils ovmf swtpm wget)
        gum spin --spinner dot --title "Installing for Debian/Ubuntu (via apt)..." -- bash -c "sudo apt update && sudo apt install -y ${packages[*]}"
        ;;
    *)
        echo "Unknown distro. Manual intervention required."
        exit 1
        ;;
    esac
}

log() { gum style --foreground 78 " [✓] $1"; }
warn() { gum style --foreground 214 " [!] $1"; }
info() { gum style --foreground 39 " [i] $1"; }

enable_services() {
    sudo systemctl enable --now libvirtd
    sudo virsh net-start default 2>/dev/null || true
    sudo virsh net-autostart default 2>/dev/null || true
    local groups=(libvirt libvirt-qemu kvm input disk)
    for grp in "${groups[@]}"; do
        sudo usermod -aG "$grp" "$USER" 2>/dev/null || true
    done
}

setup_firewall() {
    if command -v firewall-cmd &>/dev/null; then
        gum spin --spinner dot --title "Configuring Firewalld..." -- bash -c '
            sudo firewall-cmd --permanent --zone=libvirt --add-interface=virbr0 2>/dev/null || true
            sudo firewall-cmd --reload 2>/dev/null
        '
    elif command -v ufw &>/dev/null; then
        gum spin --spinner dot --title "Configuring UFW..." -- bash -c '
            sudo ufw allow in on virbr0 2>/dev/null
            sudo ufw allow out on virbr0 2>/dev/null
            sudo sed -i "s/^#net\/ipv4\/ip_forward=1/net\/ipv4\/ip_forward=1/" /etc/ufw/sysctl.conf
        '
    fi
}

update_grub_iommu() {
    local grub_config="/etc/default/grub"
    [ ! -f "$grub_config" ] && return

    if ! grep -E "intel_iommu=on|amd_iommu=on" "$grub_config" >/dev/null; then
        local cpu_type
        cpu_type=$(gum choose "Intel" "AMD" --header "CPU Architecture")
        local param="amd_iommu=on"
        [[ "$cpu_type" == "Intel" ]] && param="intel_iommu=on"

        sudo sed -i "/GRUB_CMDLINE_LINUX_DEFAULT=/ s/\"$/ $param\"/" "$grub_config"

        info "Updating GRUB menu..."
        if [ -f /boot/grub/grub.cfg ]; then
            sudo grub-mkconfig -o /boot/grub/grub.cfg
        elif [ -f /boot/efi/EFI/fedora/grub.cfg ]; then
            sudo grub-mkconfig -o /boot/efi/EFI/fedora/grub.cfg
        elif command -v update-grub &>/dev/null; then
            sudo update-grub
        fi
    fi
}

# --- OS Links & Configuration ---
declare -A OS_URLS=(
    ["Windows 11 | Latest Microsoft OS with modern UI and Snap layouts"]="https://dl.zerofs.link/dl/eyJhbGciOiJIUzI1NiIsInR5cCI6IkpXVCJ9.eyJidWNrZXQiOiJhc3NldHMtYW1zIiwia2V5Ijoib05xNVlUcml4ekJlZGtoRzJxZXl2cS80M2I3YzZkMDRmY2Q0ZDNhOGJjZjQ1NTA3MTlhOTI4ZiIsImZpbGVuYW1lIjoiZW4tdXNfd2luZG93c18xMV9jb25zdW1lcl9lZGl0aW9uc192ZXJzaW9uXzI1aDJfdXBkYXRlZF9tYXJjaF8yMDI2X3g2NF9kdvdfYTFjZjZjMzYuaXNvIiwicmVnaW9uIjoiZXUiLCJlbmRwb2ludCI6InMzLmV1LWNlbnRyYWwtMDAzLmJhY2tibGF6ZWIyLmNvbSIsImV4cCI6MTc3NDE2OTUzMSwia2V5X2I2NCI6InFEaXplTUhDcUJZQ1BHT2QzdzRWV2pZSGxoVVN3V2dTN2F5K29XSEliSlU9Iiwia2V5X21kNSI6Ijc4OEk3cnc5emU0MEJzRys2QmM2Rmc9PSJ9.BeeZj3sTxQRi3qfwptimTQhQfk4D4xA6QXkcrKDtuVQ"
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

    local SELECTED_OS
    SELECTED_OS=$(gum choose "${!OS_URLS[@]}" --header "Select Operating System to Download")

    local clean_name
    clean_name=$(echo "$SELECTED_OS" | cut -d'|' -f1 | xargs | tr '[:upper:]' '[:lower:]' | tr ' ' '_')

    local os_filename="${clean_name}.iso"
    local os_path="$iso_dir/$os_filename"

    if [[ ! -f "$os_path" ]]; then
        info "Fetching $SELECTED_OS..."
        wget -q --show-progress -O "$os_path" "${OS_URLS[$SELECTED_OS]}"
    fi

    if [[ "$SELECTED_OS" == *"Windows 10"* ]]; then
        if [[ ! -f "$iso_dir/virtio-win.iso" ]]; then
            info "Fetching VirtIO Drivers..."
            wget -q --show-progress -O "$iso_dir/virtio-win.iso" "$VIRTIO_URL"
        fi
    fi

    sudo chmod 777 "$iso_dir"/*.iso
    export SELECTED_ISO_PATH="$os_path"
    export SELECTED_OS_NAME="$SELECTED_OS"
}

deploy_vm_from_xml() {
    if ! gum confirm "Deploy $SELECTED_OS_NAME VM?"; then return; fi

    local vm_name
    vm_name=$(gum input --placeholder "Name (e.g., my-vm)")
    vm_name=${vm_name:-$(echo "$SELECTED_OS_NAME" | cut -d'|' -f1 | tr -d ' ' | tr '[:upper:]' '[:lower:]')}

    local disk_size
    disk_size=$(gum input --placeholder "Size (100G)")
    disk_size=${disk_size:-100G}

    local cpu_cores
    cpu_cores=$(gum choose "2" "4" "8" "16" --header "vCPU Count")

    local ram_choice
    ram_choice=$(gum choose "4GB" "8GB" "16GB" "32GB" "Custom" --header "RAM")

    local ram_kb
    if [[ "$ram_choice" == "Custom" ]]; then
        local ram_mib
        ram_mib=$(gum input --placeholder "RAM in MiB")
        ram_kb=$((ram_mib * 1024))
    else
        local num_gb="${ram_choice//GB/}"
        ram_kb=$((num_gb * 1024 * 1024))
    fi

    local chipset
    chipset=$(gum choose "q35" "i440fx" --header "Chipset")

    local xml_file="/tmp/${vm_name}.xml"
    local disk_path="/var/lib/libvirt/images/${vm_name}.qcow2"

    curl -fsSL https://raw.githubusercontent.com/OhShabuShabu/dots/refs/heads/main/vmpreset.xml -o "$xml_file"

    sed -i "s,<name>win10</name>,<name>$vm_name</name>,g" "$xml_file"
    sed -i "s,<memory unit=\"KiB\">.*</memory>,<memory unit=\"KiB\">$ram_kb</memory>,g" "$xml_file"
    sed -i "s,<currentMemory unit=\"KiB\">.*</currentMemory>,<currentMemory unit=\"KiB\">$ram_kb</currentMemory>,g" "$xml_file"
    sed -i "s,<vcpu placement=\"static\">.*</vcpu>,<vcpu placement=\"static\">$cpu_cores</vcpu>,g" "$xml_file"
    sed -i "s,/var/lib/libvirt/images/win10.qcow2,$disk_path,g" "$xml_file"
    sed -i "s,/home/user/Documents/Iso/win10.iso,$SELECTED_ISO_PATH,g" "$xml_file"
    sed -i "s,/home/user/,$HOME/,g" "$xml_file"

    if [[ "$SELECTED_OS_NAME" != *"Windows 10"* ]]; then
        local match_line
        match_line=$(grep -n "virtio-win.iso" "$xml_file" | cut -d: -f1 || true)
        if [[ -n "$match_line" ]]; then
            local start=$((match_line - 2))
            local end=$((match_line + 5))
            sed -i "${start},${end}d" "$xml_file"
        fi
    fi

    sed -i '/<uuid>/d; /<mac address=/d; /<topology/d' "$xml_file"
    [[ "$chipset" == "i440fx" ]] && sed -i "s|machine=\"pc-q35-10.2\"|machine=\"pc\"|g" "$xml_file"

    if [ ! -f "$disk_path" ]; then
        sudo qemu-img create -f qcow2 "$disk_path" "$disk_size" >/dev/null
        sudo chown libvirt-qemu:kvm "$disk_path" 2>/dev/null || true
        sudo chmod 660 "$disk_path"
    fi

    if virsh define "$xml_file" >/dev/null; then
        log "VM '$vm_name' defined."
        rm -f "$xml_file"
        gum confirm "Start VM?" && virsh start "$vm_name"
    fi
}

# --- Main Execution ---
install_gum
if ! curl -fsSL "$TUI_URL" -o /tmp/tui-engine.sh; then
    echo "Error: Could not download TUI engine."
    exit 1
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
log "Done. A reboot is highly recommended to apply group and IOMMU changes."
