#!/usr/bin/env bash
set -euo pipefail

# =========================================================
# ArchISO 全自动重装脚本：VMware + UEFI + GRUB（固定 /dev/sda，无需 YES）
# - 自动分区/格式化/安装 Arch
# - GRUB UEFI 安装到 /boot/efi + 生成 grub.cfg
# - 关键兜底：复制 grubx64.efi 到 /EFI/BOOT/BOOTX64.EFI（VMware UEFI 常用 fallback）
# - 安装 Hyprland + SDDM（重启进入图形登录界面）
# - 中文输入法（fcitx5+rime）+ Chrome(AUR yay) + 微信(Flatpak)
# - 修复你截图中的两个问题：
#   1) mkinitcpio: /etc/vconsole.conf not found -> 创建该文件
#   2) chroot: log command not found -> 在 chroot 内定义 log()
#
# ⚠️ 会无条件清空 /dev/sda（整盘重装），仅用于虚拟机测试环境
# =========================================================

# ===== 固定目标盘 =====
DISK="/dev/sda"

# ===== 参数（需要可自行改）=====
HOSTNAME="arch-hypr"
USERNAME="rui"
TZ="America/Los_Angeles"
LOCALE="zh_CN.UTF-8"
KEYMAP="us"

ROOTPW="root"
USERPW="123456"

ESP_SIZE="512MiB"
SWAP_SIZE="0GiB"   # 例如 "2GiB"；0GiB 表示不建 swap
# ==============================

LOG_FILE="/root/install.log"
exec > >(tee -a "$LOG_FILE") 2>&1

log(){ printf "\n\033[1;32m==> %s\033[0m\n" "$*"; }
warn(){ printf "\n\033[1;33m[!] %s\033[0m\n" "$*"; }
die(){ printf "\n\033[1;31m[ERR] %s\033[0m\n" "$*"; exit 1; }
need(){ command -v "$1" >/dev/null 2>&1 || die "缺少命令: $1"; }

cleanup(){
  set +e
  swapoff -a >/dev/null 2>&1 || true
  umount -R /mnt >/dev/null 2>&1 || true
}
trap cleanup EXIT ERR

[[ $EUID -eq 0 ]] || die "请在 Arch ISO（archiso）环境的 root 下运行。"
[[ -b "$DISK" ]] || die "找不到块设备：$DISK"
[[ -d /sys/firmware/efi ]] || die "当前不是 UEFI 启动。请在 VMware 里启用 UEFI 再启动 ISO。"

need lsblk
need sgdisk
need mkfs.fat
need mkfs.ext4
need mount
need umount
need pacstrap
need genfstab
need arch-chroot
need timedatectl
need loadkeys
need partprobe
need curl

log "目标磁盘固定为：$DISK"
lsblk "$DISK" || true

warn "即将清空并重装整块磁盘：$DISK（无确认步骤）"
warn "如果这不是你要装的盘，请立刻按 Ctrl+C 终止。"
for i in 5 4 3 2 1; do echo "  $i..."; sleep 1; done

log "1) 时间同步 & 键盘布局"
timedatectl set-ntp true || true
loadkeys "$KEYMAP" || true

log "2) 清理旧挂载/交换（如果有）"
cleanup

log "3) 清空分区表并创建 GPT 分区（EFI + ROOT + 可选 SWAP）"
sgdisk --zap-all "$DISK"
sgdisk -n 1:0:+${ESP_SIZE} -t 1:ef00 -c 1:"EFI" "$DISK"

if [[ "$SWAP_SIZE" != "0GiB" ]]; then
  sgdisk -n 2:0:+${SWAP_SIZE} -t 2:8200 -c 2:"SWAP" "$DISK"
  sgdisk -n 3:0:0 -t 3:8300 -c 3:"ROOT" "$DISK"
  ESP_PART="${DISK}1"
  SWAP_PART="${DISK}2"
  ROOT_PART="${DISK}3"
else
  sgdisk -n 2:0:0 -t 2:8300 -c 2:"ROOT" "$DISK"
  ESP_PART="${DISK}1"
  ROOT_PART="${DISK}2"
  SWAP_PART=""
fi

partprobe "$DISK" || true
sleep 1
lsblk "$DISK"

log "4) 格式化分区"
mkfs.fat -F32 "$ESP_PART"
mkfs.ext4 -F "$ROOT_PART"
if [[ -n "$SWAP_PART" ]]; then
  mkswap "$SWAP_PART"
  swapon "$SWAP_PART"
fi

log "5) 挂载到 /mnt（GRUB UEFI 标准：ESP 挂到 /boot/efi）"
mount "$ROOT_PART" /mnt
mkdir -p /mnt/boot/efi
mount "$ESP_PART" /mnt/boot/efi

log "6) pacstrap 安装基础系统 + 必要组件（含 GRUB+efibootmgr）"
pacstrap -K /mnt \
  base linux linux-firmware \
  grub efibootmgr \
  sudo git curl wget unzip \
  base-devel \
  networkmanager network-manager-applet \
  vim nano \
  pipewire pipewire-alsa pipewire-pulse wireplumber \
  xdg-user-dirs xdg-utils \
  mesa vulkan-icd-loader \
  noto-fonts noto-fonts-cjk noto-fonts-emoji ttf-dejavu \
  flatpak \
  open-vm-tools \
  openssh \
  htop btop ncdu ripgrep fd tmux python jq \
  p7zip unrar \
  gvfs ntfs-3g exfatprogs \
  firefox \
  xorg-xwayland

genfstab -U /mnt >> /mnt/etc/fstab

log "7) chroot 配置系统 + 安装桌面/输入法/应用 + 安装 GRUB(UEFI)"
arch-chroot /mnt /bin/bash -euo pipefail <<CHROOT
# ---- 修复：你截图里的 log command not found ----
log(){ printf "\n==> %s\n" "\$*"; }

log "7.1) 基础配置：时区/语言/主机名"
ln -sf /usr/share/zoneinfo/${TZ} /etc/localtime || true
hwclock --systohc || true

# ---- 修复：你截图里的 mkinitcpio /etc/vconsole.conf not found ----
cat > /etc/vconsole.conf <<EOF
KEYMAP=${KEYMAP}
EOF

sed -i 's/^#\\(${LOCALE} UTF-8\\)/\\1/' /etc/locale.gen || true
sed -i 's/^#\\(en_US.UTF-8 UTF-8\\)/\\1/' /etc/locale.gen || true
locale-gen
echo "LANG=${LOCALE}" > /etc/locale.conf

echo "${HOSTNAME}" > /etc/hostname
cat > /etc/hosts <<EOF
127.0.0.1   localhost
::1         localhost
127.0.1.1   ${HOSTNAME}.localdomain ${HOSTNAME}
EOF

log "7.2) 创建用户 & sudo"
id -u ${USERNAME} >/dev/null 2>&1 || useradd -m -G wheel -s /bin/bash ${USERNAME}
echo "root:${ROOTPW}" | chpasswd
echo "${USERNAME}:${USERPW}" | chpasswd
sed -i 's/^# %wheel ALL=(ALL:ALL) ALL/%wheel ALL=(ALL:ALL) ALL/' /etc/sudoers

log "7.3) 启用服务：NetworkManager / SSH / VMware tools"
systemctl enable NetworkManager
systemctl enable sshd
systemctl enable vmtoolsd || true

log "7.4) 安装 Hyprland + SDDM + 生态补齐"
pacman -S --needed --noconfirm \
  hyprland \
  waybar wofi \
  kitty \
  thunar thunar-archive-plugin file-roller \
  grim slurp wl-clipboard \
  xdg-desktop-portal xdg-desktop-portal-hyprland xdg-desktop-portal-gtk \
  qt5-wayland qt6-wayland \
  brightnessctl playerctl \
  pavucontrol pamixer \
  polkit polkit-gnome \
  cliphist \
  hyprpaper hyprlock hypridle \
  wlogout \
  sddm

# 确保 SDDM 能看到 Hyprland 会话
mkdir -p /usr/share/wayland-sessions
cat > /usr/share/wayland-sessions/hyprland.desktop <<'EOF'
[Desktop Entry]
Name=Hyprland
Comment=Hyprland Wayland Compositor
Exec=Hyprland
Type=Application
EOF

# 强制默认进入图形界面并启用 SDDM
systemctl set-default graphical.target
systemctl enable sddm

log "7.5) 中文输入法：fcitx5 + rime"
pacman -S --needed --noconfirm \
  fcitx5 fcitx5-configtool \
  fcitx5-im fcitx5-chinese-addons fcitx5-rime || true

cat > /etc/environment <<EOF
GTK_IM_MODULE=fcitx
QT_IM_MODULE=fcitx
XMODIFIERS=@im=fcitx
SDL_IM_MODULE=fcitx
EOF

log "7.6) 微信（Flatpak）"
flatpak remote-add --if-not-exists --system flathub https://flathub.org/repo/flathub.flatpakrepo
flatpak install -y --system flathub com.tencent.WeChat

log "7.7) yay + Chrome（AUR，普通用户构建）"
sudo -u ${USERNAME} bash -euo pipefail <<'USERPART'
set -euo pipefail
if ! command -v yay >/dev/null 2>&1; then
  tmpdir="$(mktemp -d)"
  git clone https://aur.archlinux.org/yay.git "$tmpdir/yay"
  (cd "$tmpdir/yay" && makepkg -si --noconfirm)
  rm -rf "$tmpdir"
fi
yay -S --noconfirm --needed google-chrome
USERPART

log "7.8) 写入 Hyprland 最小配置（含剪贴板历史/锁屏/退出）"
sudo -u ${USERNAME} bash -euo pipefail <<'USERCONF'
set -euo pipefail
mkdir -p ~/.config/hypr ~/.config/autostart

if [[ -f /usr/share/applications/org.fcitx.Fcitx5.desktop ]]; then
  cp -f /usr/share/applications/org.fcitx.Fcitx5.desktop ~/.config/autostart/ || true
fi

if [[ ! -f ~/.config/hypr/hyprland.conf ]]; then
  cat > ~/.config/hypr/hyprland.conf <<'EOF'
$mod = SUPER

exec-once = waybar
exec-once = fcitx5 -d
exec-once = nm-applet --indicator
exec-once = hyprpaper
exec-once = wl-paste --type text --watch cliphist store
exec-once = wl-paste --type image --watch cliphist store

bind = $mod, RETURN, exec, kitty
bind = $mod, D, exec, wofi --show drun

bind = $mod, Q, killactive,
bind = $mod, F, fullscreen,
bind = $mod, SPACE, togglefloating,

bind = $mod, H, movefocus, l
bind = $mod, L, movefocus, r
bind = $mod, K, movefocus, u
bind = $mod, J, movefocus, d

bind = $mod SHIFT, S, exec, grim -g "$(slurp)" - | wl-copy
bind = $mod, V, exec, cliphist list | wofi --dmenu | cliphist decode | wl-copy

bind = $mod, ESCAPE, exec, hyprlock
bind = $mod SHIFT, E, exec, wlogout

input {
  kb_layout = us
}

misc {
  disable_hyprland_logo = true
}
EOF
fi

if [[ ! -f ~/.config/hypr/hyprpaper.conf ]]; then
  cat > ~/.config/hypr/hyprpaper.conf <<'EOF'
preload = /usr/share/backgrounds/gnome/adwaita-l.webp
wallpaper = ,/usr/share/backgrounds/gnome/adwaita-l.webp
splash = false
EOF
fi

xdg-user-dirs-update || true
USERCONF

log "7.9) 安装 GRUB（UEFI）到 /boot/efi，并生成 grub.cfg"
grub-install --target=x86_64-efi --efi-directory=/boot/efi --bootloader-id=GRUB
grub-mkconfig -o /boot/grub/grub.cfg

log "7.10) VMware UEFI 兜底：写入 fallback BOOTX64.EFI"
# VMware 有时不读 NVRAM 启动项，会找 /EFI/BOOT/BOOTX64.EFI
mkdir -p /boot/efi/EFI/BOOT
if [[ -f /boot/efi/EFI/GRUB/grubx64.efi ]]; then
  cp -f /boot/efi/EFI/GRUB/grubx64.efi /boot/efi/EFI/BOOT/BOOTX64.EFI
else
  # 少数情况下路径不同，做一次查找兜底
  GRUB_EFI="$(find /boot/efi -maxdepth 4 -type f -iname 'grubx64.efi' | head -n 1 || true)"
  [[ -n "$GRUB_EFI" ]] && cp -f "$GRUB_EFI" /boot/efi/EFI/BOOT/BOOTX64.EFI
fi

log "chroot 配置完成"
CHROOT

log "8) 安装完成：请关机并断开 ISO，然后从硬盘启动进入 SDDM 图形登录"
cleanup

echo
echo "=================================================="
echo "安装完成。日志：$LOG_FILE"
echo "下一步（必须）："
echo "1) 现在执行：poweroff"
echo "2) VMware -> Settings -> CD/DVD -> 取消 Connect at power on / 断开 ISO"
echo "3) 再开机：将从 /dev/sda 启动 -> GRUB -> SDDM 图形登录 -> Hyprland"
echo "账号：${USERNAME}  密码：${USERPW}"
echo "=================================================="
echo
