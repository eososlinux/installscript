#!/usr/bin/env bash
set -euo pipefail

echo "=== Arch Linux BIOS Legacy Installer (LUKS2 + BTRFS + Limine) ==="

lsblk
echo ""

read -rp "Enter target disk (e.g. /dev/sda or /dev/nvme0n1): " DISK
read -rp "Enter username: " USERNAME
read -srp "Enter user password: " USER_PASS; echo
read -srp "Enter root password: " ROOT_PASS; echo
read -srp "Enter LUKS encryption password: " LUKS_PASS; echo

# ========= TIMEZONE =========
echo "--- Detecting timezone ---"
TIMEZONE=$(curl -fsSL https://ipapi.co/timezone || echo "UTC")
echo "Using timezone: $TIMEZONE"

# ========= PARTITIONING (MBR) =========
echo "--- Partitioning $DISK (BIOS legacy / MBR) ---"
sgdisk --zap-all "$DISK"

parted --script "$DISK" \
    mklabel msdos \
    mkpart primary ext4 1MiB 1025MiB \
    set 1 boot on \
    mkpart primary 1025MiB 100%

# NVMe vs SATA naming
if [[ "$DISK" =~ nvme ]]; then
    BOOT="${DISK}p1"
    ROOT="${DISK}p2"
else
    BOOT="${DISK}1"
    ROOT="${DISK}2"
fi

# ========= FORMAT /BOOT =========
echo "--- Formatting /boot (ext4) ---"
mkfs.ext4 -F "$BOOT"

# ========= LUKS + BTRFS =========
echo "--- Setting up LUKS2 ---"
echo -n "$LUKS_PASS" | cryptsetup luksFormat --type luks2 "$ROOT" -
echo -n "$LUKS_PASS" | cryptsetup open "$ROOT" root -

echo "--- Formatting BTRFS ---"
mkfs.btrfs /dev/mapper/root

mount /dev/mapper/root /mnt

echo "--- Creating BTRFS subvolumes ---"
for sub in @ @home @var_log @pkg; do
    btrfs subvolume create "/mnt/$sub"
done

umount /mnt

echo "--- Mounting subvolumes ---"
mount -o compress=zstd:1,noatime,subvol=@ /dev/mapper/root /mnt
mount --mkdir -o compress=zstd:1,noatime,subvol=@home /dev/mapper/root /mnt/home
mount --mkdir -o compress=zstd:1,noatime,subvol=@var_log /dev/mapper/root /mnt/var/log
mount --mkdir -o compress=zstd:1,noatime,subvol=@pkg /dev/mapper/root /mnt/var/cache

mkdir -p /mnt/boot
mount "$BOOT" /mnt/boot

# ========= BASE INSTALL =========
echo "--- Installing base system ---"
pacman -Sy --noconfirm archlinux-keyring reflector

reflector --latest 20 --protocol https --sort rate --save /etc/pacman.d/mirrorlist

pacstrap -K /mnt \
    base base-devel linux linux-firmware \
    btrfs-progs cryptsetup \
    limine \
    networkmanager sudo vim git \
    intel-ucode amd-ucode \
    pipewire pipewire-alsa pipewire-pulse wireplumber \
    bluez bluez-utils \
    firewalld acpid avahi \
    rsync bash-completion duf \
    zram-generator

genfstab -U /mnt >> /mnt/etc/fstab

# ========= CHROOT =========
arch-chroot /mnt /bin/bash <<EOF
set -e

# --- TIMEZONE ---
ln -sf /usr/share/zoneinfo/$TIMEZONE /etc/localtime
hwclock --systohc

# --- LOCALE ---
sed -i 's/^#en_US.UTF-8 UTF-8/en_US.UTF-8 UTF-8/' /etc/locale.gen
locale-gen
echo "LANG=en_US.UTF-8" > /etc/locale.conf

# --- HOSTNAME ---
echo "archlinux" > /etc/hostname
cat <<HOSTS > /etc/hosts
127.0.0.1   localhost
::1         localhost
127.0.1.1   archlinux.localdomain archlinux
HOSTS

# --- USERS ---
echo "root:$ROOT_PASS" | chpasswd
useradd -m -G wheel -s /bin/bash $USERNAME
echo "$USERNAME:$USER_PASS" | chpasswd
sed -i 's/^# %wheel ALL=(ALL:ALL) ALL/%wheel ALL=(ALL:ALL) ALL/' /etc/sudoers

# --- MKINITCPIO ---
sed -i 's/^HOOKS=.*/HOOKS=(base udev autodetect modconf block encrypt filesystems keyboard fsck)/' /etc/mkinitcpio.conf
mkinitcpio -P

# --- ZRAM ---
install -Dm644 /dev/stdin /etc/systemd/zram-generator.conf <<'ZRAMCONF'
[zram0]
zram-size = ram / 2
compression-algorithm = zstd
swap-priority = 100
ZRAMCONF

echo "vm.swappiness=180" > /etc/sysctl.d/99-zram.conf

# --- LIMINE BIOS INSTALL ---
limine-install "$DISK"

LUKS_UUID=\$(cryptsetup luksUUID "$ROOT")

cat <<LIMINECONF > /boot/limine.conf
timeout: 3

/Arch Linux
    protocol: linux
    kernel_path: boot():/vmlinuz-linux
    cmdline: quiet cryptdevice=UUID=\$LUKS_UUID:root root=/dev/mapper/root rw rootflags=subvol=@ rootfstype=btrfs
    module_path: boot():/initramfs-linux.img

/Arch Linux (fallback)
    protocol: linux
    kernel_path: boot():/vmlinuz-linux
    cmdline: quiet cryptdevice=UUID=\$LUKS_UUID:root root=/dev/mapper/root rw rootflags=subvol=@ rootfstype=btrfs
    module_path: boot():/initramfs-linux-fallback.img
LIMINECONF

# --- ENABLE SERVICES ---
for s in NetworkManager bluetooth avahi-daemon firewalld acpid reflector.timer; do
    systemctl enable \$s
done

EOF

# ========= OPTIONAL INTERACTIVE CHROOT =========
echo ""
read -rp "Enter system with arch-chroot before unmounting? [y/N]: " CHROOT_CONFIRM
if [[ "$CHROOT_CONFIRM" =~ ^[yY]$ ]]; then
    arch-chroot /mnt
fi

# ========= CLEANUP =========
echo "--- Final cleanup ---"
sync
umount -R /mnt
cryptsetup close root

echo "=== INSTALLATION COMPLETE ==="
echo "Remove installation media and reboot."
