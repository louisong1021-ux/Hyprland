#!/usr/bin/env bash
set -euo pipefail

# =========================================================
# Part 2: Install Hyprland + Essentials (Interactive EN)
# - Run this INSIDE the newly installed Arch system (from disk)
# - Refuses to run in archiso/live environment
# - Installs Hyprland + SDDM (graphical login)
# - Installs fonts, PipeWire audio, networking tray, basic tools
# - Installs Chinese input method (fcitx5 + rime) and sets env vars
# - Optional: Chrome (AUR via yay) and WeChat (Flatpak)
#
# Run as: normal user (with sudo)
# =========================================================

die(){ echo -e "\033[31mERROR: $*\033[0m" >&2;; exit 1; }
need(){ command -v "$1" >/dev/null 2>&1 || die "Missing command: $1"; }

# ---- Safety: refuse to run in Arch ISO / archiso ----
if grep -qiE 'archiso|archisobasedir|cow_spacesize' /proc/cmdline 2>/dev/null; then
  die "This script must be run in the installed system (booted from disk), not in archiso/ISO."
fi

[[ $EUID -ne 0 ]] || die "Please run as a normal user (not root). Use sudo when prompted."
need sudo
need pacman
need systemctl
need grep

echo
echo "=== Part 2: Hyprland setup (installed system) ==="
echo

# 1) Choose profile
echo "Select setup profile:"
echo "  1) Minimal Hyprland (recommended)"
echo "  2) Full (adds Chrome + WeChat + extras)"
echo
read -r -p "Enter 1 or 2: " PROFILE < /dev/tty
case "$PROFILE" in
  1) PROFILE_NAME="minimal" ;;
  2) PROFILE_NAME="full" ;;
  *) die "Invalid choice. Enter 1 or 2." ;;
esac
echo "Selected profile: $PROFILE_NAME"
echo

# 2) Update system
echo "Updating package databases and system..."
sudo pacman -Syu --noconfirm

# 3) Base desktop stack (Hyprland + DM + core Wayland tools)
BASE_PKGS=(
  hyprland
  sddm
  xorg-xwayland

  waybar wofi kitty

  xdg-desktop-portal xdg-desktop-portal-hyprland xdg-desktop-portal-gtk
  qt5-wayland qt6-wayland

  grim slurp wl-clipboard
  cliphist

  thunar thunar-archive-plugin file-roller
  gvfs

  polkit polkit-gnome

  network-manager-applet

  pipewire pipewire-alsa pipewire-pulse wireplumber
  pavucontrol pamixer

  noto-fonts noto-fonts-cjk noto-fonts-emoji ttf-dejavu

  unzip p7zip unrar
  wget curl
  htop btop
  ripgrep fd
)

echo "Installing Hyprland and core packages..."
sudo pacman -S --needed --noconfirm "${BASE_PKGS[@]}"

# 4) Ensure SDDM can see Hyprland session
echo "Creating Hyprland session entry for display manager..."
sudo mkdir -p /usr/share/wayland-sessions
sudo tee /usr/share/wayland-sessions/hyprland.desktop >/dev/null <<'EOF'
[Desktop Entry]
Name=Hyprland
Comment=Hyprland Wayland Compositor
Exec=Hyprland
Type=Application
EOF

# 5) Chinese input method (fcitx5 + rime)
echo "Installing Chinese input method (fcitx5 + rime)..."
sudo pacman -S --needed --noconfirm \
  fcitx5 fcitx5-configtool \
  fcitx5-im fcitx5-chinese-addons fcitx5-rime

echo "Setting system-wide input method environment variables..."
sudo tee /etc/environment >/dev/null <<'EOF'
GTK_IM_MODULE=fcitx
QT_IM_MODULE=fcitx
XMODIFIERS=@im=fcitx
SDL_IM_MODULE=fcitx
EOF

# 6) Minimal Hyprland config (safe defaults)
echo "Writing minimal Hyprland config..."
mkdir -p "$HOME/.config/hypr" "$HOME/.config/autostart"

# Autostart fcitx5 if desktop entry exists
if [[ -f /usr/share/applications/org.fcitx.Fcitx5.desktop ]]; then
  cp -f /usr/share/applications/org.fcitx.Fcitx5.desktop "$HOME/.config/autostart/" || true
fi

if [[ ! -f "$HOME/.config/hypr/hyprland.conf" ]]; then
  cat > "$HOME/.config/hypr/hyprland.conf" <<'EOF'
$mod = SUPER

exec-once = waybar
exec-once = fcitx5 -d
exec-once = nm-applet --indicator
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

input {
  kb_layout = us
}

misc {
  disable_hyprland_logo = true
}
EOF
else
  echo "Hyprland config already exists, not overwriting: $HOME/.config/hypr/hyprland.conf"
fi

# 7) Optional: Full profile extras
if [[ "$PROFILE_NAME" == "full" ]]; then
  echo
  echo "Full profile selected: installing extras..."
  echo

  # Flatpak + WeChat
  echo "Installing Flatpak and WeChat (Flatpak)..."
  sudo pacman -S --needed --noconfirm flatpak
  sudo flatpak remote-add --if-not-exists --system flathub https://flathub.org/repo/flathub.flatpakrepo
  sudo flatpak install -y --system flathub com.tencent.WeChat

  # AUR helper (yay) + Chrome
  echo "Installing yay (AUR helper) if missing..."
  if ! command -v yay >/dev/null 2>&1; then
    sudo pacman -S --needed --noconfirm base-devel git
    tmpdir="$(mktemp -d)"
    git clone https://aur.archlinux.org/yay.git "$tmpdir/yay"
    (cd "$tmpdir/yay" && makepkg -si --noconfirm)
    rm -rf "$tmpdir"
  fi

  echo "Installing Google Chrome (AUR)..."
  yay -S --needed --noconfirm google-chrome

  # Extras commonly useful for Hyprland
  echo "Installing extra Hyprland tools..."
  sudo pacman -S --needed --noconfirm \
    hyprpaper hyprlock hypridle \
    wlogout \
    brightnessctl playerctl
fi

# 8) Enable graphical boot + SDDM
echo
echo "Enabling graphical target and SDDM..."
sudo systemctl set-default graphical.target
sudo systemctl enable --now sddm

echo
echo "✅ Part 2 complete."
echo "Notes:"
echo "  - On the login screen, select session: Hyprland"
echo "  - First-time Chinese input: open Fcitx5 config and enable Rime."
echo "  - If you were previously in TTY, reboot to verify graphical login."
echo
read -r -p "Reboot now? (y/N): " RB < /dev/tty
if [[ "${RB,,}" == "y" ]]; then
  sudo reboot
else
  echo "Done. You can reboot later with: sudo reboot"
fi
