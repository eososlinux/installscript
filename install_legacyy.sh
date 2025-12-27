#!/usr/bin/env bash
set -euo pipefail

# ==============================================================================
# Arch Linux BIOS Legacy Installer (LUKS2 + BTRFS + Limine)
# Archinstall-compatible
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
    mkpart primary fat32 1MiB 2048MiB \
    set 1 boot on \
    mkpart primary 2048MiB 100%

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

# ========= MICROCODE =========
UCODE_PKG=""
if grep -q "Intel" /proc/cpuinfo; then
    UCODE_PKG="intel-ucode"
elif grep -q "AMD" /proc/cpuinfo; then
    UCODE_PKG="amd-ucode"
fi

# ========= BASE SYSTEM =========
pacman -Sy --noconfirm archlinux-keyring

pacstrap -K /mnt \
    base base-devel linux linux-firmware \
    btrfs-progs cryptsetup limine $UCODE_PKG \
    networkmanager sudo vim git \
    pipewire pipewire-alsa pipewire-pulse wireplumber \
    bluez bluez-utils firewalld acpid avahi rsync

genfstab -U /mnt >> /mnt/etc/fstab

# ========= CHROOT =========
LUKS_UUID=$(cryptsetup luksUUID "$ROOT")

arch-chroot /mnt /bin/bash -e <<EOF
# --- TIME ---
ln -sf /usr/share/zoneinfo/$TIMEZONE /etc/localtime
hwclock --systohc

# --- LOCALE ---
sed -i 's/^#en_US.UTF-8 UTF-8/en_US.UTF-8 UTF-8/' /etc/locale.gen
locale-gen
echo "LANG=en_US.UTF-8" > /etc/locale.conf

# --- HOST ---
echo "arch" > /etc/hostname

# --- USERS ---
echo "root:$ROOT_PASS" | chpasswd
useradd -m -G wheel -s /bin/bash "$USERNAME"
echo "$USERNAME:$USER_PASS" | chpasswd
sed -i 's/^# %wheel ALL=(ALL:ALL) ALL/%wheel ALL=(ALL:ALL) ALL/' /etc/sudoers

# --- MKINITCPIO ---
sed -i 's/^HOOKS=.*/HOOKS=(base udev autodetect modconf keyboard block encrypt filesystems fsck)/' /etc/mkinitcpio.conf
mkinitcpio -P

# --- LIMINE (BIOS) ---
mkdir -p /boot/limine

cp /usr/share/limine/limine-bios.sys /boot/limine/

cat <<LIMINECONF > /boot/limine/limine.conf
timeout: 5

/Arch Linux (linux)
    protocol: linux
    path: boot():/vmlinuz-linux
    cmdline: quiet cryptdevice=PARTUUID=$LUKS_UUID:root root=/dev/mapper/root rootflags=subvol=@ rw rootfstype=btrfs
LIMINECONF

# --- INSTALL BOOTLOADER ---
# limine bios-install "$DISK"

# --- PACMAN HOOK (ARCHINSTALL STYLE) ---
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
Exec = /bin/sh -c "limine bios-install $DISK && cp /usr/share/limine/limine-bios.sys /boot/limine/"
HOOK

# --- SERVICES ---
for s in NetworkManager bluetooth avahi-daemon firewalld acpid; do
    systemctl enable \$s
done
EOF


# ========= CLEANUP =========
sync
umount -R /mnt
cryptsetup close root

echo "=== INSTALLATION COMPLETE ==="
echo "Remove installation media and reboot."
