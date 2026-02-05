# Guía de Instalación Dual Boot - Arch Linux

## 1. Iniciar ISO en vivo de Arch Linux

Inicia desde un USB booteable con la ISO de Arch Linux.

## 2. Conectarse a Internet con iwdctl

Para redes WiFi, usa `iwdctl` (reemplaza `wlan0` y `"MiWiFi_5G"` según tu configuración):

```bash
# Escanear redes disponibles
iwctl station wlan0 scan

# Listar redes encontradas
iwctl station wlan0 get-networks

# Conectar a la red (ejemplo: "MiWiFi_5G")
iwctl station wlan0 connect "MiWiFi_5G"

# Ingresar contraseña cuando se solicite
# Después de conectar, verificar conexión
ping -c 3 8.8.8.8
```

## 3. Identificar el disco

```bash
lsblk -f
```

## 4. Particionar el disco

```bash
cfdisk /dev/sda
```

**Recomendación de particiones en espacio libre (ej: 100GB):**
- **2GB** - para el bootloader Limine (FAT32)
- **Resto** - para el sistema root (Btrfs)

## 5. Formatear y crear subvolúmenes

```bash
# Formatear partición boot (FAT32)
mkfs.fat -F 32 /dev/sda5

# Formatear partición root (Btrfs)
mkfs.btrfs /dev/sda6

# Montar temporalmente para crear subvolúmenes
mount /dev/sda6 /mnt

# Crear subvolúmenes Btrfs
btrfs subvolume create /mnt/@
btrfs subvolume create /mnt/@home
btrfs subvolume create /mnt/@pkg
btrfs subvolume create /mnt/@log

# Desmontar
umount /mnt
```

## 6. Montar subvolúmenes

```bash
# Montar subvolumen root
mount -o compress=zstd:1,noatime,subvol=@ /dev/sda6 /mnt

# Montar subvolúmenes adicionales
mount --mkdir -o compress=zstd:1,noatime,subvol=@home /dev/sda6 /mnt/home
mount --mkdir -o compress=zstd:1,noatime,subvol=@log /dev/sda6 /mnt/var/log
mount --mkdir -o compress=zstd:1,noatime,subvol=@pkg /dev/sda6 /mnt/var/cache/pacman/pkg

# Montar partición boot
mount --mkdir /dev/sda5 /mnt/boot
```

## 7. Ejecutar archinstall

```bash
archinstall
```

**Importante:** En la configuración de disco, selecciona la opción de montaje `/mnt` (ya montado manualmente).

## 8. Post-instalación

1. **Salir de chroot**
2. **Reiniciar el sistema**
3. Se iniciará la pantalla de Limine
4. Selecciona Arch Linux, ingresa usuario y contraseña
5. **Verifica la conexión a internet**

## 9. Instalar Omarchy

```bash
curl -fsSL https://omarchy.org/install | bash
```

## 10. Configurar bootloader

```bash
sudo limine-scan
```

---

### ⚠️ Notas Importantes

- Reemplaza `/dev/sda5` y `/dev/sda6` con los nombres de tus particiones reales
- Ajusta los tamaños de partición según tus necesidades
- Para redes Ethernet, la conexión debería ser automática
- El comando `limine-scan` detectará automáticamente Windows y lo agregará al menú de arranque

### 🎯 ¡Buena suerte con tu instalación!

Esta guía te ayudará a tener un sistema Arch Linux funcional junto con Windows en configuración dual boot.
