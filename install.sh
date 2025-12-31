#!/usr/bin/env bash
set -euo pipefail

# Arch + Hyprland (VM) bootstrap:
# - Hyprland + Waybar + Wofi + basic tools
# - Fcitx5 + Rime (Chinese input)
# - Google Chrome (AUR via yay)
# - WeChat (Flatpak: com.tencent.WeChat)
#
# Run as a normal user with sudo privileges on a fresh-ish Arch install.

log(){ printf "\n\033[1;32m==> %s\033[0m\n" "$*"; }
warn(){ printf "\n\033[1;33m[!] %s\033[0m\n" "$*"; }
die(){ printf "\n\033[1;31m[ERR] %s\033[0m\n" "$*"; exit 1; }

need(){ command -v "$1" >/dev/null 2>&1 || die "Missing command: $1"; }

if [[ $EUID -eq 0 ]]; then
  die "Please run as a normal user (not root). The script will use sudo when needed."
fi

need sudo
need pacman

log "1) System update & base tools"
sudo pacman -Syu --noconfirm
sudo pacman -S --needed --noconfirm \
  git base-devel curl wget unzip ca-certificates \
  networkmanager nm-connection-editor \
  xdg-user-dirs xdg-utils \
  pipewire pipewire-alsa pipewire-pulse wireplumber \
  polkit polkit-gnome \
  noto-fonts noto-fonts-cjk noto-fonts-emoji ttf-dejavu \
  fastfetch

log "Enable NetworkManager"
sudo systemctl enable --now NetworkManager

log "2) Locale (zh_CN.UTF-8) + timezone (optional)"
# Locale: enable zh_CN.UTF-8 and en_US.UTF-8 if present
if ! grep -qE '^[^#]*zh_CN\.UTF-8 UTF-8' /etc/locale.gen; then
  sudo sed -i 's/^#\(zh_CN\.UTF-8 UTF-8\)/\1/' /etc/locale.gen || true
fi
if ! grep -qE '^[^#]*en_US\.UTF-8 UTF-8' /etc/locale.gen; then
  sudo sed -i 's/^#\(en_US\.UTF-8 UTF-8\)/\1/' /etc/locale.gen || true
fi
sudo locale-gen
echo 'LANG=zh_CN.UTF-8' | sudo tee /etc/locale.conf >/dev/null

# Timezone: comment out if you don't want to set it
sudo ln -sf /usr/share/zoneinfo/America/Los_Angeles /etc/localtime || true
sudo hwclock --systohc || true

log "3) Install Hyprland stack"
# Core Wayland/Hyprland + essentials
sudo pacman -S --needed --noconfirm \
  hyprland \
  waybar wofi \
  kitty \
  thunar thunar-archive-plugin file-roller \
  grim slurp wl-clipboard \
  xdg-desktop-portal xdg-desktop-portal-hyprland \
  qt5-wayland qt6-wayland \
  brightnessctl playerctl \
  pavucontrol \
  bluez bluez-utils \
  sddm

log "Enable Bluetooth (optional)"
sudo systemctl enable --now bluetooth || true

log "Enable SDDM (display manager)"
sudo systemctl enable --now sddm

log "4) Chinese input method: fcitx5 + rime"
sudo pacman -S --needed --noconfirm \
  fcitx5 fcitx5-configtool \
  fcitx5-im fcitx5-chinese-addons fcitx5-rime \
  rime-ice || true

# Environment variables for IM modules (system-wide)
# Recommended variables per ArchWiki
sudo tee /etc/environment >/dev/null <<'EOF'
GTK_IM_MODULE=fcitx
QT_IM_MODULE=fcitx
XMODIFIERS=@im=fcitx
SDL_IM_MODULE=fcitx
EOF

# Autostart fcitx5 for desktop sessions
mkdir -p ~/.config/autostart
if [[ -f /usr/share/applications/org.fcitx.Fcitx5.desktop ]]; then
  cp -f /usr/share/applications/org.fcitx.Fcitx5.desktop ~/.config/autostart/
fi

log "5) Install Flatpak + add Flathub + install WeChat"
sudo pacman -S --needed --noconfirm flatpak
# Add flathub (system-wide)
sudo flatpak remote-add --if-not-exists flathub https://flathub.org/repo/flathub.flatpakrepo
# Install WeChat
sudo flatpak install -y flathub com.tencent.WeChat

log "6) Install yay (AUR helper) + Google Chrome (AUR)"
if ! command -v yay >/dev/null 2>&1; then
  tmpdir="$(mktemp -d)"
  git clone https://aur.archlinux.org/yay.git "$tmpdir/yay"
  (cd "$tmpdir/yay" && makepkg -si --noconfirm)
  rm -rf "$tmpdir"
fi

# Install Chrome
yay -S --noconfirm --needed google-chrome

log "7) Basic Hyprland config (minimal, safe defaults)"
mkdir -p ~/.config/hypr
if [[ ! -f ~/.config/hypr/hyprland.conf ]]; then
  cat > ~/.config/hypr/hyprland.conf <<'EOF'
# Minimal Hyprland config for VM
# Mod key
$mod = SUPER

# Autostart
exec-once = waybar
exec-once = fcitx5 -d
exec-once = nm-applet --indicator

# Terminal / launcher
bind = $mod, RETURN, exec, kitty
bind = $mod, D, exec, wofi --show drun

# Basic window management
bind = $mod, Q, killactive,
bind = $mod, F, fullscreen,
bind = $mod, SPACE, togglefloating,

# Move focus
bind = $mod, H, movefocus, l
bind = $mod, L, movefocus, r
bind = $mod, K, movefocus, u
bind = $mod, J, movefocus, d

# Screenshot
bind = $mod SHIFT, S, exec, grim -g "$(slurp)" - | wl-copy

# Input (keyboard)
input {
  kb_layout = us
}

# Some VM-friendly defaults
misc {
  disable_hyprland_logo = true
}
EOF
fi

log "Done."
warn "Next steps:"
echo "1) Reboot: sudo reboot"
echo "2) On login screen (SDDM), choose session: Hyprland"
echo "3) Fcitx5: open 'Fcitx5 Configuration' and add 'Rime' input method"
echo "4) WeChat: launch from app menu (Flatpak). Chrome: launch 'Google Chrome'"
