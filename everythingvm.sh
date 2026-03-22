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
    command -v gum &>/dev/null && return
    if [ "$DISTRO" = "arch" ]; then
        sudo pacman -S --needed --noconfirm gum >/dev/null
    elif [ "$DISTRO" = "fedora" ]; then
        sudo dnf install -y gum >/dev/null
    elif [ "$DISTRO" = "debian" ]; then
        sudo mkdir -p /etc/apt/keyrings
        curl -fsSL https://repo.charm.sh/apt/gpg.key | sudo gpg --dearmor -o /etc/apt/keyrings/charm.gpg
        echo "deb [signed-by=/etc/apt/keyrings/charm.gpg] https://repo.charm.sh/apt/ * *" | sudo tee /etc/apt/sources.list.d/charm.list >/dev/null
        sudo apt update >/dev/null && sudo apt install -y gum >/dev/null
    fi
}

install_gum

log() { gum style --foreground 78 "[OK] $1"; }
info() { gum style --foreground 39 "[INFO] $1"; }

init_sudo() {
    info "Requesting sudo..."
    sudo -v

}

# Helper for distro-specific wget flags
fetch_iso() {
    local url="$1"
    local dest="$2"
    if [ "$DISTRO" = "fedora" ]; then
        wget -q --progress=bar:force -O "$dest" "$url"
    else
        wget -q --show-progress -O "$dest" "$url"
    fi
}

check_yay() {
    if [[ "$DISTRO" == "arch" ]] && ! command -v yay &>/dev/null; then
        gum spin --spinner line --title "Installing yay..." -- bash -c '
            sudo pacman -S --needed --noconfirm base-devel git >/dev/null 2>&1
            tmpdir=$(mktemp -d)
            git clone https://aur.archlinux.org/yay.git "$tmpdir/yay" >/dev/null 2>&1
            pushd "$tmpdir/yay" >/dev/null && makepkg -si --noconfirm >/dev/null 2>&1 && popd >/dev/null
            rm -rf "$tmpdir"
        '
    fi
}

install_required() {
    local status=0

    case "$DISTRO" in
    "arch")
        local pkgs=(qemu-full virt-manager virt-viewer dnsmasq vde2 bridge-utils openbsd-netcat libvirt swtpm ovmf ebtables iptables-nft wget)
        gum spin --spinner line --title "Installing virt stack (Arch)..." -- \
            yay -S --needed --noconfirm "${pkgs[@]}" >/dev/null 2>&1
        status=$?
        ;;
    "fedora")
        gum spin --spinner line --title "Installing virt stack (Fedora)..." -- \
            sudo dnf install -y @virtualization wget >/dev/null 2>&1
        status=$?
        ;;
    "debian")
        local pkgs=(qemu-system-x86 libvirt-daemon-system libvirt-clients virt-manager bridge-utils ovmf swtpm wget)
        # We split apt update and install for better error tracking
        gum spin --spinner line --title "Updating package lists..." -- sudo apt update >/dev/null 2>&1

        gum spin --spinner line --title "Installing virt stack (Debian)..." -- \
            sudo apt install -y "${pkgs[@]}" >/dev/null 2>&1
        status=$?
        ;;
    *)
        gum format "> [!] **Error**: Unsupported distribution: $DISTRO"
        return 1
        ;;
    esac

    # Final Verification
    if [ $status -eq 0 ]; then
        gum style --foreground 212 "✔ Virtualization stack installed successfully!"
    else
        gum style --foreground 196 "✖ Installation failed. Please check your internet connection or package manager."
        return 1
    fi
}

enable_services() {
    gum spin --spinner line --title "Configuring services..." -- bash -c '
        sudo systemctl enable --now libvirtd >/dev/null 2>&1
        sudo virsh net-start default 2>/dev/null || true
        sudo virsh net-autostart default 2>/dev/null || true
        for grp in libvirt libvirt-qemu kvm input disk; do
            sudo usermod -aG "$grp" "$USER" 2>/dev/null || true
        done
    '
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
        gum spin --spinner line --title "Updating GRUB..." -- bash -c "
            sudo sed -i '/GRUB_CMDLINE_LINUX_DEFAULT=/ s/\"$/ $param\"/' $grub
            if [ '$DISTRO' = 'arch' ]; then sudo grub-mkconfig -o /boot/grub/grub.cfg
            elif [ '$DISTRO' = 'fedora' ]; then sudo grub2-mkconfig -o /boot/grub2/grub.cfg
            else command -v update-grub &>/dev/null && sudo update-grub || sudo grub-mkconfig -o /boot/grub/grub.cfg
            fi
        " >/dev/null 2>&1
        log "IOMMU enabled"
    fi
}

declare -A OS_URLS=(
    ["Windows 10 | Standard NT kernel workstation; wide legacy support for proprietary hardware/software binaries."]="https://trashbytes.net/dl/4PTqqKt6mJB_wXE4cTujQS9rjIVQ3gFgH2fn9KJ8Nv7peYgPOL2wCgvB4-RFWQvBaWh113lFOpiUpHDOmMiEYJ6fqiwX48vbaSxyHQDW_widvtWxUqEvs8sOadPuPa79Q0VzPWVqYvohQQD-tCs6VBz3JZieOJ4HKTKGsbbmvCxPX2-F478osl1t_mvspZ7AXY6q7K7risgS?v=1774125334-E%2B%2BwUgVTiRw3aDfQghebvB9oTV52Wi7V%2Bcx%2FjATF%2FIo%3D"
    ["Arch Linux | DIY rolling-release; utilizes Pacman and Systemd; minimal base for maximum user customization."]="https://geo.mirror.pkgbuild.com/iso/latest/archlinux-x86_64.iso"
    ["Ubuntu 24.04 | Debian-based 5-year LTS; standardized GNOME env; highly optimized for cloud and enterprise dev."]="https://releases.ubuntu.com/24.04/ubuntu-24.04.4-desktop-amd64.iso"
    ["Fedora 41 | Red Hat upstream; features DNF5 and vanilla GNOME; testbed for latest Linux kernel technologies."]="https://download.fedoraproject.org/pub/fedora/linux/releases/41/Workstation/x86_64/iso/Fedora-Workstation-Live-x86_64-41-1.4.iso"
    ["Linux Mint 22.3 | Ubuntu-stable base with Cinnamon desktop; prioritizes UI familiarity for Windows migrants."]="https://ftp.fau.de/mint/iso/stable/22.3/linuxmint-22.3-cinnamon-64bit.iso"
    ["Debian 12.13 | 'The Universal OS'; focuses on extreme stability and FOSS; utilizes the APT package manager."]="https://ftp.thm.de/debian-cd/debian-12.13.0-amd64-DVD-1.iso"
    ["Manjaro 26.0 | User-friendly Arch derivative; hardware detection scripts and pre-configured XFCE environment."]="https://download.manjaro.org/xfce/26.0.3/manjaro-xfce-26.0.3-260228-linux618.iso"
    ["Kali Linux 2026.1 | Specialized Debian-base for InfoSec; comes pre-loaded with hundreds of penetration tools."]="https://ftp.riken.jp/Linux/kali-images/kali-weekly/kali-linux-2026-W12-installer-amd64.iso"
)
VIRTIO_URL="https://fedorapeople.org/groups/virt/virtio-win/direct-downloads/archive-virtio/virtio-win-0.1.285-1/virtio-win-0.1.285.iso"

manage_isos() {
    local iso_dir="$HOME/Documents/Iso"
    mkdir -p "$iso_dir"

    local SELECTED_OS=$(gum choose "${!OS_URLS[@]}" --height 10 --header "Select Guest OS")
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

    sudo chmod 777 "$iso_dir"/*.iso
    export SELECTED_ISO_PATH="$os_path"
    export SELECTED_OS_NAME="$SELECTED_OS"
}

deploy_vm_from_xml() {
    gum confirm "Deploy ${SELECTED_OS_NAME% | *}?" || return
    local default_name=$(echo "${SELECTED_OS_NAME% | *}" | tr ' ' '_' | tr '[:upper:]' '[:lower:]')
    local vm_name=$(gum input --placeholder "VM Name" --value "$default_name")
    local xml_file="/tmp/${vm_name}.xml"
    local disk_path="/var/lib/libvirt/images/${vm_name}.qcow2"

    gum spin --spinner line --title "Fetching XML preset..." -- curl -fsSL https://raw.githubusercontent.com/OhShabuShabu/dots/refs/heads/main/vmpreset.xml -o "$xml_file"

    sed -i -e '/<uuid>.*<\/uuid>/d' \
        -e "s/machine='[^']*'/machine='q35'/g" \
        -e "s,<name>win10</name>,<name>$vm_name</name>,g" \
        -e "s,/var/lib/libvirt/images/win10.qcow2,$disk_path,g" \
        -e "s,/home/user/Documents/Iso/win10.iso,$SELECTED_ISO_PATH,g" \
        -e "s,/home/user/,$HOME/,g" "$xml_file"

    if [[ "$SELECTED_OS_NAME" != *"Windows"* ]]; then
        local match_line=$(grep -n "virtio-win.iso" "$xml_file" | cut -d: -f1 || true)
        [[ -n "$match_line" ]] && sed -i "$((match_line - 2)),$((match_line + 5))d" "$xml_file"
    fi

    if [ ! -f "$disk_path" ]; then
        gum spin --spinner line --title "Allocating 100G disk..." -- sudo qemu-img create -f qcow2 "$disk_path" 100G >/dev/null
        sudo chown libvirt-qemu:kvm "$disk_path" 2>/dev/null || true
    fi

    if virsh define "$xml_file" >/dev/null 2>&1; then
        rm -f "$xml_file"
        log "VM defined"
        if gum confirm "Start $vm_name now?"; then
            virsh start "$vm_name" >/dev/null 2>&1
            log "VM started"
        fi
    fi
}

if ! curl -fsSL "$TUI_URL" -o /tmp/tui-engine.sh; then exit 1; fi
source /tmp/tui-engine.sh

init_sudo
log "DONE. init sudo"
check_yay
log "DONE. check yay"
install_required
log "DONE. install_required"
enable_services

log "DONE. enable_services"
setup_firewall

log "DONE. setup_firewall"
update_grub_iommu
manage_isos
deploy_vm_from_xml

gum style --border normal --margin "1" --padding "1" --border-foreground 78 "Atlas Setup Complete."
