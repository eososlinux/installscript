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
        Mark all packages that pacman considers 'orphaned' as explicit.

        This is necessary because in the live ISO (airotfs),
        normally all packages are marked as dependencies (--asdeps),
        which causes 'pacman -Qdtq' to list even the entire graphical environment after installation.

        Comando usado:
            pacman -Qdtq | pacman -D --asexplicit -
        """
        libcalamares.utils.debug("Marking orphaned packages as explicit in the installed system...")
        libcalamares.utils.target_env_call([
            "sh", "-c",
            "orphans=$(pacman -Qdtq); "
            "if [ -n \"$orphans\" ]; then pacman -D --asexplicit $orphans; fi"
        ])
        libcalamares.utils.debug("Package marking completed.")

    def setup_snapper(self):
        snapper_bin = join(self.root, "usr/bin/snapper")

        if not exists(snapper_bin):
             print("[postcfg] Snapper no está instalado, saltando...")
             return

        print("[postcfg] Configurando Snapper para /")

        snapshots_path = join(self.root, ".snapshots")
        snapper_cfg = join(self.root, "etc/snapper/configs/root")
        fstab_path = join(self.root, "etc/fstab")

        #  /.snapshots está montado, desmontar
        print("[postcfg] Desmontando /.snapshots si está montado...")
        target_env_call(["umount", "-q", "/.snapshots"])

        # existe como subvolumen, eliminarlo (solo si vacío)
        if exists(snapshots_path):
            print("[postcfg] Eliminando subvolumen /.snapshots existente...")
            target_env_call(["btrfs", "subvolume", "delete", "/.snapshots"])

        # Crear nueva configuración
        print("[postcfg] Creando configuración nueva de Snapper para / ...")
        target_env_call(["snapper", "--no-dbus", "-c", "root", "create-config", "/"])

        # Montar nuevamente /.snapshots (según fstab)
        print("[postcfg] Montando /.snapshots ...")
        target_env_call(["mount", "-a"])

        # Establecer subvolumen por defecto (opcional pero recomendado)
        print("[postcfg] Estableciendo subvolumen por defecto ...")
        target_env_call(["bash", "-c", "btrfs subvolume set-default $(btrfs subvolume list / | awk '/@/ {print $2; exit}') /"])

        # Ajustar permisos
        print("[postcfg] Ajustando permisos de /.snapshots ...")
        target_env_call(["chown", "-R", ":wheel", "/.snapshots"])

        # Añadir grupo wheel a la config de Snapper
        if exists(snapper_cfg):
            print("[postcfg] Añadiendo grupo wheel a la configuración de Snapper ...")
            target_env_call([
                "bash", "-c",
                "sed -i 's/^ALLOW_GROUPS=\".*\"/ALLOW_GROUPS=\"wheel\"/' /etc/snapper/configs/root"
           ])
        else:
           print("[postcfg] ERROR: configuración de Snapper no encontrada en /etc/snapper/configs/root")

        # Activar timers y servicios
        print("[postcfg] Activando servicios Snapper ...")
        target_env_call(["systemctl", "enable", "grub-btrfsd"])
        target_env_call(["systemctl", "enable", "snapper-timeline.timer"])
        target_env_call(["systemctl", "enable", "snapper-cleanup.timer"])

        # Regenerar grub.cfg
        if exists(join(self.root, "usr/bin/grub-mkconfig")):
            print("[postcfg] Regenerando grub.cfg ...")
            target_env_call(["grub-mkconfig", "-o", "/boot/grub/grub.cfg"])

        print("[postcfg] Snapper configurado correctamente.")


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

        # Nueva acción: marcar huérfanos como explícitos
        self.mark_orphans_as_explicit()

        # Configurar Snapper si existe
        self.setup_snapper()

        return None


def run():
    """ Misc postinstall configurations """

    config = ConfigController()

    return config.run()

