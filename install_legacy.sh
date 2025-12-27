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

if [[ "$DISK" =~ nvme ]]; then
    BOOT="${DISK}p1"
    ROOT="${DISK}p2"
else
    BOOT="${DISK}1"
    ROOT="${DISK}2"
fi

# ========= FORMAT /BOOT =========
mkfs.ext4 -F "$BOOT"

# ========= LUKS + BTRFS =========
echo -n "$LUKS_PASS" | cryptsetup luksFormat --type luks2 "$ROOT" -
echo -n "$LUKS_PASS" | cryptsetup open "$ROOT" root -

mkfs.btrfs /dev/mapper/root
mount /dev/mapper/root /mnt

for sub in @ @home @var_log @pkg; do
    btrfs subvolume create "/mnt/$sub"
done

umount /mnt

mount -o compress=zstd:1,noatime,subvol=@ /dev/mapper/root /mnt
mount --mkdir -o compress=zstd:1,noatime,subvol=@home /dev/mapper/root /mnt/home
mount --mkdir -o compress=zstd:1,noatime,subvol=@var_log /dev/mapper/root /mnt/var/log
mount --mkdir -o compress=zstd:1,noatime,subvol=@pkg /dev/mapper/root /mnt/var/cache/pacman/pkg

mkdir -p /mnt/boot
mount "$BOOT" /mnt/boot

# ========= BASE INSTALL =========
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

# ========= CHROOT CONFIGURATION =========
export TIMEZONE ROOT_PASS USERNAME USER_PASS

arch-chroot /mnt /bin/bash -e <<EOF
# --- TIMEZONE ---
ln -sf "/usr/share/zoneinfo/$TIMEZONE" /etc/localtime
hwclock --systohc

sed -i 's/^#en_US.UTF-8 UTF-8/en_US.UTF-8 UTF-8/' /etc/locale.gen
locale-gen
echo "LANG=en_US.UTF-8" > /etc/locale.conf

echo "arch" > /etc/hostname
cat <<HOSTS > /etc/hosts
127.0.0.1 localhost
::1       localhost
127.0.1.1 arch.localdomain arch
HOSTS

echo "KEYMAP=us" > /etc/vconsole.conf

echo "root:$ROOT_PASS" | chpasswd
useradd -m -G wheel -s /bin/bash "$USERNAME"
echo "$USERNAME:$USER_PASS" | chpasswd
sed -i 's/^# %wheel ALL=(ALL:ALL) ALL/%wheel ALL=(ALL:ALL) ALL/' /etc/sudoers

# --- MKINITCPIO (NO MODIFICADO) ---
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

# --- LIMINE BIOS FILES ---
mkdir -p /boot/limine
cp /usr/share/limine/limine-bios.sys /boot/limine/

LUKS_UUID=$(cryptsetup luksUUID /dev/mapper/root)

cat <<LIMINECONF > /boot/limine.conf
timeout: 3

/Arch Linux
    protocol: linux
    kernel_path: boot():/vmlinuz-linux
    cmdline: cryptdevice=UUID=$LUKS_UUID:root root=/dev/mapper/root rw rootflags=subvol=@
    module_path: boot():/initramfs-linux.img

/Arch Linux (fallback)
    protocol: linux
    kernel_path: boot():/vmlinuz-linux
    cmdline: cryptdevice=UUID=$LUKS_UUID:root root=/dev/mapper/root rw rootflags=subvol=@
    module_path: boot():/initramfs-linux-fallback.img
LIMINECONF

for s in NetworkManager bluetooth avahi-daemon firewalld acpid reflector.timer; do
    systemctl enable "$s"
done
EOF

# ========= LIMINE BIOS INSTALL =========
limine bios-install "$DISK"

echo ""
read -rp "Do you want to enter the system via arch-chroot before unmounting? [y/N]: " CHROOT_CONFIRM

case "${CHROOT_CONFIRM,,}" in
    y|yes)
        echo "Entering interactive chroot. Type 'exit' to continue installation cleanup."
        arch-chroot /mnt
        ;;
    *)
        echo "Skipping interactive chroot."
        ;;
esac

# ========= CLEANUP =========
sync
umount -R /mnt
cryptsetup close root

echo "=== INSTALLATION COMPLETE ==="
echo "Remove installation media and reboot."

