#!/bin/bash
set -euo pipefail

TUI_URL="https://raw.githubusercontent.com/OhShabuShabu/dots/heads/main/atlas/tui-engine.sh"
if ! curl -fsSL "$TUI_URL" -o /tmp/tui-engine.sh; then
    echo "Error: Could not download TUI engine."
    exit 1
fi
source /tmp/tui-engine.sh

if ! command -v gum &>/dev/null; then
    sudo pacman -S --needed --noconfirm gum
fi
check_deps "wget" "curl"

log() { gum style --foreground 78 " [✓] $1"; }
warn() { gum style --foreground 214 " [!] $1"; }
info() { gum style --foreground 39 " [i] $1"; }

init_sudo() {
    # Added info about sudo privileges as requested
    info "sudo privileges are required."
    sudo -v
    while true; do
        sudo -n true
        sleep 60
        kill -0 "$$" || exit
    done 2>/dev/null &
}

check_yay() {
    if ! pacman -Qi yay &>/dev/null; then
        sudo pacman -S --needed --noconfirm base-devel git
        local tmpdir
        tmpdir=$(mktemp -d)
        git clone https://aur.archlinux.org/yay.git "$tmpdir/yay"
        pushd "$tmpdir/yay" >/dev/null && makepkg -si --noconfirm && popd >/dev/null
        rm -rf "$tmpdir"
    fi
}

install_required() {
    local packages=(qemu-full qemu-emulators-full virt-manager virt-viewer dnsmasq vde2 bridge-utils openbsd-netcat libvirt swtpm ovmf ebtables iptables-nft wget)
    gum spin --spinner dot --title "Installing Stack..." -- yay -S --needed --noconfirm "${packages[@]}"
}

enable_services() {
    sudo systemctl enable --now libvirtd
    sudo virsh net-start default &>/dev/null || true
    sudo virsh net-autostart default &>/dev/null || true
    local groups=(libvirt libvirt-qemu kvm input disk)
    for grp in "${groups[@]}"; do sudo usermod -aG "$grp" "$USER"; done
}

setup_firewall() {
    local fw_found=false

    if pacman -Qi firewalld &>/dev/null; then
        fw_found=true
        gum spin --spinner dot --title "Configuring Firewalld..." -- bash -c '
            sudo firewall-cmd --permanent --zone=libvirt --add-interface=virbr0 &>/dev/null || true
            sudo firewall-cmd --reload &>/dev/null
        '
        log "Firewalld: Virbr0 interface authorized."
    fi

    if pacman -Qi ufw &>/dev/null; then
        fw_found=true
        gum spin --spinner dot --title "Configuring UFW..." -- bash -c '
            sudo ufw allow in on virbr0 &>/dev/null
            sudo ufw allow out on virbr0 &>/dev/null
            sudo sed -i "s/^#net\/ipv4\/ip_forward=1/net\/ipv4\/ip_forward=1/" /etc/ufw/sysctl.conf
        '
        log "UFW: Rules updated and IP forwarding enabled."
    fi
    if [[ "$fw_found" == "false" ]]; then
        info "No active firewall (Firewalld/UFW) detected. Skipping."
    fi
}

update_grub_iommu() {
    if grep -E "intel_iommu=on|amd_iommu=on" /etc/default/grub >/dev/null; then
        log "IOMMU already present in GRUB config. Skipping."
        return
    fi

    local cpu_type
    cpu_type=$(gum choose "Intel" "AMD" --header "CPU Architecture")
    local param="amd_iommu=on"
    [[ "$cpu_type" == "Intel" ]] && param="intel_iommu=on"

    sudo sed -i "/GRUB_CMDLINE_LINUX_DEFAULT=/ s/\"$/ $param\"/" /etc/default/grub
    local grub_path="/boot/grub/grub.cfg"
    [ -f /boot/efi/EFI/arch/grub.cfg ] && grub_path="/boot/efi/EFI/arch/grub.cfg"
    sudo grub-mkconfig -o "$grub_path"
    log "IOMMU enabled for $cpu_type."
}

manage_isos() {
    local iso_dir="$HOME/Documents/Iso"
    local win_url="https://trashbytes.net/dl/4PTqqKt6mJB_wXE4cTujQS9rjIVQ3gFgH2fn9KJ8Nv7peYgPOL2wCgvB4-RFWQvBaWh113lFOpiUpHDOmMiEYJ6fqiwX48vbaSxyHQDW_widvtWxUqEvs8sOadPuPa79Q0VzPWVqYvohQQD-tCs6VBz3JZieOJ4HKTKGsbbmvCxPX2-F478osl1t_mvspZ7AXY6q7K7risgS?v=1774125334-E%2B%2BwUgVTiRw3aDfQghebvB9oTV52Wi7V%2Bcx%2FjATF%2FIo%3D"
    local virtio_url="https://fedorapeople.org/groups/virt/virtio-win/direct-downloads/archive-virtio/virtio-win-0.1.285-1/virtio-win-0.1.285.iso"

    # Check if files already exist
    if [[ -f "$iso_dir/win10.iso" && -f "$iso_dir/virtio-win.iso" ]]; then
        log "Windows 10 and VirtIO ISOs already found in $iso_dir. Skipping download."
        return
    fi

    gum format "### ISOs:" "Downloads Windows 10 & VirtIO drivers (7.2GB) to \`$iso_dir\`."
    if gum confirm "Start downloads?"; then
        mkdir -p "$iso_dir"
        [[ ! -f "$iso_dir/win10.iso" ]] && info "Fetching Windows 10..." && wget -q --show-progress -O "$iso_dir/win10.iso" "$win_url"
        [[ ! -f "$iso_dir/virtio-win.iso" ]] && info "Fetching VirtIO Drivers..." && wget -q --show-progress -O "$iso_dir/virtio-win.iso" "$virtio_url"
        chmod 777 "$iso_dir"/*.iso
    fi
}

deploy_vm_from_xml() {
    if ! gum confirm "Deploy VM?"; then return; fi

    local vm_name
    vm_name=$(gum input --placeholder "Name (win10)")
    vm_name=${vm_name:-win10}

    local disk_size
    disk_size=$(gum input --placeholder "Size (100G)")
    disk_size=${disk_size:-100G}

    local cpu_cores
    cpu_cores=$(gum choose "1" "2" "4" "8" "16" --header "vCPU Count")

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

    sed -i "s|<name>win10</name>|<name>$vm_name</name>|g" "$xml_file"
    sed -i "s|<memory unit=\"KiB\">.*</memory>|<memory unit=\"KiB\">$ram_kb</memory>|g" "$xml_file"
    sed -i "s|<currentMemory unit=\"KiB\">.*</currentMemory>|<currentMemory unit=\"KiB\">$ram_kb</currentMemory>|g" "$xml_file"
    sed -i "s|<vcpu placement=\"static\">.*</vcpu>|<vcpu placement=\"static\">$cpu_cores</vcpu>|g" "$xml_file"
    sed -i "s|/var/lib/libvirt/images/win10.qcow2|$disk_path|g" "$xml_file"
    sed -i "s|/home/user/|/home/$USER/|g" "$xml_file"
    sed -i '/<uuid>/d; /<mac address=/d; /<topology/d' "$xml_file"

    [[ "$chipset" == "i440fx" ]] && sed -i "s|machine=\"pc-q35-10.2\"|machine=\"pc\"|g" "$xml_file"

    if [ ! -f "$disk_path" ]; then
        sudo qemu-img create -f qcow2 "$disk_path" "$disk_size" >/dev/null
        sudo chown libvirt-qemu:kvm "$disk_path" && sudo chmod 660 "$disk_path"
    fi

    if virsh define "$xml_file" >/dev/null; then
        log "VM defined."
        rm -f "$xml_file"
        gum confirm "Start VM?" && virsh start "$vm_name"
    fi
}

# --- Execution ---
init_sudo
check_yay
install_required
enable_services
setup_firewall
update_grub_iommu
manage_isos
deploy_vm_from_xml
log "Done. Reboot recommended."
