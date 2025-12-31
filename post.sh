#!/usr/bin/env bash
set -eo pipefail

# ===== Basic config =====
HOSTNAME="arch-hypr-vm"
USERNAME="rui"
USERPW="123456"
ROOTPW="root"

TZ="America/Los_Angeles"
LOCALE="en_US.UTF-8"
KEYMAP="us"

ESP_SIZE="512MiB"
# ========================

die(){ echo "ERROR: $*" >&2; exit 1; }

[[ $EUID -eq 0 ]] || die "Run in Arch ISO as root"
[[ -d /sys/firmware/efi ]] || die "UEFI required"

part() {
  [[ "$1" =~ [0-9]$ ]] && echo "$1p$2" || echo "$1$2"
}

umount -R /mnt 2>/dev/null || true
swapoff -a 2>/dev/null || true

echo "=== VMware Arch + Hyprland Installer (auto start Hyprland) ==="
echo "Disks:"
lsblk -dn -o NAME,SIZE,MODEL

read -rp "Disk to install (e.g. sda): " d
DISK="/dev/$d"
[[ -b "$DISK" ]] || die "Invalid disk: $DISK"

read -rp "Type YES to wipe $DISK: " ok
[[ "$ok" == "YES" ]] || die "Cancelled"

timedatectl set-ntp true || true

# ===== Partition (EFI + ROOT) =====
sgdisk --zap-all "$DISK"
sgdisk -o "$DISK"
sgdisk -n 1:0:+${ESP_SIZE} -t 1:ef00 "$DISK"
sgdisk -n 2:0:0 -t 2:8300 "$DISK"

ESP=$(part "$DISK" 1)
ROOT=$(part "$DISK" 2)

mkfs.fat -F32 "$ESP"
mkfs.ext4 -F "$ROOT"

mount "$ROOT" /mnt
mkdir -p /mnt/boot/efi
mount "$ESP" /mnt/boot/efi

# ---- Pre-create vconsole.conf BEFORE pacstrap (silence mkinitcpio warning) ----
mkdir -p /mnt/etc
cat > /mnt/etc/vconsole.conf <<EOF
KEYMAP=${KEYMAP}
EOF

# ===== Install packages =====
pacstrap -K /mnt \
  base linux linux-firmware \
  grub efibootmgr \
  networkmanager sudo \
  hyprland xorg-xwayland \
  xdg-desktop-portal xdg-desktop-portal-hyprland xdg-desktop-portal-gtk \
  qt5-wayland qt6-wayland \
  foot open-vm-tools \
  noto-fonts noto-fonts-emoji

genfstab -U /mnt >> /mnt/etc/fstab

# ===== Chroot =====
arch-chroot /mnt bash <<CHROOT
set -e

ln -sf /usr/share/zoneinfo/${TZ} /etc/localtime
hwclock --systohc

sed -i 's/^#en_US.UTF-8 UTF-8/en_US.UTF-8 UTF-8/' /etc/locale.gen || true
locale-gen
echo LANG=${LOCALE} > /etc/locale.conf

echo "${HOSTNAME}" > /etc/hostname

echo "root:${ROOTPW}" | chpasswd
useradd -m -G wheel -s /bin/bash "${USERNAME}"
echo "${USERNAME}:${USERPW}" | chpasswd
sed -i 's/^# %wheel ALL=(ALL:ALL) ALL/%wheel ALL=(ALL:ALL) ALL/' /etc/sudoers

systemctl enable NetworkManager
systemctl enable vmtoolsd || true

# autologin tty1
mkdir -p /etc/systemd/system/getty@tty1.service.d
cat > /etc/systemd/system/getty@tty1.service.d/override.conf <<EOF
[Service]
ExecStart=
ExecStart=-/usr/bin/agetty --autologin ${USERNAME} --noclear %I \\$TERM
EOF

# Hyprland config (IMPORTANT: quoted heredoc to avoid \$mod expansion)
mkdir -p /home/${USERNAME}/.config/hypr
cat > /home/${USERNAME}/.config/hypr/hyprland.conf <<'EOF'
$mod = SUPER
bind = $mod, RETURN, exec, foot
bind = $mod, Q, killactive
bind = $mod, M, exit
misc { disable_hyprland_logo = true }
EOF
chown -R ${USERNAME}:${USERNAME} /home/${USERNAME}/.config

# auto start Hyprland on tty1
cat > /home/${USERNAME}/.bash_profile <<'EOF'
if [[ -z "$WAYLAND_DISPLAY" && "$(tty)" == "/dev/tty1" ]]; then
  exec Hyprland
fi
EOF
chown ${USERNAME}:${USERNAME} /home/${USERNAME}/.bash_profile

# GRUB UEFI
grub-install --target=x86_64-efi --efi-directory=/boot/efi --bootloader-id=ARCH
grub-mkconfig -o /boot/grub/grub.cfg

# VMware/UEFI fallback
mkdir -p /boot/efi/EFI/BOOT
if [[ -f /boot/efi/EFI/ARCH/grubx64.efi ]]; then
  cp -f /boot/efi/EFI/ARCH/grubx64.efi /boot/efi/EFI/BOOT/BOOTX64.EFI
fi
CHROOT

umount -R /mnt
echo "DONE. IMPORTANT: Disconnect ISO in VMware before next boot."
reboot
