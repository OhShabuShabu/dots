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
  packages=(
    qemu-full 
    virt-manager
    virt-viewer
    dnsmasq
    vde2
    bridge-utils
    openbsd-netcat 
    dmidecode
    libvirt
  )

  for pkg in "${packages[@]}"; do
    if pacman -Qi "$pkg" &> /dev/null; then
      echo -e "${GREEN}[✓] $pkg is already installed${RESET}"
    else
      echo -e "${YELLOW}[→] Installing $pkg...${RESET}"
      yay -S --needed --noconfirm "$pkg"
    fi
  done
}

enable_service() {
  echo -e "${YELLOW}[→] Enabling libvirtd service...${RESET}"
  sudo systemctl enable --now libvirtd
}

setting_users() {
  groups=(
    libvirt
    libvirt-qemu
    kvm
    input
    disk
  )

  for grp in "${groups[@]}"; do
    sudo usermod -aG "$grp" "$USER"
    echo -e "${GREEN}[✓] $USER added to $grp${RESET}"
  done
}

# ---- RUN EVERYTHING ----
check_yay
install_required
enable_service
setting_users

echo -e "${GREEN}Done. You may need to log out and back in for group changes.${RESET}"
