#!/usr/bin/env python3

from archinstall import guided
from archinstall import filesystem
from archinstall import misc

# -------- USER INPUT --------
disk = input("Enter target disk (e.g. /dev/nvme0n1): ")
username = input("Enter username: ")
user_pass = input("Enter user password: ")
root_pass = input("Enter root password: ")
luks_pass = input("Enter LUKS password: ")

# -------- GEOLOCATION / TIMEZONE --------
import requests
try:
    timezone = requests.get("https://ipapi.co/timezone").text.strip()
except:
    timezone = "UTC"

print(f"Using timezone: {timezone}")

# -------- CONFIGURATION --------
# Guided installation object
guide = guided.Guide(
    disk=disk,
    filesystem="btrfs",
    encrypt=True,
    luks_pass=luks_pass,
    root_password=root_pass,
    username=username,
    user_password=user_pass,
    hostname="arch",
    locale="en_US.UTF-8",
    keymap="us",
    timezone=timezone,
    subvolumes=["@", "@home", "@var_log", "@pkg"],
    desktop=None,       # puedes agregar "hyprland" si quieres instalar DE
    packages=[
        "base", "base-devel", "linux", "linux-firmware", "btrfs-progs", 
        "efibootmgr", "limine", "cryptsetup", "networkmanager", "sudo", 
        "vim", "intel-ucode", "dhcpcd", "iwd", "firewalld", "bluez", "bluez-utils", 
        "acpid", "avahi", "rsync", "bash-completion", "pipewire", "pipewire-alsa",
        "pipewire-pulse", "wireplumber", "sof-firmware", "git", "duf"
    ]
)

# -------- RUN THE INSTALLATION --------
guide.run()

# -------- POST INSTALL --------
# Limine setup is not fully wrapped in archinstall API,
# se podría hacer con misc.run() para ejecutar comandos de shell
limine_cmds = f"""
mkdir -p /mnt/boot/EFI/limine
cp /usr/share/limine/BOOTX64.EFI /mnt/boot/EFI/limine/
efibootmgr --create --disk {disk} --part 1 \\
    --label "Arch Linux Limine Bootloader" \\
    --loader '\\EFI\\limine\\BOOTX64.EFI' --unicode
"""
misc.run(limine_cmds)