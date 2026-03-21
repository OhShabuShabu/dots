#!/bin/bash
set -euo pipefail

# Colors
GREEN="\e[32m"
RED="\e[31m"
YELLOW="\e[33m"
RESET="\e[0m"

check_yay() {
  if pacman -Qi yay &> /dev/null; then
    echo -e "${GREEN}[✓] yay is already installed${RESET}"
  else
    echo -e "${RED}[✗] yay is NOT installed. Installing...${RESET}"
    make_yay
  fi
}

make_yay() {
  sudo pacman -S --needed --noconfirm base-devel git
  tmpdir=$(mktemp -d)
  git clone https://aur.archlinux.org/yay.git "$tmpdir/yay"
  pushd "$tmpdir/yay" > /dev/null
  makepkg -si --noconfirm
  popd > /dev/null
  rm -rf "$tmpdir"
}

install_required() {
  packages=(qemu-full qemu-emulators-full virt-manager virt-viewer dnsmasq vde2 bridge-utils openbsd-netcat libvirt)
  for pkg in "${packages[@]}"; do
    if pacman -Qi "$pkg" &> /dev/null; then
      echo -e "${GREEN}[✓] $pkg is already installed${RESET}"
    else
      echo -e "${YELLOW}[→] Installing $pkg...${RESET}"
      yay -S --needed --noconfirm "$pkg"
    fi
  done
}

enable_autostart() {
  echo -e "${YELLOW}[→] Enabling libvirtd service...${RESET}"
  sudo systemctl enable --now libvirtd
  echo -e "${YELLOW}[→] Enabling virtual network...${RESET}"
  sudo virsh net-start default || true
  sudo virsh net-autostart default
}

setting_users() {
  groups=(libvirt libvirt-qemu kvm input disk)
  for grp in "${groups[@]}"; do
    sudo usermod -aG "$grp" "$USER"
    echo -e "${GREEN}[✓] $USER added to $grp${RESET}"
  done
}

config_options() {
  local FILE=$1
  local SETTING=$2
  local LINE=$3

  if grep -Fxq "$SETTING" "$FILE"; then
      echo -e "${GREEN}[✓] $SETTING is already configured in $FILE. Skipping.${RESET}"
  else
      echo -e "${YELLOW}[→] Creating File Backup for $FILE...${RESET}"
      sudo cp "$FILE" "$FILE.bak"
      echo -e "${GREEN}[✓] Applying configuration: Setting line $LINE to $SETTING...${RESET}"
      sudo sed -i "${LINE}c\\$SETTING" "$FILE"
  fi
}

allow_libvirt(){
  if pacman -Qi firewalld &> /dev/null; then
    echo -e "${YELLOW}[→] firewalld is installed.${RESET}"
    sudo firewall-cmd --permanent --new-zone=libvirt || true
    sudo firewall-cmd --reload
  fi

  if pacman -Qi ufw &> /dev/null; then
    echo -e "${YELLOW}[→] ufw is installed. applying firewall rules${RESET}"
    sudo ufw allow in on virbr0
    sudo ufw allow out on virbr0
    config_options "/etc/ufw/sysctl.conf" "net.ipv4.ip_forward=1" 8
  fi
}

download_ios(){
  echo -e "${GREEN}[✓] Downloading Windows 10 ISO...${RESET}"
  curl https://trashbytes.net/dl/4PTqqKt6mJB_wXE4cTujQS9rjIVQ3gFgH2fn9KJ8Nv7peYgPOL2wCgvB4-RFWQvBaWh113lFOpiUpHDOmMiEYJ6fqiwX48vbaSxyHQDW_widvtWxUqEvs8sOadPuPa79Q0VzPWVqYvohQQD-tCs6VBz3JZieOJ4HKTKGsbbmvCxPX2-F478osl1t_mvspZ7AXY6q7K7risgS?v=1774125334-E%2B%2BwUgVTiRw3aDfQghebvB9oTV52Wi7V%2Bcx%2FjATF%2FIo%3D -o /home/$USER/Downloads/win10.iso
  echo -e "${GREEN}[✓] Finished Download for Windows 10 ISO in /home/$USER/Downloads.${RESET}"

  echo -e "${GREEN}[✓] Downloading Virtio Guest-Agent ISO...${RESET}"
  curl https://fedorapeople.org/groups/virt/virtio-win/direct-downloads/archive-virtio/virtio-win-0.1.285-1/virtio-win-0.1.285.iso -o /home/$USER/Downloads/virtio-win.iso
  echo -e "${GREEN}[✓] Finished Download for Virtio Guest-Agent ISO in /home/$USER/Downloads.${RESET}"
}

# ---- RUN EVERYTHING ----
check_yay
install_required
allow_libvirt
enable_autostart
setting_users

read -p "Do you want to Download Windows 10 ISO? (y/n): " confirm </dev/tty

# Check the input
case "$confirm" in
    [yY][eE][sS]|[yY])
        download_ios
        ;;
    [nN][oO]|[nN])
        echo "Operation cancelled."
        ;;
    *)
        echo "Invalid input. Please enter y or n."
        ;;
esac

echo -e "${GREEN}Done. You may need to log out and back in for group changes.${RESET}"
