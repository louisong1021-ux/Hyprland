#!/usr/bin/env bash
set -euo pipefail

# =========================================================
# ArchISO 全自动安装脚本（固定安装到 /dev/sda，无需输入 YES）
# - 自动分区/格式化/安装 Arch
# - 安装 Hyprland + 中文输入法(fcitx5+rime) + Chrome + 微信(Flatpak)
# - 补齐你需要的 Hyprland 生态与常用软件（见下方“补齐清单”）
# - GRUB 自动适配 UEFI / Legacy BIOS
#
# ⚠️ 警告：此脚本会无条件清空 /dev/sda（整盘重装）
# 仅建议用于虚拟机测试环境
# =========================================================

# ===== 固定目标盘（按你的要求写死）=====
DISK="/dev/sda"

# ===== 可改参数 =====
HOSTNAME="arch-hypr"
USERNAME="rui"
TZ="America/Los_Angeles"
LOCALE="zh_CN.UTF-8"
KEYMAP="us"

# 测试用密码（装完建议立刻修改）
ROOTPW="root"
USERPW="123456"

ESP_SIZE="512MiB"   # EFI 分区
SWAP_SIZE="0GiB"    # 例如 "2GiB"；0GiB 表示不建 swap
# ===================

# ===== 日志（archiso 下写到 /root/install.log）=====
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

log "目标磁盘固定为：$DISK"
lsblk "$DISK" || true

warn "即将清空并重装整块磁盘：$DISK（无确认步骤）"
warn "如果这不是你要装的盘，请立刻按 Ctrl+C 终止。"
for i in 5 4 3 2 1; do
  echo "  $i..."
  sleep 1
done

log "1) 时间同步 & 键盘布局"
timedatectl set-ntp true || true
loadkeys "$KEYMAP" || true

log "2) 清理旧挂载/交换（如果有）"
cleanup

log "3) 清空分区表并创建 GPT 分区（ESP + ROOT + 可选 SWAP）"
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

log "5) 挂载到 /mnt（ESP 挂到 /boot）"
mount "$ROOT_PART" /mnt
mkdir -p /mnt/boot
mount "$ESP_PART" /mnt/boot

log "6) pacstrap 安装基础系统 + 你需要的软件（补齐清单）"
# ===== 补齐清单（你提到/我建议你需要的）=====
# Hyprland生态：xdg-desktop-portal-gtk、cliphist、hyprpaper、hyprlock、hypridle、wlogout、pamixer
# 日常：firefox、p7zip、unrar、gvfs、ntfs-3g、exfatprogs
# 工具：openssh、btop/htop、ncdu、ripgrep、fd、tmux、python、jq
# ==================================================

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
  firefox

genfstab -U /mnt >> /mnt/etc/fstab

log "7) chroot 配置系统 + 安装 Hyprland/输入法/Chrome/微信 + 补齐组件"
arch-chroot /mnt /bin/bash -euo pipefail <<CHROOT
log(){ printf "\n\033[1;32m==> %s\033[0m\n" "\$*"; }
warn(){ printf "\n\033[1;33m[!] %s\033[0m\n" "\$*"; }
die(){ printf "\n\033[1;31m[ERR] %s\033[0m\n" "\$*"; exit 1; }

log "7.1) 时区 / 语言 / 主机名"
ln -sf /usr/share/zoneinfo/${TZ} /etc/localtime || true
hwclock --systohc || true

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

log "7.2) 创建用户 + sudo"
id -u ${USERNAME} >/dev/null 2>&1 || useradd -m -G wheel -s /bin/bash ${USERNAME}
echo "root:${ROOTPW}" | chpasswd
echo "${USERNAME}:${USERPW}" | chpasswd
sed -i 's/^# %wheel ALL=(ALL:ALL) ALL/%wheel ALL=(ALL:ALL) ALL/' /etc/sudoers

log "7.3) 启用服务：NetworkManager / SSH / VMware Tools"
systemctl enable NetworkManager
systemctl enable sshd
systemctl enable vmtoolsd || true

log "7.4) 安装 Hyprland + 生态补齐 + SDDM"
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

log "7.6) 安装微信（Flatpak / Flathub，系统级）"
flatpak remote-add --if-not-exists --system flathub https://flathub.org/repo/flathub.flatpakrepo
flatpak install -y --system flathub com.tencent.WeChat

log "7.7) 安装 yay + Chrome（AUR，使用普通用户构建）"
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

log "7.8) 写入 Hyprland 最小配置（补齐：壁纸/锁屏/剪贴板历史/退出菜单）"
sudo -u ${USERNAME} bash -euo pipefail <<'USERCONF'
set -euo pipefail

mkdir -p ~/.config/hypr ~/.config/autostart ~/.config/waybar

# 自启动 fcitx5（更稳）
if [[ -f /usr/share/applications/org.fcitx.Fcitx5.desktop ]]; then
  cp -f /usr/share/applications/org.fcitx.Fcitx5.desktop ~/.config/autostart/ || true
fi

# Hyprland 主配置
if [[ ! -f ~/.config/hypr/hyprland.conf ]]; then
  cat > ~/.config/hypr/hyprland.conf <<'EOF'
$mod = SUPER

# ===== Autostart =====
exec-once = waybar
exec-once = fcitx5 -d
exec-once = nm-applet --indicator
exec-once = hyprpaper
exec-once = wl-paste --type text --watch cliphist store
exec-once = wl-paste --type image --watch cliphist store

# ===== Terminal / launcher =====
bind = $mod, RETURN, exec, kitty
bind = $mod, D, exec, wofi --show drun

# ===== Basic window management =====
bind = $mod, Q, killactive,
bind = $mod, F, fullscreen,
bind = $mod, SPACE, togglefloating,

# ===== Focus =====
bind = $mod, H, movefocus, l
bind = $mod, L, movefocus, r
bind = $mod, K, movefocus, u
bind = $mod, J, movefocus, d

# ===== Screenshot =====
bind = $mod SHIFT, S, exec, grim -g "$(slurp)" - | wl-copy

# ===== Clipboard history (wofi) =====
bind = $mod, V, exec, cliphist list | wofi --dmenu | cliphist decode | wl-copy

# ===== Lock / logout =====
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

# hyprpaper 配置（简单壁纸：纯色占位 + 你可自行替换）
mkdir -p ~/.config/hypr
if [[ ! -f ~/.config/hypr/hyprpaper.conf ]]; then
  cat > ~/.config/hypr/hyprpaper.conf <<'EOF'
# 你可以把壁纸放到 ~/Pictures/wallpaper.jpg 并替换下面路径
preload = /usr/share/backgrounds/gnome/adwaita-l.webp
wallpaper = ,/usr/share/backgrounds/gnome/adwaita-l.webp
splash = false
EOF
fi

# 创建用户目录
xdg-user-dirs-update || true
USERCONF

log "7.9) 安装 GRUB（自动兼容 UEFI / Legacy BIOS）"
if [[ -d /sys/firmware/efi ]]; then
  log "检测到 UEFI：安装 GRUB x86_64-efi 到 ESP(/boot)"
  grub-install --target=x86_64-efi --efi-directory=/boot --bootloader-id=GRUB
else
  log "检测到 Legacy BIOS：安装 GRUB i386-pc 到 ${DISK}"
  grub-install --target=i386-pc ${DISK}
fi
grub-mkconfig -o /boot/grub/grub.cfg

log "chroot 配置完成"
CHROOT

log "8) 卸载挂载并重启"
cleanup

warn "安装完成：即将重启。日志在：$LOG_FILE"
reboot
