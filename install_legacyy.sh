#!/usr/bin/env bash
set -euo pipefail

# ==============================================================================
# Arch Linux BIOS Legacy Installer (LUKS2 + BTRFS + Limine)
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
    mkpart primary fat32 1MiB 1024MiB \
    set 1 boot on \
    mkpart primary 1024MiB 100%

# Detectar particiones según el tipo de disco
if [[ "$DISK" =~ nvme ]]; then
    BOOT="${DISK}p1"
    ROOT="${DISK}p2"
else
    BOOT="${DISK}1"
    ROOT="${DISK}2"
fi

# ========= FORMAT & LUKS =========
# Necesitamos dosfstools para FAT32
mkfs.vfat -F 32 "$BOOT"

echo -n "$LUKS_PASS" | cryptsetup luksFormat --type luks2 "$ROOT" -
echo -n "$LUKS_PASS" | cryptsetup open "$ROOT" root -

# ========= BTRFS =========
mkfs.btrfs -L ARCH_ROOT /dev/mapper/root
mount /dev/mapper/root /mnt

for sub in @ @home @var_log @pkg; do
    btrfs subvolume create "/mnt/$sub"
done
umount /mnt

# ========= MOUNTING =========
BTRFS_OPTS="compress=zstd:1,noatime"
mount -o $BTRFS_OPTS,subvol=@ /dev/mapper/root /mnt
mount --mkdir -o $BTRFS_OPTS,subvol=@home /dev/mapper/root /mnt/home
mount --mkdir -o $BTRFS_OPTS,subvol=@var_log /dev/mapper/root /mnt/var/log
mount --mkdir -o $BTRFS_OPTS,subvol=@pkg /dev/mapper/root /mnt/var/cache/pacman/pkg

mkdir -p /mnt/boot
mount "$BOOT" /mnt/boot

# ========= MICROCODE & PACKAGES =========
UCODE_PKG=""
grep -q "Intel" /proc/cpuinfo && UCODE_PKG="intel-ucode"
grep -q "AMD" /proc/cpuinfo && UCODE_PKG="amd-ucode"

pacman -Sy --noconfirm archlinux-keyring

# IMPORTANTE: añadimos dosfstools para soportar la partición boot FAT32
pacstrap -K /mnt \
    base base-devel linux linux-firmware \
    btrfs-progs cryptsetup limine $UCODE_PKG \
    dosfstools networkmanager sudo vim git \
    pipewire pipewire-alsa pipewire-pulse wireplumber \
    bluez bluez-utils firewalld acpid avahi rsync

genfstab -U /mnt >> /mnt/etc/fstab

parted --script "$DISK" set 1 boot on

# ========= CHROOT =========
LUKS_UUID=$(cryptsetup luksUUID "$ROOT")

arch-chroot /mnt /bin/bash -e <<EOF

DISK_TARGET="$DISK"
LUKS_ID="$LUKS_UUID"

# --- TIME & LOCALE ---
ln -sf /usr/share/zoneinfo/$TIMEZONE /etc/localtime
hwclock --systohc
sed -i 's/^#en_US.UTF-8 UTF-8/en_US.UTF-8 UTF-8/' /etc/locale.gen
locale-gen
echo "LANG=en_US.UTF-8" > /etc/locale.conf
echo "arch" > /etc/hostname

# --- USERS ---
echo "root:$ROOT_PASS" | chpasswd
useradd -m -G wheel -s /bin/bash "$USERNAME"
echo "$USERNAME:$USER_PASS" | chpasswd
sed -i 's/^# %wheel ALL=(ALL:ALL) ALL/%wheel ALL=(ALL:ALL) ALL/' /etc/sudoers

# --- MKINITCPIO ---
# Se requiere 'encrypt' para LUKS
sed -i 's/^HOOKS=.*/HOOKS=(base udev autodetect modconf keyboard block encrypt filesystems fsck)/' /etc/mkinitcpio.conf
mkinitcpio -P

# --- LIMINE (BIOS CONFIG) ---
mkdir -p /boot/limine
cp /usr/share/limine/limine-bios.sys /boot/limine/
cp /usr/share/limine/limine-bios.sys /boot/

cat <<LIMINECONF > /boot/limine/limine.conf
timeout: 5
/Arch Linux
    protocol: linux
    kernel_path: boot():/vmlinuz-linux
    module_path: boot():/initramfs-linux.img
    cmdline: cryptdevice=UUID=\$LUKS_ID:root root=/dev/mapper/root rootflags=subvol=@ rw
LIMINECONF

# --- INSTALL TO MBR ---
# Esto graba el cargador físicamente en el disco
limine bios-install "\$DISK_TARGET"

# --- PACMAN HOOK ---
mkdir -p /etc/pacman.d/hooks
cat <<HOOK > /etc/pacman.d/hooks/99-limine.hook
[Trigger]
Operation = Install
Operation = Upgrade
Type = Package
Target = limine

[Action]
Description = Deploying Limine after upgrade...
When = PostTransaction
# Aquí grabamos el valor real del disco directamente en el archivo
Exec = /bin/sh -c "limine bios-install \$DISK_TARGET && cp /usr/share/limine/limine-bios.sys /boot/limine/"
HOOK

# --- SERVICES ---
systemctl enable NetworkManager bluetooth avahi-daemon firewalld acpid
EOF

# ========= CLEANUP =========
sync
umount -R /mnt
cryptsetup close root

echo "=== INSTALLATION COMPLETE ==="
