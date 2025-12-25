# Bash Script to Install Arch Linux

# Clone this repository
credits https://github.com/nightdevil00

```bash
git clone https://github.com/eososlinux/installscript.git
cd /installscript
chmod +x install.sh
sh install.sh

Disk Configuration

NVMe Drives
If you are using an NVMe drive, use the following configuration:
# ESP="${DISK}p1"
# ROOT="${DISK}p2"

SATA / SSD / HDD Drives
If you are NOT using an NVMe drive, comment the NVMe lines and use:
ESP="${DISK}1"
ROOT="${DISK}2"

Restart and remove the USB drive

Check internet connection

Omarchy Installation

curl -fsSL https://omarchy.org/install | bash

https://learn.omacom.io/2/the-omarchy-manual/96/manual-installation

Total installation time: 1:40 minutes





