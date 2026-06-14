# Troubleshooting — the 5 things most likely to break

This is the compact reference. For the full playbook with every failure mode we hit and how we solved it, see [PLAYBOOK.md](../PLAYBOOK.md) §9.5.

---

### 1. "Cannot connect to the Docker daemon" / SSH timeout / "command exited with status 255"

**Most common cause** — your computer and the phone aren't on the same network. Verify Layer-2/3 reachability first:

```bash
# 1. Ping the phone (Mac/Linux)
ping -c 3 <PHONE_IP>
# If 100% packet loss → network problem, not Docker

# 2. If ping works, test the SSH port
nc -zv <PHONE_IP> 2222
# If "Connection refused" or timeout → QEMU died, SSH isn't listening
# If "succeeded" → network is fine, Docker context should work
```

**Network causes** (in order of likelihood): different Wi-Fi, AP isolation enabled on router, guest network blocking client-to-client traffic, VPN on Mac, phone asleep and dropped off Wi-Fi.

**Fix network**: put both devices on the same SSID, disable AP isolation in router settings, turn off Mac VPN, wake the phone screen.

**If network is fine but SSH still times out**: QEMU died inside the phone. Restart it via `phone-vm-start --wait` if you have the helper scripts, or reboot the phone entirely and wait 20–30 min for TCG boot.

---

### 2. "QEMU died after my SSH disconnected"

**Symptom**: QEMU was running, you disconnected from Termux SSH, and an hour later QEMU is gone.

**Cause**: Even with `setsid` + `disown`, Android's aggressive battery management can kill background processes when the screen is off and no wake lock is held.

**Fix**: Make sure `termux-wake-lock` is active (the `01-start-vm.sh` boot script calls it). Verify with:

```bash
ssh phone-termux 'termux-wake-lock 2>/dev/null; cat /proc/$(pgrep -f qemu-system-aarch64 | head -1)/status | grep State'
```

If you see "State: S (sleeping)" instead of "Z (zombie)" or no process at all, you're fine.

**Also**: In Android Settings → Apps → Termux, disable "Battery optimization" for Termux. This is separate from the wake lock.

---

### 3. "Docker pull fails with TLS handshake timeout"

**Symptom**: `docker pull hello-world` fails with `TLS handshake timeout` even though `curl https://registry-1.docker.io/v2/` works.

**Cause**: Docker's default TLS timeout (~10s) is shorter than TCG's TLS handshake time (~25–30s).

**Fix**: Already covered by `vm/docker-daemon.json` in this repo (`max-download-attempts: 5`). If it still happens, retry — eventually it succeeds. First pull of a 5 KB image takes ~75 seconds.

```bash
# Retry with more patience
docker --context phone pull hello-world
# Or pull inside the VM directly to see progress
ssh phone-vm 'sudo docker pull hello-world'
```

---

### 4. "Termux sshd isn't running after reboot"

**Symptom**: After phone reboots, `ssh phone-termux` fails but `ssh phone-vm` works.

**Cause**: Termux:Boot launches the VM (which has its own SSH on 2222), but Termux's own sshd on 8022 wasn't configured to auto-start.

**Fix**: Add a second boot script `~/.termux/boot/02-start-sshd.sh`:

```bash
#!/data/data/com.termux/files/usr/bin/bash
sleep 30                          # wait for VM launch to stabilize
termux-wake-lock 2>/dev/null
sshd                              # start Termux's own sshd
```

```bash
chmod +x ~/.termux/boot/02-start-sshd.sh
```

---

### 5. "The VM boots to a UEFI shell instead of Debian"

**Symptom**: Serial console shows `Shell>` instead of GRUB. VM hangs.

**Cause**: UEFI firmware can't find the bootloader. The Debian cloud image ESP doesn't always have a `startup.nsh` file.

**Fix**: Write a `startup.nsh` to the Debian ESP root. Requires booting into an Alpine rescue ISO (outside the scope of this repo — see PLAYBOOK.md §9.5.2 for the full procedure).

Short version, once you're in Alpine rescue with Debian root at `/mnt`:

```bash
# ESP is at /dev/vdb15 when Debian root is /dev/vdb1
mount /dev/vdb15 /mnt/esp
# CRLF line endings are REQUIRED in UEFI shell
printf 'FS0:\r\nEFI\\debian\\grubaa64.efi\r\n' > /mnt/esp/startup.nsh
umount /mnt/esp
```

---

## Still stuck?

Open an [Issue](https://github.com/sulthonzh/android-docker-qemu/issues) with:
1. Output of `phone-healthcheck` (or equivalent manual checks)
2. Last 50 lines of `~/qemu-vm/debian-boot.log` from the phone
3. Your phone model, Android version, and Termux version
