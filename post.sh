#!/usr/bin/env bash
set -euo pipefail

# ===================== CONFIG =====================
HOSTNAME="arch-hypr-vm"
USERNAME="rui"
USERPW="123456"
ROOTPW="root"

TZ="America/Los_Angeles"
LOCALE="en_US.UTF-8"
KEYMAP="us"

ESP_SIZE="512MiB"
SWAP_SIZE="0GiB"   # set to "2GiB" if you want swap
# ==================================================

die(){ echo -e "\033[31mERROR: $*\033[0m" >&2; exit 1; }
need(){ command -v "$1" >/dev/null 2>&1 || die "Missing command: $1"; }

for c in lsblk sgdisk partprobe mkfs.fat mkfs.ext4 mkswap swapon mount umount \
         pacstrap genfstab arch-chroot timedatectl awk sed find head; do
  need "$c"
done

[[ $EUID -eq 0 ]] || die "Run as root in Arch ISO (archiso)."
[[ -d /sys/firmware/efi ]] || die "UEFI boot is required (/sys/firmware/efi not found)."

part() {
  local disk="$1" n="$2"
  if [[ "$disk" =~ [0-9]$ ]]; then echo "${disk}p${n}"; else echo "${disk}${n}"; fi
}

umount -R /mnt 2>/dev/null || true
swapoff -a 2>/dev/null || true

echo
echo "=== VMware Arch + Hyprland Installer (UEFI + GRUB, auto-start Hyprland) ==="
echo "WARNING: This will ERASE the selected disk."
echo

# ---------------- Disk selection ----------------
echo "===== Available disks (WILL BE ERASED) ====="
mapfile -t DISKS < <(lsblk -dn -o NAME,TYPE | awk '$2=="disk"{print $1}')
((${#DISKS[@]} > 0)) || die "No disks detected."

for i in "${!DISKS[@]}"; do
  name="${DISKS[$i]}"
  size="$(lsblk -dn -o SIZE "/dev/$name" | head -n1)"
  model="$(lsblk -dn -o MODEL "/dev/$name" | head -n1)"
  echo "  [$i] /dev/${name}   size=${size}   model=${model:-unknown}"
done

echo
read -r -p "Enter disk number to install to (e.g. 0): " DISK_IDX < /dev/tty
[[ "$DISK_IDX" =~ ^[0-9]+$ ]] || die "Please enter a numeric disk index."
(( DISK_IDX >= 0 && DISK_IDX < ${#DISKS[@]} )) || die "Disk index out of range."

DISK="/dev/${DISKS[$DISK_IDX]}"
[[ -b "$DISK" ]] || die "Disk not found: $DISK"

echo
echo "You selected: $DISK"
lsblk "$DISK"
echo
read -r -p "Type YES to confirm erasing and installing to ${DISK}: " ok < /dev/tty
[[ "$ok" == "YES" ]] || die "Cancelled."

# ---------------- Time sync ----------------
timedatectl set-ntp true || true

# ---------------- Partitioning ----------------
echo
echo "===== Partitioning (GPT + EFI) ====="
sgdisk --zap-all "${DISK}"
sgdisk -o "${DISK}"
sgdisk -n 1:0:+"${ESP_SIZE}" -t 1:ef00 -c 1:"EFI" "${DISK}"

if [[ "${SWAP_SIZE}" != "0" && "${SWAP_SIZE}" != "0GiB" ]]; then
  sgdisk -n 2:0:+"${SWAP_SIZE}" -t 2:8200 -c 2:"SWAP" "${DISK}"
  sgdisk -n 3:0:0 -t 3:8300 -c 3:"ROOT" "${DISK}"
  ESP="$(part "$DISK" 1)"; SWP="$(part "$DISK" 2)"; ROOT="$(part "$DISK" 3)"
else
  sgdisk -n 2:0:0 -t 2:8300 -c 2:"ROOT" "${DISK}"
  ESP="$(part "$DISK" 1)"; SWP=""; ROOT="$(part "$DISK" 2)"
fi

partprobe "$DISK" || true
sleep 1

echo "EFI : $ESP"
echo "SWAP: ${SWP:-<none>}"
echo "ROOT: $ROOT"

# ---------------- Formatting ----------------
echo
echo "===== Formatting ====="
mkfs.fat -F32 "${ESP}"
mkfs.ext4 -F "${ROOT}"
if [[ -n "${SWP}" ]]; then
  mkswap "${SWP}"
  swapon "${SWP}"
fi

# ---------------- Mounting ----------------
echo
echo "===== Mounting ====="
mount "${ROOT}" /mnt
mkdir -p /mnt/boot/efi
mount "${ESP}" /mnt/boot/efi

# ---------------- Packages (minimal for Hyprland to actually run) ----------------
# "Only Arch + Hyprland" in practice means:
# - base system + kernel + firmware
# - GRUB (UEFI) + efibootmgr
# - NetworkManager (so you can network after boot)
# - Hyprland + Xwayland
# - portals (many desktop apps need them)
# - a tiny terminal (to confirm you are in Hyprland)
# - vm tools optional but recommended for VMware usability
PKGS=(
  base linux linux-firmware
  grub efibootmgr
  networkmanager sudo
  hyprland xorg-xwayland
  xdg-desktop-portal xdg-desktop-portal-hyprland xdg-desktop-portal-gtk
  qt5-wayland qt6-wayland
  foot
  noto-fonts noto-fonts-emoji
  open-vm-tools
)

echo
echo "===== Installing system (pacstrap) ====="
pacstrap -K /mnt "${PKGS[@]}"
genfstab -U /mnt >> /mnt/etc/fstab

# ---------------- Chroot configuration ----------------
echo
echo "===== Configuring system (chroot) ====="
arch-chroot /mnt /bin/bash -euo pipefail <<CHROOT
set -euo pipefail

ln -sf /usr/share/zoneinfo/${TZ} /etc/localtime
hwclock --systohc

# Locale
sed -i "s/^#\\(${LOCALE} UTF-8\\)/\\1/" /etc/locale.gen || true
sed -i "s/^#\\(en_US.UTF-8 UTF-8\\)/\\1/" /etc/locale.gen || true
locale-gen
echo "LANG=${LOCALE}" > /etc/locale.conf

# Console keymap
cat > /etc/vconsole.conf <<EOF
KEYMAP=${KEYMAP}
EOF

# Hostname / hosts
echo "${HOSTNAME}" > /etc/hostname
cat > /etc/hosts <<EOF
127.0.0.1 localhost
::1       localhost
127.0.1.1 ${HOSTNAME}.localdomain ${HOSTNAME}
EOF

# Users
echo "root:${ROOTPW}" | chpasswd
id -u "${USERNAME}" >/dev/null 2>&1 || useradd -m -G wheel -s /bin/bash "${USERNAME}"
echo "${USERNAME}:${USERPW}" | chpasswd
sed -i 's/^# %wheel ALL=(ALL:ALL) ALL/%wheel ALL=(ALL:ALL) ALL/' /etc/sudoers

# Services
systemctl enable NetworkManager
systemctl enable vmtoolsd || true

# ----- Auto-login on tty1 + auto start Hyprland -----
mkdir -p /etc/systemd/system/getty@tty1.service.d
cat > /etc/systemd/system/getty@tty1.service.d/override.conf <<EOF
[Service]
ExecStart=
ExecStart=-/usr/bin/agetty --autologin ${USERNAME} --noclear %I \$TERM
EOF

# A minimal Hyprland config (per-user)
install -d -m 0755 /home/${USERNAME}/.config/hypr
cat > /home/${USERNAME}/.config/hypr/hyprland.conf <<'EOF'
$mod = SUPER
bind = $mod, RETURN, exec, foot
bind = $mod, Q, killactive
bind = $mod, M, exit

misc { disable_hyprland_logo = true }
EOF
chown -R ${USERNAME}:${USERNAME} /home/${USERNAME}/.config

# Start Hyprland automatically when logging into tty1
cat > /home/${USERNAME}/.bash_profile <<'EOF'
# Auto-start Hyprland on tty1
if [[ -z "${WAYLAND_DISPLAY:-}" && "$(tty)" == "/dev/tty1" ]]; then
  exec Hyprland
fi
EOF
chown ${USERNAME}:${USERNAME} /home/${USERNAME}/.bash_profile

# Bootloader: GRUB UEFI
grub-install --target=x86_64-efi --efi-directory=/boot/efi --bootloader-id=ARCH
grub-mkconfig -o /boot/grub/grub.cfg

# VMware/UEFI fallback (fixes "No compatible bootloader found" sometimes)
mkdir -p /boot/efi/EFI/BOOT
if [[ -f /boot/efi/EFI/ARCH/grubx64.efi ]]; then
  cp -f /boot/efi/EFI/ARCH/grubx64.efi /boot/efi/EFI/BOOT/BOOTX64.EFI
else
  GRUB_EFI="\$(find /boot/efi -maxdepth 5 -type f -iname 'grubx64.efi' | head -n 1 || true)"
  [[ -n "\$GRUB_EFI" ]] && cp -f "\$GRUB_EFI" /boot/efi/EFI/BOOT/BOOTX64.EFI
fi
CHROOT

echo
echo "✅ Install complete."
echo "IMPORTANT (VMware): Disconnect the ISO before the next boot."
echo "After reboot, it will auto-login and start Hyprland on tty1."
echo
echo "Hyprland keybinds:"
echo "  Super+Enter  -> terminal (foot)"
echo "  Super+Q      -> close window"
echo "  Super+M      -> exit Hyprland"
echo

umount -R /mnt
reboot
