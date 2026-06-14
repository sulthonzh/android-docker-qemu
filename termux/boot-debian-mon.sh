#!/data/data/com.termux/files/usr/bin/bash
# boot-debian-mon.sh — Boot Debian 12 arm64 QEMU VM inside Termux
#
# Installs/runs on: the PHONE, inside Termux (NOT inside the VM).
# Place at: ~/boot-debian-mon.sh
#
# This is the VM launcher. It starts QEMU with monitor and serial sockets
# exposed for management, and forwards host ports 2222→22 (SSH), 8080→80,
# and 9000→9000 into the VM.
#
# Source: https://github.com/sulthonzh/android-docker-qemu
# Full tutorial: https://dev.to/sulthonzh/run-real-docker-on-android-no-root-no-tricks-just-qemu-15jn

set +e

VM_DIR="/data/data/com.termux/files/home/qemu-vm"
CODE="/data/data/com.termux/files/usr/share/qemu/edk2-aarch64-code.fd"
VARS="$VM_DIR/edk2-vars.fd"
IMG="$VM_DIR/debian-12-arm64.qcow2"
SEED="$VM_DIR/seed.iso"
MONSOCK="$VM_DIR/mon.sock"
SERIALSOCK="$VM_DIR/serial.sock"
LOG="$VM_DIR/debian-boot.log"

# Kill any prior QEMU instance (clean restart)
pkill -9 -f qemu-system-aarch64 2>/dev/null
sleep 2
rm -f $MONSOCK $SERIALSOCK

# Launch QEMU detached via setsid so it survives SSH disconnect.
# TCG (software emulation) is slow but it's the only no-root option.
setsid qemu-system-aarch64 \
  -name docker-phone \
  -machine virt,gic-version=3 \
  -cpu max,aarch64=on,pmu=on \
  -smp 6 \
  -m 6144 \
  -accel tcg,thread=multi,tb-size=512 \
  -nodefaults \
  -chardev socket,id=mon0,path=$MONSOCK,server=on,wait=off \
  -mon chardev=mon0,mode=readline \
  -chardev socket,id=ser0,path=$SERIALSOCK,server=on,wait=off,logfile=$LOG \
  -serial chardev:ser0 \
  -display none \
  -drive if=pflash,format=raw,readonly=on,file=$CODE \
  -drive if=pflash,format=raw,file=$VARS \
  -drive file=$IMG,if=virtio,format=qcow2,cache=writeback \
  -drive file=$SEED,if=virtio,format=raw,readonly=on \
  -netdev user,id=net0,hostfwd=tcp::2222-:22,hostfwd=tcp::8080-:80,hostfwd=tcp::9000-:9000 \
  -device virtio-net-pci,netdev=net0 \
  -device virtio-rng-pci \
  -rtc base=utc \
  > $LOG 2>&1 &

disown
sleep 3
echo "QEMU PID: $(pgrep -f qemu-system-aarch64 | head -1)"
echo "Monitor socket: $MONSOCK"
echo "Serial socket: $SERIALSOCK"
echo "Log: $LOG"
