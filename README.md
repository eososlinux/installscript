# installscript

# bash script to install arch linux installation

# Clone this repository

```bash
git clone <repository_url>
cd /installscript
chmod +x install.sh
sh install.sh

NVMe Drives

If you have an NVMe drive, uncomment the following lines and it should look like this:
# ESP="${DISK}p1"
# ROOT="${DISK}p2"

Please comment if it has an NVMe drive
ESP="${DISK}1"
ROOT="${DISK}2"

Restart and remove the USB drive

Check internet connection

Omarchy Installation

curl -fsSL https://omarchy.org/install | bash

https://learn.omacom.io/2/the-omarchy-manual/96/manual-installation

Total installation time: 1:40 minutes



