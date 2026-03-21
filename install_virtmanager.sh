#!/bin/bash

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
  test12312
)

for pkg in "${packages[@]}"; do
  if pacman -Qi "$pkg" &> /dev/null; then
    echo "[✓] $pkg is already installed"
  else
    echo "[✗] $pkg is NOT installed. Installing..."
    yay -S --noconfirm "$pkg"
  fi
done


sudo systemctl enable --now libvirtd


echo "Done."
