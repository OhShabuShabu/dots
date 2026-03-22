#!/bin/bash
set -euo pipefail

GREEN="\e[32m"
YELLOW="\e[33m"
BLUE="\e[34m"
RESET="\e[0m"

log() { echo -e "${GREEN}[✓] $1${RESET}"; }
warn() { echo -e "${YELLOW}[→] $1${RESET}"; }
info() { echo -e "${BLUE}[i] $1${RESET}"; }

check_yay() {
    log "Checking for AUR helper..."
    if ! pacman -Qi yay &> /dev/null; then
        warn "yay not found. Installing dependencies and cloning yay..."
        sudo pacman -S --needed --noconfirm base-devel git
        local tmpdir=$(mktemp -d)
        git clone https://aur.archlinux.org/yay.git "$tmpdir/yay"
        pushd "$tmpdir/yay" > /dev/null
        makepkg -si --noconfirm
        popd > /dev/null
        rm -rf "$tmpdir"
        log "yay installed successfully."
    else
        log "yay is already installed."
    fi
}

install_required() {
    log "Starting package installation..."
    local packages=(
        qemu-full qemu-emulators-full virt-manager virt-viewer
        dnsmasq vde2 bridge-utils openbsd-netcat libvirt
        swtpm ovmf ebtables iptables-nft wget
    )
    for pkg in "${packages[@]}"; do
        if ! pacman -Qi "$pkg" &> /dev/null; then
            warn "Installing $pkg..."
            yay -S --needed --noconfirm "$pkg"
        else
            log "$pkg is already present."
        fi
    done
}

enable_services() {
    log "Configuring virtualization services..."
    sudo systemctl enable --now libvirtd

    log "Activating default network bridge..."
    sudo virsh net-start default 2>/dev/null || warn "Default network already started or unavailable."
    sudo virsh net-autostart default 2>/dev/null || true

    log "Updating user groups for $USER..."
    local groups=(libvirt libvirt-qemu kvm input disk)
    for grp in "${groups[@]}"; do
        sudo usermod -aG "$grp" "$USER"
    done
}

setup_firewall(){
    log "Checking firewall configurations..."
    if pacman -Qi firewalld &> /dev/null; then
        warn "Configuring firewalld for virbr0..."
        sudo firewall-cmd --permanent --zone=libvirt --add-interface=virbr0 || true
        sudo firewall-cmd --reload
    fi

    if pacman -Qi ufw &> /dev/null; then
        warn "Configuring UFW for virbr0..."
        sudo ufw allow in on virbr0
        sudo ufw allow out on virbr0
        sudo sed -i 's/^#net\/ipv4\/ip_forward=1/net\/ipv4\/ip_forward=1/' /etc/ufw/sysctl.conf
        log "IP forwarding enabled in UFW."
    fi
}

update_grub_iommu(){
    log "Starting IOMMU configuration..."
    local param=""
    read -p "Are you on Intel? (y/n): " is_intel

    [[ "$is_intel" =~ ^[Yy]$ ]] && param="intel_iommu=on" || param="amd_iommu=on"

    if ! grep -q "$param" /etc/default/grub; then
        warn "Backing up GRUB and applying $param..."
        sudo cp /etc/default/grub /etc/default/grub.bak
        sudo sed -i "/GRUB_CMDLINE_LINUX_DEFAULT=/ s/\"$/ $param\"/" /etc/default/grub

        local grub_path="/boot/grub/grub.cfg"
        [ -f /boot/efi/EFI/arch/grub.cfg ] && grub_path="/boot/efi/EFI/arch/grub.cfg"

        log "Regenerating GRUB config at $grub_path..."
        sudo grub-mkconfig -o "$grub_path"
        log "IOMMU parameter applied."
    else
        log "IOMMU parameter ($param) is already configured."
    fi
}

manage_isos() {
    local iso_dir="$HOME/Documents/Iso"
    local win_url="https://trashbytes.net/dl/4PTqqKt6mJB_wXE4cTujQS9rjIVQ3gFgH2fn9KJ8Nv7peYgPOL2wCgvB4-RFWQvBaWh113lFOpiUpHDOmMiEYJ6fqiwX48vbaSxyHQDW_widvtWxUqEvs8sOadPuPa79Q0VzPWVqYvohQQD-tCs6VBz3JZieOJ4HKTKGsbbmvCxPX2-F478osl1t_mvspZ7AXY6q7K7risgS?v=1774125334-E%2B%2BwUgVTiRw3aDfQghebvB9oTV52Wi7V%2Bcx%2FjATF%2FIo%3D"
    local virtio_url="https://fedorapeople.org/groups/virt/virtio-win/direct-downloads/archive-virtio/virtio-win-0.1.285-1/virtio-win-0.1.285.iso"

    read -p "Would you like to download the Windows 10 and VirtIO ISOs? (y/n): " dl_choice
    if [[ "$dl_choice" =~ ^[Yy]$ ]]; then
        [ ! -d "$iso_dir" ] && mkdir -p "$iso_dir"
        info "Downloading ISOs to $iso_dir..."
        wget -O "$iso_dir/win10.iso" "$win_url"
        wget -O "$iso_dir/virtio-win.iso" "$virtio_url"
        chmod 777 "$iso_dir/win10.iso" "$iso_dir/virtio-win.iso"
    fi
}

deploy_vm_from_xml() {
    read -p "Would you like to create/deploy the Windows VM now? (y/n): " create_choice
    if [[ ! "$create_choice" =~ ^[Yy]$ ]]; then
        info "Skipping VM deployment."
        return
    fi

    read -p "Enter VM Name (default: win10): " vm_name
    vm_name=${vm_name:-win10}
    read -p "Enter Disk Size (default: 100G): " disk_size
    disk_size=${disk_size:-100G}

    echo -e "Choose Chipset:\n1) q35 (Modern PCIe)\n2) i440fx (Legacy PCI)"
    read -p "Selection [1-2]: " chipset_choice

    local xml_file="${vm_name}_temp.xml"
    local disk_path="/var/lib/libvirt/images/${vm_name}.qcow2"

    curl -fsSL https://raw.githubusercontent.com/OhShabuShabu/dots/refs/heads/main/win10.xml -o "$xml_file"
    sed -i "s|<name>win10</name>|<name>$vm_name</name>|g" "$xml_file"
    sed -i "s|/var/lib/libvirt/images/win10.qcow2|$disk_path|g" "$xml_file"
    sed -i '/<uuid>/d' "$xml_file"
    sed -i '/<mac address=/d' "$xml_file"

    if [[ "$chipset_choice" == "2" ]]; then
        log "Applying Legacy i440fx patches..."
        sed -i "s|machine=\"[^\"]*\"|machine=\"pc\"|g" "$xml_file"
        sed -i "s|model=\"pcie-root\"|model=\"pci-root\"|g" "$xml_file"
        sed -i '/<controller type="pci" index="[1-9][0-4]*" model="pcie-root-port">/,/<\/controller>/d' "$xml_file"
        sed -i '/<watchdog model="itco"/d' "$xml_file"
        sed -i '/<address type="pci"/d' "$xml_file"
    else
        log "Applying Modern q35 patches..."
        sed -i "s|machine=\"[^\"]*\"|machine=\"q35\"|g" "$xml_file"
    fi

    if [ ! -f "$disk_path" ]; then
        sudo qemu-img create -f qcow2 "$disk_path" "$disk_size"
        sudo chmod 777 "$disk_path"
        sudo chown libvirt-qemu:kvm "$disk_path"
    fi

    log "Defining VM '$vm_name'..."
    if virsh define "$xml_file"; then
        log "Success!"
        rm "$xml_file"
        read -p "Start now? (y/n): " start_now
        [[ "$start_now" =~ ^[Yy]$ ]] && virsh start "$vm_name"
    else
        warn "Failed to define VM. Check XML for remaining chipset conflicts."
        rm "$xml_file"
    fi
}

# --- Flow ---
check_yay
install_required
enable_services
setup_firewall
update_grub_iommu
manage_isos
deploy_vm_from_xml

log "Setup Complete. REBOOT recommended."
