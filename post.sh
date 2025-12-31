#!/usr/bin/env bash
set -eo pipefail
# ===== Fixed config =====
DISK="/dev/sda" # DEFAULT DISK - VMware ONLY!
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
[[ -b "$DISK" ]] || die "Disk not found: $DISK"
part() { [[ "$1" =~ [0-9]$ ]] && echo "$1p$2" || echo "$1$2"; }
umount -R /mnt 2>/dev/null || true
swapoff -a 2>/dev/null || true
echo "=== VMware Arch + Hyprland Installer (2025 Fixed) ==="
echo "Using disk: $DISK (NO CONFIRMATION, NO SWAP)"
echo "确保 VMware 已开启 3D 加速！"
sleep 3
timedatectl set-ntp true || true
# ===== Partition =====
sgdisk --zap-all "$DISK"
sgdisk -o "$DISK"
sgdisk -n 1:0:+${ESP_SIZE} -t 1:ef00 -c 1:"EFI" "$DISK"
sgdisk -n 2:0:0 -t 2:8300 -c 2:"ROOT" "$DISK"
ESP=$(part "$DISK" 1)
ROOT=$(part "$DISK" 2)
mkfs.fat -F32 "$ESP"
mkfs.ext4 -F "$ROOT"
mount "$ROOT" /mnt
mkdir -p /mnt/boot/efi
mount "$ESP" /mnt/boot/efi
mkdir -p /mnt/etc
cat > /mnt/etc/vconsole.conf <<EOF
KEYMAP=${KEYMAP}
EOF
# ===== Install packages (添加 mesa 解决 VMware 图形问题) =====
pacstrap -K /mnt \
  base linux linux-firmware mesa \
  grub efibootmgr \
  networkmanager sudo \
  hyprland xorg-xwayland \
  xdg-desktop-portal xdg-desktop-portal-hyprland xdg-desktop-portal-gtk \
  qt5-wayland qt6-wayland \
  foot open-vm-tools \
  noto-fonts noto-fonts-emoji \
  polkit-gnome waybar wofi mako
genfstab -U /mnt >> /mnt/etc/fstab
# ===== Chroot =====
arch-chroot /mnt bash <<CHROOT
set -e
ln -sf /usr/share/zoneinfo/${TZ} /etc/localtime
hwclock --systohc
sed -i 's/^#en_US.UTF-8 UTF-8/en_US.UTF-8 UTF-8/' /etc/locale.gen
locale-gen
echo LANG=${LOCALE} > /etc/locale.conf
echo "${HOSTNAME}" > /etc/hostname
echo "root:${ROOTPW}" | chpasswd
useradd -m -G wheel -s /bin/bash "${USERNAME}"
echo "${USERNAME}:${USERPW}" | chpasswd
sed -i 's/^# %wheel ALL=(ALL:ALL) ALL/%wheel ALL=(ALL:ALL) ALL/' /etc/sudoers
systemctl enable NetworkManager
systemctl enable vmtoolsd
# autologin tty1
mkdir -p /etc/systemd/system/getty@tty1.service.d
cat > /etc/systemd/system/getty@tty1.service.d/override.conf <<EOF
[Service]
ExecStart=
ExecStart=-/usr/bin/agetty --autologin ${USERNAME} --noclear %I \\$TERM
EOF
# Hyprland config + VMware 专用环境变量（核心修复）
mkdir -p /home/${USERNAME}/.config/hypr
cat > /home/${USERNAME}/.config/hypr/hyprland.conf <<'EOF'
# ===== VMware 专用环境变量（解决启动黑屏/崩溃）=====
env = WLR_RENDERER_ALLOW_SOFTWARE,1
env = WLR_NO_HARDWARE_CURSORS,1

# ===== 基础配置 =====
\$mod = SUPER

monitor=,preferred,auto,1

input {
    kb_layout = us
    follow_mouse = 1
    sensitivity = 0
}

general {
    gaps_in = 5
    gaps_out = 10
    border_size = 2
    col.active_border = rgba(33ccffee)
    col.inactive_border = rgba(595959aa)
}

decoration {
    rounding = 10
    blur { enabled = true; size = 3; passes = 1; }
    drop_shadow = yes
}

animations { enabled = yes }

misc { disable_hyprland_logo = true }

# ===== 快捷键 =====
bind = \$mod, RETURN, exec, foot
bind = \$mod, Q, killactive
bind = \$mod, M, exit
bind = \$mod, R, exec, wofi --show drun
bind = \$mod, V, togglefloating

# ===== 启动程序 =====
exec-once = waybar
exec-once = mako
exec-once = /usr/lib/polkit-gnome/polkit-gnome-authentication-agent-1
EOF

# auto start Hyprland + 调试日志
cat > /home/${USERNAME}/.bash_profile <<'EOF'
if [[ -z "$WAYLAND_DISPLAY" && "$(tty)" == "/dev/tty1" ]]; then
    echo "启动 Hyprland (VMware 模式)..." >> /tmp/hyprland-start.log
    exec Hyprland &>> /tmp/hyprland.log
fi
EOF

chown -R ${USERNAME}:${USERNAME} /home/${USERNAME}/.config /home/${USERNAME}/.bash_profile
chmod +x /home/${USERNAME}/.bash_profile

# GRUB UEFI + VMware fallback
grub-install --target=x86_64-efi --efi-directory=/boot/efi --bootloader-id=ARCH
grub-mkconfig -o /boot/grub/grub.cfg
mkdir -p /boot/efi/EFI/BOOT
cp -f /boot/efi/EFI/ARCH/grubx64.efi /boot/efi/EFI/BOOT/BOOTX64.EFI 2>/dev/null || true
CHROOT
umount -R /mnt
echo "安装完成！请在 VMware 中移除 ISO 并重启。"
echo "如果仍无法进入，切换到 tty2 (Ctrl+Alt+F2) 查看："
echo "   cat /tmp/hyprland.log"
echo "   cat /tmp/hyprland-start.log"
reboot
