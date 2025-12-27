#!/usr/bin/env bash
set -euo pipefail

# ==============================================================================
# Arch Linux BIOS Legacy Installer (LUKS2 + BTRFS + Limine) - FIXED VERSION
# ==============================================================================

echo "=== Arch Linux BIOS Legacy Installer ==="

lsblk
echo ""

read -rp "Enter target disk (e.g. /dev/sda): " DISK
read -rp "Enter username: " USERNAME
read -srp "Enter user password: " USER_PASS; echo
read -srp "Enter root password: " ROOT_PASS; echo
read -srp "Enter LUKS encryption password: " LUKS_PASS; echo

# ========= TIMEZONE =========
TIMEZONE=$(curl -fsSL https://ipapi.co/timezone || echo "UTC")

# ========= PARTITIONING (MBR) =========
sgdisk --zap-all "$DISK"

parted --script "$DISK" \
    mklabel msdos \
    mkpart primary ext4 1MiB 1025MiB \
    set 1 boot on \
    mkpart primary 1025MiB 100%

if [[ "$DISK" =~ nvme ]]; then
    BOOT="${DISK}p1"
    ROOT="${DISK}p2"
else
    BOOT="${DISK}1"
    ROOT="${DISK}2"
fi

# ========= FORMAT & LUKS =========
mkfs.ext4 -F "$BOOT"
echo -n "$LUKS_PASS" | cryptsetup luksFormat --type luks2 "$ROOT" -
echo -n "$LUKS_PASS" | cryptsetup open "$ROOT" root -

# ========= BTRFS SUBVOLUMES =========
mkfs.btrfs -L ARCH_ROOT /dev/mapper/root
mount /dev/mapper/root /mnt

btrfs subvolume create /mnt/@
btrfs subvolume create /mnt/@home
btrfs subvolume create /mnt/@var_log
btrfs subvolume create /mnt/@pkg
umount /mnt

# ========= MOUNTING =========
BTRFS_OPTS="compress=zstd:1,noatime"
mount -o $BTRFS_OPTS,subvol=@ /dev/mapper/root /mnt
mount --mkdir -o $BTRFS_OPTS,subvol=@home /dev/mapper/root /mnt/home
mount --mkdir -o $BTRFS_OPTS,subvol=@var_log /dev/mapper/root /mnt/var/log
mount --mkdir -o $BTRFS_OPTS,subvol=@pkg /dev/mapper/root /mnt/var/cache/pacman/pkg

mkdir -p /mnt/boot
mount "$BOOT" /mnt/boot

# ========= MICROCODE DETECTION =========
UCODE_PKG=""
UCODE_LINE=""
if grep -q "Intel" /proc/cpuinfo; then
    UCODE_PKG="intel-ucode"
    UCODE_LINE="module_path: /intel-ucode.img"
elif grep -q "AMD" /proc/cpuinfo; then
    UCODE_PKG="amd-ucode"
    UCODE_LINE="module_path: /amd-ucode.img"
fi

# ========= BASE INSTALL =========
pacman -Sy --noconfirm archlinux-keyring
pacstrap -K /mnt \
    base base-devel linux linux-firmware \
    btrfs-progs cryptsetup limine $UCODE_PKG \
    networkmanager sudo vim git \
    pipewire pipewire-alsa pipewire-pulse wireplumber \
    bluez bluez-utils firewalld acpid avahi rsync

genfstab -U /mnt >> /mnt/etc/fstab

# ========= CHROOT CONFIGURATION =========
LUKS_UUID=$(cryptsetup luksUUID "$ROOT")
export TIMEZONE ROOT_PASS USERNAME USER_PASS LUKS_UUID UCODE_LINE

arch-chroot /mnt /bin/bash -e <<EOF
ln -sf "/usr/share/zoneinfo/\$TIMEZONE" /etc/localtime
hwclock --systohc
sed -i 's/^#en_US.UTF-8 UTF-8/en_US.UTF-8 UTF-8/' /etc/locale.gen
locale-gen
echo "LANG=en_US.UTF-8" > /etc/locale.conf
echo "arch" > /etc/hostname

echo "root:\$ROOT_PASS" | chpasswd
useradd -m -G wheel -s /bin/bash "\$USERNAME"
echo "\$USERNAME:\$USER_PASS" | chpasswd
sed -i 's/^# %wheel ALL=(ALL:ALL) ALL/%wheel ALL=(ALL:ALL) ALL/' /etc/sudoers

sed -i 's/^HOOKS=.*/HOOKS=(base udev autodetect modconf block encrypt filesystems keyboard fsck)/' /etc/mkinitcpio.conf
mkinitcpio -P

# --- LIMINE CONFIG (FIXED FOR SEPARATE BOOT) ---
# Al tener partición /boot aparte, para Limine la raíz "/" es el contenido de esa partición.
mkdir -p /boot/limine
cat <<LIMINECONF > /boot/limine.conf
timeout: 3

/Arch Linux
    protocol: linux
    kernel_path: /vmlinuz-linux
    \$UCODE_LINE
    module_path: /initramfs-linux.img
    cmdline: cryptdevice=UUID=\$LUKS_UUID:root root=/dev/mapper/root rw rootflags=subvol=@

/Arch Linux (fallback)
    protocol: linux
    kernel_path: /vmlinuz-linux
    \$UCODE_LINE
    module_path: /initramfs-linux-fallback.img
    cmdline: cryptdevice=UUID=\$LUKS_UUID:root root=/dev/mapper/root rw rootflags=subvol=@
LIMINECONF

# Copiar el archivo Stage 3 a la raíz de la partición de arranque
cp /usr/share/limine/limine-bios.sys /boot/limine/

for s in NetworkManager bluetooth avahi-daemon firewalld acpid; do
    systemctl enable "\$s"
done
EOF

# ========= LIMINE BIOS INSTALL =========
echo "--- Finalizing bootloader stage ---"
/mnt/usr/bin/limine bios-install "$DISK"

# ========= INTERACTIVE CHROOT (OPCIONAL) =========
echo ""
read -rp "Do you want to enter the system via arch-chroot before unmounting? [y/N]: " CHROOT_CONFIRM
if [[ "${CHROOT_CONFIRM,,}" =~ ^(y|yes)$ ]]; then
    echo "Entering interactive chroot. Type 'exit' to finish."
    arch-chroot /mnt
fi

# ========= CLEANUP =========
echo "--- Unmounting and closing LUKS ---"
sync
umount -R /mnt
cryptsetup close root

echo "=== INSTALLATION COMPLETE ==="
echo "Remove installation media and reboot."
