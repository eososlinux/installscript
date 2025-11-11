#!/usr/bin/env python3
# -*- coding: utf-8 -*-
#
# === This file is part of Calamares - <http://github.com/calamares> ===
#
#   Copyright 2014 - 2019, Philip Müller <philm@manjaro.org>
#   Copyright 2016, Artoo <artoo@manjaro.org>
#
#   Calamares is free software: you can redistribute it and/or modify
#   it under the terms of the GNU General Public License as published by
#   the Free Software Foundation, either version 3 of the License, or
#   (at your option) any later version.
#
#   Calamares is distributed in the hope that it will be useful,
#   but WITHOUT ANY WARRANTY; without even the implied warranty of
#   MERCHANTABILITY or FITNESS FOR A PARTICULAR PURPOSE. See the
#   GNU General Public License for more details.
#
#   You should have received a copy of the GNU General Public License
#   along with Calamares. If not, see <http://www.gnu.org/licenses/>.
#   new branch

import libcalamares
import subprocess

from shutil import copy2, copytree
from os.path import join, exists
from os import rename, makedirs
from libcalamares.utils import target_env_call, target_env_process_output


class ConfigController:
    def __init__(self):
        self.__root = libcalamares.globalstorage.value("rootMountPoint")
        self.__keyrings = libcalamares.job.configuration.get('keyrings', [])

    @property
    def root(self):
        return self.__root

    @property
    def keyrings(self):
        return self.__keyrings

    def init_keyring(self):
        target_env_call(["pacman-key", "--init"])

    def populate_keyring(self):
        target_env_call(["pacman-key", "--populate"])

    def terminate(self, proc):
        target_env_call(['killall', '-9', proc])

    def copy_file(self, file):
        if exists("/" + file):
            copy2("/" + file, join(self.root, file))

    def copy_folder(self, source, target):
        if exists("/" + source):
            copytree("/" + source, join(self.root, target), symlinks=True, dirs_exist_ok=True)

    def remove_pkg(self, pkg, path):
        if exists(join(self.root, path)):
            target_env_call(['pacman', '-R', '--noconfirm', pkg])

    def umount(self, mp):
        subprocess.call(["umount", "-l", join(self.root, mp)])

    def mount(self, mp):
        subprocess.call(["mount", "-B", "/" + mp, join(self.root, mp)])

    def rmdir(self, dir):
        subprocess.call(["rm", "-Rf", join(self.root, dir)])

    def mkdir(self, dir):
        subprocess.call(["mkdir", "-p", join(self.root, dir)])

    def find_xdg_directory(self, user, type):
        output = []
        target_env_process_output(["su", "-lT", user, "xdg-user-dir", type], output)
        return output[0].strip()

    def mark_orphans_as_explicit(self) -> None:
        """
        Marca todos los paquetes que pacman considera 'huérfanos' como explícitos.
        Esto es necesario porque en el live ISO (airootfs) normalmente todos los
        paquetes se marcan como dependencias (--asdeps), lo que provoca que tras
        instalar, 'pacman -Qdtq' liste incluso el entorno gráfico completo.

        Comando usado:
            pacman -Qdtq | pacman -D --asexplicit -
        """
        libcalamares.utils.debug("Marcando paquetes huérfanos como explícitos en el sistema instalado...")
        libcalamares.utils.target_env_call([
            "sh", "-c",
            "orphans=$(pacman -Qdtq); "
            "if [ -n \"$orphans\" ]; then pacman -D --asexplicit $orphans; fi"
        ])
        libcalamares.utils.debug("Marcado de paquetes completado.")

    def setup_snapper(self):
        snapper_bin = join(self.root, "usr/bin/snapper")

        if not exists(snapper_bin):
            print("[postcfg] Snapper no está instalado, saltando...")
            return

        print("[postcfg] Configurando Snapper para /")

        # 1. Crear configuración solo si no existe
        snapper_cfg = join(self.root, "etc/snapper/configs/root")
        if not exists(snapper_cfg):
            print("[postcfg] Creando configuración de Snapper...")
            target_env_call(["snapper", "--no-dbus", "-c", "root", "create-config", "/"])
        else:
            print("[postcfg] Configuracion de Snapper ya existe, se reutiliza.")

        # 2. Verificar que /.snapshots existe (no lo crea)
        snapshots_path = join(self.root, ".snapshots")
        if not exists(snapshots_path):
            print("[postcfg] ERROR: /.snapshots no existe y debería haber sido creado por mount.conf")
        else:
            print("[postcfg] /.snapshots detectado correctamente")

        # 3. Ajustar permisos (recomendado para uso sin root)
        target_env_call(["chown", "-R", ":wheel", "/.snapshots"])

        # 4. Activar servicios/timers de Snapper y grub-btrfs
        target_env_call(["systemctl", "enable", "grub-btrfsd"])
        target_env_call(["systemctl", "enable", "snapper-timeline.timer"])
        target_env_call(["systemctl", "enable", "snapper-cleanup.timer"])

        print("[postcfg] Snapper configurado correctamente.")

        # 5. Generar grub.cfg dentro del sistema instalado
        if exists(join(self.root, "usr/bin/grub-mkconfig")):
            print("[postcfg] Generando grub.cfg ...")
            target_env_call(["grub-mkconfig", "-o", "/boot/grub/grub.cfg"])


    def run(self) -> None:
        self.init_keyring()
        self.populate_keyring()

        # Remove unneeded ucode
        cpu_ucode = subprocess.getoutput("hwinfo --cpu | awk -F'\"' '/Vendor:/ {print $2; exit}'")
        if cpu_ucode == "AuthenticAMD":
            self.remove_pkg("intel-ucode", "boot/intel-ucode.img")
        elif cpu_ucode == "GenuineIntel":
            self.remove_pkg("amd-ucode", "boot/amd-ucode.img")
        else:
            # Since no microcode packages were removed, dracut needs to be manually triggered
            target_env_call(["mkinitcpio", "-P"])

        # Workaround for pacman-key bug
        # FS#45351 https://bugs.archlinux.org/task/45351
        # We have to kill gpg-agent because if it stays
        # around we can't reliably unmount
        # the target partition.
        # Terminar proceso gpg-agent para evitar bloqueo de desmontaje
        self.terminate('gpg-agent')

        # Actualizar grub.cfg si existe
        if exists(join(self.root, "usr/bin/update-grub")):
            libcalamares.utils.target_env_call(["update-grub"]) # type: ignore

        # Parche temporal con dd para evitar bugs en grub
        # if exists(join(self.root, "usr/bin/dd")):
        #    libcalamares.utils.target_env_call([ # type: ignore
        #        "sh", "-c",
        #        "mkdir -p /tmp/vmlinuz-hack && mv /boot/vmlinuz-* /tmp/vmlinuz-hack/ && "
        #        "find /tmp/vmlinuz-hack/ -maxdepth 1 -type f -exec sh -c 'dd if=\"$1\" of=\"/boot/$(basename \"$1\")\"' sh {} \\;"
        #    ])

        # Nueva acción: marcar huérfanos como explícitos
        self.mark_orphans_as_explicit()

        # Configurar Snapper si existe
        self.setup_snapper()

        return None


def run():
    """ Misc postinstall configurations """

    config = ConfigController()

    return config.run()
