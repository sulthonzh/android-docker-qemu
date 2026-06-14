#!/data/data/com.termux/files/usr/bin/bash
# 01-start-vm.sh — Termux:Boot auto-start script
#
# Installs on: the PHONE, at ~/.termux/boot/01-start-vm.sh
# Requires: Termux:Boot app (install from F-Droid, open it once to register)
#
# This runs automatically when the phone finishes booting. It acquires a
# wake lock (so Android doesn't kill QEMU in the background), kills any
# stale QEMU process, then launches the VM.

sleep 15                          # let Android settle after boot
termux-wake-lock 2>/dev/null      # prevent Android doze from killing QEMU
pkill -9 -f qemu-system-aarch64 2>/dev/null
sleep 2
bash ~/boot-debian-mon.sh
