#!/usr/bin/env python3

from archinstall import Installer
from archinstall import settings
from archinstall import misc
import getpass
import requests

# ================= USER INPUT =================
disk = input("Enter target disk (e.g. /dev/nvme0n1): ")
username = input("Enter username: ")
user_pass = getpass.getpass("Enter user password: ")
root_pass = getpass.getpass("Enter root password: ")
luks_pass = getpass.getpass("Enter LUKS password: ")

# ================= TIMEZONE =================
try:
    timezone = requests.get("https://ipapi.co/timezone").text.strip()
except:
    timezone = "UTC"
print(f"Using timezone: {timezone}")

# ================= DISK PARTITIONS =================
if "nvme" in disk:
    boot_part = f"{disk}p1"
    root_part = f"{disk}p2"
else:
    boot_part = f"{disk}1"
    root_part = f"{disk}2"

# ================= SETTINGS =================
cfg = settings.Settings()
cfg.disks = [disk]
cfg.encrypt = True
cfg.luks_pass = luks_pass
cfg.root_password = root_pass
cfg.username = username
cfg.user_password = user_pass
cfg.filesystem = "btrfs"
cfg.subvolumes = ["@", "@home", "@var_log", "@pkg"]
cfg.hostname = "arch"
cfg.locale = "en_US.UTF-8"
cfg.keymap = "us"
cfg.timezone = timezone
cfg.packages = [
    "base", "base-devel", "linux", "linux-firmware", "btrfs-progs",
    "efibootmgr", "limine", "cryptsetup", "networkmanager", "sudo",
    "vim", "intel-ucode", "dhcpcd", "iwd", "firewalld", "bluez", "bluez-utils",
    "acpid", "avahi", "rsync", "bash-completion", "pipewire", "pipewire-alsa",
    "pipewire-pulse", "wireplumber", "sof-firmware", "git", "duf"
]

# ================= INSTALLER =================
installer = Installer(cfg)

# Ejecuta instalación automática
installer.install()

# ================= POST-INSTALL: LIMINE =================
limine_cmds = f"""
mkdir -p /mnt/boot/EFI/limine
cp /usr/share/limine/BOOTX64.EFI /mnt/boot/EFI/limine/
efibootmgr --create --disk {disk} --part 1 \\
    --label "Arch Linux Limine Bootloader" \\
    --loader '\\EFI\\limine\\BOOTX64.EFI' --unicode
LUKS_UUID=$(cryptsetup luksUUID {root_part})
cat <<EOF > /mnt/boot/EFI/limine/limine.conf
timeout: 3

/Arch Linux
    protocol: linux
    path: boot():/vmlinuz-linux
    cmdline: quiet cryptdevice=UUID=\$LUKS_UUID:root root=/dev/mapper/root rw rootflags=subvol=@ rootfstype=btrfs
    module_path: boot():/initramfs-linux.img

/Arch Linux (fallback)
    protocol: linux
    path: boot():/vmlinuz-linux
    cmdline: quiet cryptdevice=UUID=\$LUKS_UUID:root root=/dev/mapper/root rw rootflags=subvol=@ rootfstype=btrfs
    module_path: boot():/initramfs-linux-fallback.img
EOF
"""

misc.run(limine_cmds)
