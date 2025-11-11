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
from libcalamares.utils import target_env_call # type: ignore
from typing import cast


class ConfigController:
    def __init__(self):
        # Forzar tipo para que Pylance no se queje (libcalamares es dinámico)
        self.__root: str = cast(str, libcalamares.globalstorage.value("rootMountPoint"))  # type: ignore
        self.__keyrings: list[str] = cast(list[str], libcalamares.job.configuration.get('keyrings', []))  # type: ignore

    @property
    def root(self) -> str:
        return self.__root

    @property
    def keyrings(self) -> list[str]:
        return self.__keyrings

    def init_keyring(self) -> None:
        libcalamares.utils.target_env_call(["pacman-key", "--init"]) # type: ignore

    def populate_keyring(self) -> None:
        libcalamares.utils.target_env_call(["pacman-key", "--populate"]) # type: ignore

    def terminate(self, proc: str) -> None:
        libcalamares.utils.target_env_call(['killall', '-9', proc]) # type: ignore

    def remove_pkg(self, pkg: str, path: str):
        full_path = join(self.root, path)
        if exists(full_path):
            print(f"[postcfg] Eliminando {pkg} porque existe {path}")
            target_env_call(["pacman", "-Rns", "--noconfirm", pkg])

    def copy_file(self, file: str) -> None:
        source_path = "/" + file
        target_path = join(self.root, file)
        if exists(source_path):
            copy2(source_path, target_path)

    def copy_folder(self, source: str, target: str) -> None:
        source_path = "/" + source
        target_path = join(self.root, target)
        if exists(source_path):
            copytree(source_path, target_path, dirs_exist_ok=True)

    def umount(self, mp: str) -> None:
        subprocess.call(["umount", "-l", join(self.root, mp)])

    def mount(self, mp: str) -> None:
        subprocess.call(["mount", "-B", "/" + mp, join(self.root, mp)])

    def rmdir(self, path: str) -> None:
        subprocess.call(["rm", "-Rf", join(self.root, path)])

    def mkdir(self, path: str) -> None:
        subprocess.call(["mkdir", "-p", join(self.root, path)])

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

    # def handle_ucode(self):
    #     # Remove unneeded ucode
    #     cpu_ucode = subprocess.getoutput("hwinfo --cpu | grep Vendor: -m1 | cut -d\'\"\' -f2")
    #     if cpu_ucode == "AuthenticAMD":
    #         self.remove_pkg("intel-ucode", "boot/intel-ucode.img")
    #     elif cpu_ucode == "GenuineIntel":
    #         self.remove_pkg("amd-ucode", "boot/amd-ucode.img")
    #     else:
    #         target_env_call(["mkinitcpio", "-P"])

    def setup_snapper(self):
        snapper_bin = join(self.root, "usr/bin/snapper")

        if not exists(snapper_bin):
            print("[postcfg] Snapper no está instalado, saltando...")
            return

        print("[postcfg] Configurando Snapper para /")

        # 1. Crear configuración de Snapper (esto también genera .snapshots si el root es subvol Btrfs)
        target_env_call(["snapper", "--no-dbus", "-c", "root", "create-config", "/"])

        # 2. Asegurar que el subvolumen /.snapshots existe
        snapshots_path = join(self.root, ".snapshots")
        if not exists(snapshots_path):
            print("[postcfg] Creando subvolumen Btrfs /.snapshots")
            target_env_call(["btrfs", "subvolume", "create", "/.snapshots"])

        # 3. Ajustar permisos
        target_env_call(["chown", "-R", ":wheel", "/.snapshots"])
        # target_env_call(["chmod", "750", "/.snapshots"])

        # 4. Activar servicios (sin --now para evitar fallos en chroot)
        target_env_call(["systemctl", "enable", "grub-btrfsd"])
        target_env_call(["systemctl", "enable", "snapper-timeline.timer"])
        target_env_call(["systemctl", "enable", "snapper-cleanup.timer"])

        print("[postcfg] Snapper configurado correctamente.")

        # 5. Regenerar grub para agregar snapshots al menú
        target_env_call(["grub-mkconfig", "-o", "/boot/grub/grub.cfg"])



    def run(self) -> None:
        self.init_keyring()
        self.populate_keyring()

        # Actualizar base de datos si hay internet
        if libcalamares.globalstorage.value("hasInternet"): # type: ignore
            libcalamares.utils.target_env_call(["pacman", "-Sy", "--noconfirm"]) # type: ignore

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

        # Activar menú oculto automático en grub si soportado
        if exists(join(self.root, "usr/bin/grub-set-bootflag")):
            libcalamares.utils.target_env_call([ # type: ignore
                "grub-editenv", "-", "set", "menu_auto_hide=1", "boot_success=1"
            ])

        # Parche temporal con dd para evitar bugs en grub
        if exists(join(self.root, "usr/bin/dd")):
            libcalamares.utils.target_env_call([ # type: ignore
                "sh", "-c",
                "mkdir -p /tmp/vmlinuz-hack && mv /boot/vmlinuz-* /tmp/vmlinuz-hack/ && "
                "find /tmp/vmlinuz-hack/ -maxdepth 1 -type f -exec sh -c 'dd if=\"$1\" of=\"/boot/$(basename \"$1\")\"' sh {} \\;"
            ])

        # Aquí podés agregar más acciones si necesitás

        # Nueva acción: marcar huérfanos como explícitos
        self.mark_orphans_as_explicit()

        # Eliminar microcode innecesario
        # self.handle_ucode()

        # Configurar Snapper si existe
        self.setup_snapper()

        return None


def run() -> None:
    """ Misc postinstall configurations """
    config = ConfigController()
    return config.run()
