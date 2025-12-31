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

die(){ echo "ERROR: $*" >&2; exit 1; }

[[ $EUID -eq 0 ]] || die "Run in Arch ISO as root"
[[ -d /sys/firmware/efi ]] || die "UEFI required"

part() {
  [[ "$1" =~ [0-9]$ ]] && echo "$1p$2" || echo "$1$2"
}

umount -R /mnt 2>/dev/null || true

echo "=== VMware Arch + Hyprland Installer ==="
lsblk -dn -o NAME,SIZE,MODEL

read -rp "Disk to install (e.g. sda): " DISK
DISK="/dev/$DISK"
[[ -b "$DISK" ]] || die "Invalid disk"

read -rp "Type YES to wipe $DISK: " ok
[[ "$ok" == "YES" ]] || exit 1

timedatectl set-ntp true || true

# ===== Partition =====
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

# ===== Install packages =====
pacstrap -K /mnt \
  base linux linux-firmware \
  grub efibootmgr \
  networkmanager sudo \
  hyprland xorg-xwayland \
  xdg-desktop-portal xdg-desktop-portal-hyprland \
  foot open-vm-tools \
  noto-fonts

genfstab -U /mnt >> /mnt/etc/fstab

# ===== Chroot =====
arch-chroot /mnt bash <<'CHROOT'
ln -sf /usr/share/zoneinfo/America/Los_Angeles /etc/localtime
hwclock --systohc

sed -i 's/^#en_US.UTF-8 UTF-8/en_US.UTF-8 UTF-8/' /etc/locale.gen
locale-gen
echo LANG=en_US.UTF-8 > /etc/locale.conf

echo arch-hypr-vm > /etc/hostname

echo root:root | chpasswd
useradd -m -G wheel -s /bin/bash rui
echo rui:123456 | chpasswd
sed -i 's/^# %wheel ALL=(ALL:ALL) ALL/%wheel ALL=(ALL:ALL) ALL/' /etc/sudoers

systemctl enable NetworkManager
systemctl enable vmtoolsd

# autologin tty1
mkdir -p /etc/systemd/system/getty@tty1.service.d
cat > /etc/systemd/system/getty@tty1.service.d/override.conf <<EOF
[Service]
ExecStart=
ExecStart=-/usr/bin/agetty --autologin rui --noclear %I \$TERM
EOF

# Hyprland config
mkdir -p /home/rui/.config/hypr
cat > /home/rui/.config/hypr/hyprland.conf <<'EOF'
$mod = SUPER
bind = $mod, RETURN, exec, foot
bind = $mod, Q, killactive
bind = $mod, M, exit
misc { disable_hyprland_logo = true }
EOF
chown -R rui:rui /home/rui

# auto start Hyprland
cat > /home/rui/.bash_profile <<'EOF'
if [[ -z "$WAYLAND_DISPLAY" && "$(tty)" == "/dev/tty1" ]]; then
  exec Hyprland
fi
EOF
chown rui:rui /home/rui/.bash_profile

grub-install --target=x86_64-efi --efi-directory=/boot/efi --bootloader-id=ARCH
grub-mkconfig -o /boot/grub/grub.cfg
CHROOT

umount -R /mnt
echo "DONE. Disconnect ISO and reboot."
reboot
