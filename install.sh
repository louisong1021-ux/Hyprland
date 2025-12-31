#!/usr/bin/env bash
set -euo pipefail

# =========================================================
# Arch Linux Minimal Installer (UEFI + GRUB) - Interactive (EN)
# - Runs in Arch ISO (archiso) as root
# - Step 1: Choose environment (Physical / VMware)
# - Step 2: List disks and select target disk
# - Wipes the selected disk and installs a minimal Arch base
# - Installs GRUB (UEFI) to ESP mounted at /boot/efi
# - VMware extra: writes UEFI fallback /EFI/BOOT/BOOTX64.EFI
#
# NOTES:
# - Minimal packages only. Hyprland and other apps should be installed by a separate script.
# - Requires UEFI boot. (BIOS not supported in this script.)
# =========================================================

# ---------- Fixed config ----------
HOSTNAME="arch-min"
USERNAME="rui"
TZ="America/Los_Angeles"
LOCALE="zh_CN.UTF-8"
KEYMAP="us"
ROOTPW="root"
USERPW="123456"

ESP_SIZE="512MiB"
SWAP_SIZE="2GiB"     # set to "0GiB" to disable swap
# -------------------------------

die(){ echo -e "\033[31mERROR: $*\033[0m" >&2; exit 1; }
need(){ command -v "$1" >/dev/null 2>&1 || die "Missing command: $1"; }

for c in lsblk sgdisk partprobe mkfs.fat mkfs.ext4 mkswap swapon mount umount pacstrap genfstab arch-chroot timedatectl loadkeys awk sed find head; do
  need "$c"
done

[[ $EUID -eq 0 ]] || die "Run as root in Arch ISO (archiso)."
[[ -d /sys/firmware/efi ]] || die "UEFI boot is required (/sys/firmware/efi not found)."

# Partition name helper: NVMe needs p1/p2, SATA uses 1/2
part() {
  local disk="$1" n="$2"
  if [[ "$disk" =~ [0-9]$ ]]; then
    echo "${disk}p${n}"
  else
    echo "${disk}${n}"
  fi
}

# Best-effort cleanup
umount -R /mnt 2>/dev/null || true
swapoff -a 2>/dev/null || true

echo
echo "=== Arch Linux Minimal Installer (UEFI + GRUB) ==="
echo "WARNING: This will ERASE the selected disk completely."
echo

# ---------------- Environment selection ----------------
echo "Select installation environment:"
echo "  1) Physical machine"
echo "  2) VMware virtual machine"
echo
read -r -p "Enter 1 or 2: " INSTALL_ENV < /dev/tty

case "$INSTALL_ENV" in
  1) ENV_TYPE="physical"; echo "Selected: Physical machine" ;;
  2) ENV_TYPE="vmware";  echo "Selected: VMware virtual machine" ;;
  *) die "Invalid choice. Enter 1 or 2." ;;
esac
echo

# ---------------- Disk selection ----------------
echo "===== Available disks (WILL BE ERASED) ====="
mapfile -t DISKS < <(lsblk -dn -o NAME,TYPE | awk '$2=="disk"{print $1}')
((${#DISKS[@]} > 0)) || die "No disks detected."

for i in "${!DISKS[@]}"; do
  name="${DISKS[$i]}"
  size="$(lsblk -dn -o SIZE "/dev/$name" | head -n1)"
  model="$(lsblk -dn -o MODEL "/dev/$name" | head -n1)"
  tran="$(lsblk -dn -o TRAN "/dev/$name" 2>/dev/null | head -n1 || true)"
  echo "  [$i] /dev/${name}   size=${size}   model=${model:-unknown}   tran=${tran:-unknown}"
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

# ---------------- Time / keymap ----------------
timedatectl set-ntp true || true
loadkeys "$KEYMAP" || true

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

# ---------------- Packages (minimal) ----------------
PKGS=(
  base linux linux-firmware
  grub efibootmgr
  networkmanager sudo
  vim git
  openssh
)

# Optional microcode for physical machines (edit/remove as desired)
if [[ "$ENV_TYPE" == "physical" ]]; then
  PKGS+=(intel-ucode)
fi

# Optional VMware tools (you can also move this to Part 2)
if [[ "$ENV_TYPE" == "vmware" ]]; then
  PKGS+=(open-vm-tools)
fi

echo
echo "===== Installing minimal Arch (pacstrap) ====="
pacstrap -K /mnt "${PKGS[@]}"

genfstab -U /mnt >> /mnt/etc/fstab

# ---------------- Chroot configuration ----------------
echo
echo "===== Configuring system (chroot) ====="
arch-chroot /mnt /bin/bash -euo pipefail <<CHROOT
ln -sf /usr/share/zoneinfo/${TZ} /etc/localtime
hwclock --systohc

# Locale
sed -i "s/^#\\(${LOCALE} UTF-8\\)/\\1/" /etc/locale.gen || true
sed -i "s/^#\\(en_US.UTF-8 UTF-8\\)/\\1/" /etc/locale.gen || true
locale-gen
echo "LANG=${LOCALE}" > /etc/locale.conf

# Console keymap (prevents mkinitcpio warning)
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

# Passwords / user
echo "root:${ROOTPW}" | chpasswd
id -u "${USERNAME}" >/dev/null 2>&1 || useradd -m -G wheel -s /bin/bash "${USERNAME}"
echo "${USERNAME}:${USERPW}" | chpasswd
sed -i 's/^# %wheel ALL=(ALL:ALL) ALL/%wheel ALL=(ALL:ALL) ALL/' /etc/sudoers

# Services
systemctl enable NetworkManager
systemctl enable sshd

if [[ "${ENV_TYPE}" == "physical" ]]; then
  systemctl enable fstrim.timer || true
fi

if [[ "${ENV_TYPE}" == "vmware" ]]; then
  systemctl enable vmtoolsd || true
fi

echo "${ENV_TYPE}" > /etc/arch-install-env

# GRUB (UEFI)
grub-install --target=x86_64-efi --efi-directory=/boot/efi --bootloader-id=ARCH
grub-mkconfig -o /boot/grub/grub.cfg

# VMware UEFI fallback (fixes "No compatible bootloader found" in some VMware configs)
if [[ "${ENV_TYPE}" == "vmware" ]]; then
  mkdir -p /boot/efi/EFI/BOOT
  if [[ -f /boot/efi/EFI/ARCH/grubx64.efi ]]; then
    cp -f /boot/efi/EFI/ARCH/grubx64.efi /boot/efi/EFI/BOOT/BOOTX64.EFI
  else
    GRUB_EFI="\$(find /boot/efi -maxdepth 5 -type f -iname 'grubx64.efi' | head -n 1 || true)"
    [[ -n "\$GRUB_EFI" ]] && cp -f "\$GRUB_EFI" /boot/efi/EFI/BOOT/BOOTX64.EFI
  fi
fi
CHROOT

echo
echo "✅ Part 1 complete."
echo "Next steps:"
echo "  1) Power off now: poweroff"
echo "  2) If using VMware, disconnect the ISO (disable 'Connect at power on')"
echo "  3) Boot from disk and login: ${USERNAME} / ${USERPW}"
echo "  4) Run your Part 2 script to install Hyprland and other apps"
echo

umount -R /mnt
reboot
