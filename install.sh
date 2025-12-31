#!/usr/bin/env bash
set -euo pipefail

# =========================================================
# Arch Linux 自动重装脚本（UEFI + systemd-boot）
# - 固定磁盘：/dev/sda
# - 安装 Hyprland + SDDM + 中文输入法 + Chrome + 微信
# - 使用 systemd-boot，确保 VMware UEFI 可启动
# - 重启后直接进入图形登录界面
#
# ⚠️ 会无条件清空 /dev/sda，仅用于虚拟机
# =========================================================

DISK="/dev/sda"
HOSTNAME="arch-hypr"
USERNAME="rui"
TZ="America/Los_Angeles"
LOCALE="zh_CN.UTF-8"
KEYMAP="us"
ROOTPW="root"
USERPW="123456"

log(){ echo -e "\n\033[1;32m==> $*\033[0m"; }
die(){ echo -e "\n\033[1;31m[ERR] $*\033[0m"; exit 1; }

[[ $EUID -eq 0 ]] || die "请在 Arch ISO (archiso) 的 root 下运行"
[[ -d /sys/firmware/efi ]] || die "当前不是 UEFI 启动，请在 VMware 中启用 UEFI"

log "1) 清盘并分区（EFI + ROOT）"
sgdisk --zap-all "$DISK"
sgdisk -n 1:0:+512M -t 1:ef00 -c 1:"EFI" "$DISK"
sgdisk -n 2:0:0     -t 2:8300 -c 2:"ROOT" "$DISK"
partprobe "$DISK"

mkfs.fat -F32 "${DISK}1"
mkfs.ext4 -F "${DISK}2"

mount "${DISK}2" /mnt
mkdir -p /mnt/boot
mount "${DISK}1" /mnt/boot

log "2) 安装基础系统"
pacstrap -K /mnt \
  base linux linux-firmware \
  sudo git curl vim nano \
  networkmanager \
  pipewire pipewire-pulse wireplumber \
  flatpak \
  noto-fonts noto-fonts-cjk noto-fonts-emoji \
  xorg-xwayland

genfstab -U /mnt >> /mnt/etc/fstab

log "3) 进入 chroot 配置系统"
arch-chroot /mnt /bin/bash <<CHROOT

set -e

ln -sf /usr/share/zoneinfo/${TZ} /etc/localtime
hwclock --systohc

sed -i 's/^#${LOCALE}/${LOCALE}/' /etc/locale.gen
locale-gen
echo "LANG=${LOCALE}" > /etc/locale.conf
echo "${HOSTNAME}" > /etc/hostname

cat > /etc/hosts <<EOF
127.0.0.1 localhost
::1       localhost
127.0.1.1 ${HOSTNAME}
EOF

useradd -m -G wheel -s /bin/bash ${USERNAME}
echo "root:${ROOTPW}" | chpasswd
echo "${USERNAME}:${USERPW}" | chpasswd
sed -i 's/^# %wheel ALL=(ALL:ALL) ALL/%wheel ALL=(ALL:ALL) ALL/' /etc/sudoers

systemctl enable NetworkManager

log "4) 安装 systemd-boot（UEFI 原生）"
bootctl install

ROOT_UUID=\$(blkid -s UUID -o value ${DISK}2)

cat > /boot/loader/loader.conf <<EOF
default arch
timeout 3
editor no
EOF

cat > /boot/loader/entries/arch.conf <<EOF
title Arch Linux
linux /vmlinuz-linux
initrd /initramfs-linux.img
options root=UUID=\${ROOT_UUID} rw
EOF

log "5) 安装桌面：Hyprland + SDDM"
pacman -S --noconfirm \
  hyprland \
  sddm \
  waybar wofi kitty \
  thunar \
  fcitx5 fcitx5-rime \
  xdg-desktop-portal xdg-desktop-portal-hyprland \
  qt5-wayland qt6-wayland

mkdir -p /usr/share/wayland-sessions
cat > /usr/share/wayland-sessions/hyprland.desktop <<EOF
[Desktop Entry]
Name=Hyprland
Exec=Hyprland
Type=Application
EOF

systemctl enable sddm
systemctl set-default graphical.target

log "6) 安装微信 & Chrome"
flatpak remote-add --if-not-exists flathub https://flathub.org/repo/flathub.flatpakrepo
flatpak install -y flathub com.tencent.WeChat

CHROOT

log "7) 安装完成，请关机并断开 ISO"
umount -R /mnt
echo
echo "=================================================="
echo "安装完成！"
echo "请在 VMware 中："
echo "1) 关闭虚拟机"
echo "2) 断开 Arch ISO"
echo "3) 再次开机"
echo "你将直接进入 SDDM 图形登录界面"
echo "=================================================="
