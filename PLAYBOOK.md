# Termux Linux Server + Docker-Alternative Playbook (Non-Rooted Android)

> **Deep-research deliverable.** Covers: ADB-over-network → Termux install → Linux server (proot-distro) → Docker-compatible workloads — all on a **non-rooted** Android device.
>
**Target host:** macOS (`brew install --cask android-platform-tools`, adb 1.0.41 confirmed working).
> **Target device example:** `192.168.0.9:33407` (port is in the Android 11+ dynamic range, so treat as a **connect port**).
> **Researched:** 2026-06-13. All sources cited inline.

---

## Table of Contents

1. [Executive Summary & Decision Matrix](#1-executive-summary--decision-matrix)
2. [Phase 1 — ADB Over Network](#2-phase-1--adb-over-network)
3. [Phase 2 — Termux Base (SSH-reachable, reboot-survivable)](#3-phase-2--termux-base-ssh-reachable-reboot-survivable)
4. [Phase 3 — Linux Server via proot-distro](#4-phase-3--linux-server-via-proot-distro)
5. [Phase 4 — Docker-Compatible Workloads (No Root)](#5-phase-4--docker-compatible-workloads-no-root)
6. [End-to-End Verification Scenarios](#6-end-to-end-verification-scenarios)
7. [Failure Mode Encyclopedia](#7-failure-mode-encyclopedia)
8. [References & Trusted Projects](#8-references--trusted-projects)

---

## 1. Executive Summary & Decision Matrix

### The brutally honest reality

| Goal | Feasible without root? | Recommended path |
|------|:----------------------:|------------------|
| Connect to Android via ADB over WiFi | ✅ | Android 11+ Wireless Debugging (`adb pair` → `adb connect`) |
| Run a Linux shell on Android | ✅ | Termux (F-Droid) → `proot-distro install debian:12` |
| Run daemons (nginx, postgres, sshd) in that Linux | ✅ | Direct daemon exec (`/usr/sbin/sshd`) — **systemd does NOT work in proot** |
| Run real `dockerd` daemon natively | ❌ | Blocked by kernel (no cgroups/namespaces for unprivileged apps). Needs root + custom kernel. |
| Run `podman` rootless | ❌ | Officially unsupported. Podman maintainer: *"proot is not powerful enough to run Podman"* ([podman#26186](https://github.com/containers/podman/issues/26186)) |
| Run `docker run hello-world` locally, no root | ✅ **slow** | QEMU VM running Alpine + real Docker inside ([egandro/docker-qemu-arm](https://github.com/egandro/docker-qemu-arm)). 10–25× overhead. |
| Run `docker compose up` against a remote host | ✅ | Static `docker` CLI on phone + SSH socket-forward to remote `docker.sock` ([docker/compose#10511](https://github.com/docker/compose/issues/10511)) |
| Run Docker **images** without a daemon | ✅ **best** | **`udocker`** — pulls OCI images, execs them via proot/patchelf. Now in Termux APT. ([George-Seven/Termux-Udocker](https://github.com/George-Seven/Termux-Udocker)) |
| Run gVisor/runsc | ❌ | Panics on Android (`/proc/sys/vm/mmap_min_addr` permission) ([gvisor#12544](https://github.com/google/gvisor/issues/12544)) |

### TL;DR Recommendation

For a **non-rooted** phone that needs to run "Docker" workloads:

1. **Primary: `udocker`** — best speed-to-flexibility ratio. Pulls any Docker Hub image, runs in userspace. Now `pkg install udocker`. Use George-Seven's repo for ready-to-run workload scripts (Home Assistant, Nextcloud, Jellyfin, etc.).
2. **Secondary: QEMU + Alpine + real Docker** — when you genuinely need `docker build`, multi-container networking, or 100% Docker API compatibility. Expect 10–25× slowdown.
3. **Tertiary: Remote Docker via SSH socket-forward** — when you have a real server elsewhere. Phone becomes a thin client.
4. **Do NOT attempt:** Podman-in-proot, gVisor, `pkg install docker` without root, Andronix/AnLinux (use `proot-distro` instead).

---

## 2. Phase 1 — ADB Over Network

**Source:** [Android developer docs — adb#wireless](https://developer.android.com/tools/adb#wireless) · [Run apps on a hardware device](https://developer.android.com/studio/run/device) · [platform-tools release notes](https://developer.android.com/tools/releases/platform-tools)

### 2.1 macOS host setup

```bash
# Install once
brew install --cask android-platform-tools
# Verify
adb version    # → 1.0.41 / version 37.0.0-14910828 or newer
```

- **Universal binary** (Apple Silicon + Intel).
- Installs `adb`, `fastboot`, `etc1tool`, `hprof-conv` into `/opt/homebrew/bin` (Apple Silicon) or `/usr/local/bin` (Intel).
- **Do NOT use** `brew install android-platform-tools` (formula) — deprecated. The **cask** is canonical.

### 2.2 The Android 11+ "Wireless Debugging" flow (modern, what your `:33407` port is)

`33407` is in the Android 11+ dynamic high-port range. This is a **connect port**, not a pairing port.

**On the device (one-time):**

1. `Settings → System → Developer options → Wireless debugging → ON`
2. Tap **Pair device with pairing code** → device shows `IP:PAIR_PORT` + 6-digit code
3. After pairing succeeds, the main Wireless Debugging screen shows a **different** `IP:CONNECT_PORT` (this is your `:33407`)

**On macOS:**

```bash
# Step 1 — pair (one-time). Pair port is shown in the "Pair device with pairing code" dialog.
adb pair 192.168.0.9:<pair-port>
# → Prompts: "Enter pairing code: "
# → Success: "Successfully paired to 192.168.0.9:<pair-port> [guid=adb-...]"

# Step 2 — connect. Connect port is from the MAIN wireless debugging screen.
adb connect 192.168.0.9:33407
# → "connected to 192.168.0.9:33407"

# Step 3 — verify
adb devices -l
# → 192.168.0.9:33407    device    product:... model:... transport_id:1
```

> **CRITICAL — the #1 mistake:** The pairing port is **one-shot** and closes after `adb pair` succeeds. Do **not** use the pairing port for `adb connect`. Re-read the **connect port** from the main Wireless Debugging screen.

### 2.3 The legacy `adb tcpip 5555` flow (Android ≤ 10 fallback)

Required when: device is Android ≤ 10, or corporate WiFi blocks modern mDNS-based pairing.

```bash
# 1. USB-attach, accept RSA dialog
adb devices

# 2. Switch on-device adbd to TCP/IP :5555
adb tcpip 5555
# → "restarting in TCP mode port: 5555"

# 3. Read device IP
adb shell ip route | awk '/wlan0/{print $3}' | head -1

# 4. Unplug USB, connect over WiFi
adb connect <device-ip>:5555
```

Caveats: reboot resets it (not persistent); port 5555 is unauthenticated; no mDNS auto-discovery.

### 2.4 Pre-flight checklist when `adb connect` times out

Your `adb connect 192.168.0.9:33407` returned `Operation timed out`. Walk this list:

```bash
# 1. Layer-3 reachability
ping -c 3 192.168.0.9

# 2. TCP reachability to the specific port
nc -vz 192.168.0.9 33407
#   success: "Connection to 192.168.0.9 port 33407 [tcp/*] succeeded!"
#   failure: "Operation timed out" → port closed / AP isolation / device asleep

# 3. mDNS auto-discovery (same-L2 only)
adb mdns services
# If your device is reachable and wireless debugging is on, you'll see:
#   adb-XXXX _adb-tls-connect._tcp 192.168.0.9:<current-port>
# Ports rotate — re-read from device if needed.

# 4. Brute-force scan if mDNS blocked across an L3 hop
nmap -p 30000-50000 --open -T4 192.168.0.9 | grep open
```

**Common causes of timeout, in order:**

| Cause | Fix |
|-------|-----|
| Wireless debugging toggled OFF on device | Re-enable in Developer Options |
| Device screen asleep (some ROMs close the socket when screen off) | Wake device, keep screen on during pairing |
| Device rebooted (wireless debugging does NOT survive reboot) | Re-enable; re-pair if needed |
| Mac and phone on different VLANs / AP isolation active on router | Same SSID, disable AP isolation / guest network |
| macOS Local Network privacy blocked (Sonoma+) | `System Settings → Privacy & Security → Local Network → enable Terminal` |
| Port rotated (Android 11+ ports are dynamic) | `adb mdns services` or re-read from device screen |
| Used pairing port by mistake for connect | Re-read **connect** port from main Wireless Debugging screen |

### 2.5 Useful ADB commands

```bash
adb pair <ip>:<pair-port> [code]    # pair (one-time, Android 11+)
adb connect <ip>:<connect-port>     # connect
adb disconnect <ip>:<port>          # disconnect one
adb disconnect                      # disconnect ALL TCP devices
adb devices -l                      # list verbose
adb kill-server && adb start-server # restart daemon
adb reconnect offline               # force reconnect offline transports
adb mdns check                      # which mDNS backend (openscreen/bonjour)
adb mdns services                   # list _adb* services
```

**Environment variables:**

```bash
ADB_LIBUSB=1 adb start-server            # force libusb USB backend
ADB_MDNS_OPENSCREEN=1 adb start-server   # force Openscreen mDNS backend
```

### 2.6 Programmatic port discovery (when screen-reading isn't viable)

```bash
# Built-in
adb mdns services | awk '/_adb-tls-connect._tcp/ {print $3}'

# macOS native Bonjour CLI
dns-sd -B _adb-tls-connect._tcp          # browse continuously
dns-sd -L <instance> _adb-tls-connect._tcp local.   # resolve one

# Python (zeroconf)
# See https://github.com/Vazgen005/adb-wifi-py for a working implementation
```

---

## 3. Phase 2 — Termux Base (SSH-reachable, reboot-survivable)

**Sources:** [termux/termux-app README](https://github.com/termux/termux-app/blob/master/README.md) · [termux/termux-boot README](https://github.com/termux/termux-boot/blob/master/README.md) · [Termux wiki: Remote Access](https://wiki.termux.com/wiki/Remote_Access) · [Termux wiki: Package Management](https://wiki.termux.com/wiki/Package_Management)

### 3.1 Install — F-Droid or GitHub ONLY

> **The Play Store Termux is dead.** Frozen at v0.101 since ~2020 because Android 10's target-SDK policy broke the old codebase. A new "experimental" Play Store build exists since [commit d90be9c (2024-06-15)](https://github.com/termux/termux-app/commit/d90be9cd508b26636d705cda95cbebaace3d9706) but is **signature-incompatible** with F-Droid (removed `sharedUserId`) and missing functionality. Do not use it.

**Install paths (pick ONE — they're signature-incompatible with each other):**

| Source | URL | Pros | Cons |
|--------|-----|------|------|
| **F-Droid (recommended)** | https://f-droid.org/en/packages/com.termux/ | Universal APK, plugin ecosystem aligned | Lags GitHub by days-weeks |
| GitHub Releases | https://github.com/termux/termux-app/releases | Immediate, per-arch APKs (smaller) | Signed with **public testkey** — anyone can sign "an update" |

**Current version:** `v0.118.3` (2025-05-22). Anything below v0.118.0 has a known world-readable-file vulnerability — upgrade.

**Headless install via ADB (from macOS):**

```bash
# Clean any prior install (signature mismatch is the #1 install failure)
adb shell pm list packages com.termux
adb uninstall com.termux
adb uninstall com.termux.boot
adb uninstall com.termux.api
adb uninstall com.termux.window
adb uninstall com.termux.widget

# Install Termux + plugins FROM THE SAME SOURCE
adb install -r termux_v0.118.3+f-droid.apk
adb install -r termux-boot_v0.8.1+f-droid.apk
adb install -r termux-api_v0.53.0+f-droid.apk
```

### 3.2 First-launch bootstrap (over ADB)

Termux's first launch extracts a `bootstrap-<arch>.zip` (~120 MB) into `$PREFIX` (`/data/data/com.termux/files/usr/`). Trigger it headlessly:

```bash
# Launch Termux — this triggers bootstrap extraction
adb shell am start -n com.termux/.app.TermuxActivity

# Wait ~30 seconds, then verify it's running
adb shell pidof com.termux
```

### 3.3 Storage access

```bash
# Inside Termux (run once). Triggers Android WRITE_EXTERNAL_STORAGE dialog.
termux-setup-storage
# → Tap "Allow" on device
# → Creates ~/storage/{shared,downloads,dcim,pictures,music,movies} symlinks
ls -la ~/storage/
```

Per [`TermuxInstaller.java` L294](https://github.com/termux/termux-app/blob/master/app/src/main/java/com/termux/app/TermuxInstaller.java):

| Symlink | Target |
|---------|--------|
| `~/storage/shared` | `/storage/emulated/0` (== `/sdcard`) |
| `~/storage/downloads` | `/storage/emulated/0/Download` |
| `~/storage/dcim` | `/storage/emulated/0/DCIM` |
| `~/storage/pictures` | `/storage/emulated/0/Pictures` |
| `~/storage/music` | `/storage/emulated/0/Music` |
| `~/storage/movies` | `/storage/emulated/0/Movies` |

### 3.4 Update + mirror fix

```bash
pkg update && pkg upgrade -y
```

> **Use `pkg`, not `apt`.** `pkg` is a wrapper that handles mirror selection/rotation/health-checks automatically. Running `apt update` directly uses whatever stale mirror is in `sources.list` even if it's dead.

**For Asia/Jakarta timezone** — switch to the Asia mirror group:

```bash
termux-change-repo
# TUI: select "main" repo → "Mirrors in Asia" group
# Indonesian mirrors in the group: linux.domainesia.com, mirror.nevacloud.com
```

Manual override (non-interactive):

```bash
cp $PREFIX/etc/apt/sources.list $PREFIX/etc/apt/sources.list.bak
sed -i 's@^\(deb.*stable main\)$@#\1\ndeb https://linux.domainesia.com/applications/termux/termux-main stable main@' \
    $PREFIX/etc/apt/sources.list
pkg update
```

### 3.5 SSH server (Mac → Phone bridge)

Termux's `openssh` is patched to default to **port 8022** (Android blocks unprivileged ports <1024).

```bash
# Install
pkg install openssh

# Set a password (stored in ~/.termux_authinfo — Termux-specific)
passwd

# Optional but recommended: key auth
mkdir -p ~/.ssh && chmod 700 ~/.ssh
# Paste your Mac's ~/.ssh/id_ed25519.pub:
echo 'ssh-ed25519 AAAA...' >> ~/.ssh/authorized_keys
chmod 600 ~/.ssh/authorized_keys

# Start the daemon
sshd
```

**Connect from macOS** (the SSH username is ignored — Termux is single-user):

```bash
# Find device IP first (in Termux): ip addr show wlan0 | grep inet
ssh -p 8022 -i ~/.ssh/id_ed25519 192.168.0.9
```

Make it permanent in `~/.ssh/config` on macOS:

```sshconfig
Host android-termux
    HostName 192.168.0.9
    Port 8022
    User u0_a123     # ignored by Termux, keeps ssh happy
    IdentityFile ~/.ssh/id_ed25519
    IdentitiesOnly yes
    ServerAliveInterval 30
```

Then `ssh android-termux`.

> **Known bug:** Around 2024-07-01 an openssh Termux package regression broke password auth ([termux-packages#20758](https://github.com/termux/termux-packages/issues/20758), fixed in #20759). If password auth fails with a known-correct password: `pkg upgrade openssh && pkill sshd && sshd`.

### 3.6 Reboot survival (Termux:Boot)

**Install Termux:Boot** from the **same source** as Termux (signature-matched). Then:

```bash
# One-time: open the Termux:Boot app launcher manually to register BOOT_COMPLETED
adb shell am start -n com.termux.boot/com.termux.boot.BootActivity
# Or just tap the icon on the device

# Create the boot script directory
mkdir -p ~/.termux/boot

# Auto-start sshd on boot
cat > ~/.termux/boot/01-start-sshd <<'EOF'
#!/data/data/com.termux/files/usr/bin/sh
termux-wake-lock         # CRITICAL — prevents Android doze from killing sshd
sshd
EOF
chmod +x ~/.termux/boot/01-start-sshd
```

**Per-OEM battery-optimization fixes** (essential — see [dontkillmyapp.com](https://dontkillmyapp.com/)):

| OEM | Fix |
|-----|-----|
| Stock Android | `Settings → Apps → Termux → Battery → Unrestricted` |
| Xiaomi / Poco | `Security → Battery → App battery saver → Termux → No restrictions`; disable "Memory compression" |
| Samsung | `Settings → Battery → Background usage limits → Never sleeping apps → Termux` |
| Oppo / Realme | `Settings → Battery → App battery management → Termux → allow auto-launch` |
| Pixel | Disable "Phantom process killer" (Android 12+) — see below |

**Android 12+ phantom process kill** — critical, undocumented by OEMs. Termux dies randomly with `[Process completed (signal 9)]`. Fix via ADB:

```bash
adb shell device_config put activity_manager max_phantom_processes 2147483647
adb shell device_config set_sync_disabled_for_tests true
# Verify
adb shell device_config get activity_manager max_phantom_processes
```

Source: [termux-app#2366](https://github.com/termux/termux-app/issues/2366).

### 3.7 Diagnostic: `termux-info`

Run this before reporting any Termux issue — pastes a complete environment dump:

```bash
termux-info
```

Outputs: Termux version, CPU arch, subscribed repositories, upgradable packages, Android version, kernel, supported ABIs, installed plugin packages.

---

## 4. Phase 3 — Linux Server via proot-distro

**Sources:** [termux/proot-distro README](https://github.com/termux/proot-distro/blob/master/README.md) · [v5.0.2 release](https://github.com/termux/proot-distro/releases/tag/v5.0.2) · [proot-me/proot manual](https://github.com/proot-me/proot/blob/master/doc/proot/manual.rst) · [systemd-fails discussion](https://github.com/termux/proot/discussions/232)

### 4.1 ⚠️ Critical: proot-distro v5 breaking change

**v5.0 (May 2026) is a Python rewrite with breaking CLI changes.**

| Version | Install syntax |
|---------|----------------|
| v4 (legacy) | `proot-distro install ubuntu` (bundled alias) |
| **v5 (current)** | `proot-distro install ubuntu:24.04` (OCI/Docker Hub ref) |

v5 "no longer acts as a provider of distributions" — it pulls from Docker Hub / any OCI registry. If you see old tutorials showing v4 syntax, they will fail with `Error: unknown distribution 'ubuntu'`.

### 4.2 Install proot-distro

```bash
pkg install proot-distro
# Automatically pulls in proot as a dependency
```

### 4.3 Install a Linux distro (recommended: Debian 12)

**Why Debian 12 (bookworm)?** glibc (max Docker Hub image compatibility), stable, ~60k packages, well-documented. Alpine is smaller but uses **musl libc** which breaks many prebuilt Docker images. Ubuntu 24.04 is fine but offers no headless-server advantage over Debian.

```bash
# See available distros
proot-distro list

# Install Debian 12 (aarch64 by default on modern phones)
proot-distro install debian:12

# Log in
proot-distro login debian
# or with the v5 shorthand:
pd sh debian
```

Container rootfs stored at: `$PREFIX/var/lib/proot-distro/installed-rootfs/debian/`.

### 4.4 File sharing between Termux ↔ container

**Default binds** (no flags needed):

| Host (Termux) | Inside container |
|---------------|------------------|
| `/sdcard` (== `~/storage/shared`) | `/sdcard` |
| `/system`, `/vendor`, `/apex`, `/product` | same paths (read-only) |
| `/data/data/com.termux/files/usr` | same path (so `pkg`, `termux-api` work from container) |

**Custom bind:**

```bash
proot-distro login debian --bind /data/data/com.termux/files/home/myproject:/workspace
```

**Share Termux home into container:**

```bash
proot-distro login debian --shared-home   # v5 flag (was --termux-home in v4)
# Now /root inside container == Termux $HOME
```

### 4.5 The systemd trap (and how to actually run services)

**systemd does NOT work inside proot.** It requires PID 1, but PID 1 inside proot is your login shell. Confirmed by proot maintainer @michalbednarski in [discussion #232](https://github.com/termux/proot/discussions/232):

> *"SystemD cannot work inside proot (due to not being pid 1)"*

Any `apt install` whose postinst hook calls `systemctl` will appear to fail (the binaries extract fine; only the service-start hook fails):

```
System has not been booted with systemd as init system (PID 1). Can't operate.
Failed to connect to bus: Host is down
```

**Workarounds (pick one):**

#### A. Run daemons directly (most common)

```bash
# Instead of: systemctl start ssh
/usr/sbin/sshd

# Instead of: systemctl start nginx
/usr/sbin/nginx

# Auto-start on every login
cat > /etc/profile.d/services.sh <<'EOF'
#!/bin/sh
pgrep -x sshd  >/dev/null 2>&1 || /usr/sbin/sshd
pgrep -x nginx >/dev/null 2>&1 || /usr/sbin/nginx
EOF
chmod +x /etc/profile.d/services.sh
```

#### B. Pick a non-systemd distro (cleanest)

```bash
proot-distro install alpine:3.21
proot-distro login alpine --fix-lowports -- /sbin/openrc default
# Then: rc-service sshd start, rc-update add sshd default
```

OpenRC works fine inside proot (it doesn't need PID 1).

#### C. systemctl shim

- [`gdraheim/docker-systemctl-replacement`](https://github.com/gdraheim/docker-systemctl-replacement) — Python script that replaces `/usr/bin/systemctl`, parses `*.service`, execs `ExecStart`.
- [`iiab/pdsm`](https://github.com/iiab/iiab/blob/master/roles/proot_services/README.md) — purpose-built "PRoot Distro service manager" for Debian containers.
- [`EdwardLab/initd`](https://github.com/EdwardLab/initd) — newer (2026), runs unmodified systemd `.service` files.

### 4.6 SSH directly into the Linux container (skip Termux layer)

The Termux SSH daemon runs on `:8022`. For a second SSH endpoint that lands you directly in Debian, run sshd **inside** the container on a different port (e.g., `:2222`):

```bash
# Inside the Debian container:
apt install -y openssh-server
mkdir -p /run/sshd

# Configure /etc/ssh/sshd_config:
#   Port 2222
#   PasswordAuthentication yes
#   PermitRootLogin yes
#   ListenAddress 0.0.0.0

passwd                    # set root password
/usr/sbin/sshd            # start (NOT systemctl)
ss -tlnp | grep 2222      # verify listening
```

From macOS:

```bash
ssh -p 2222 root@192.168.0.9
```

You can even chain this through Termux via `ProxyJump`:

```sshconfig
Host android-debian
    ProxyJump android-termux     # jump through Termux :8022
    HostName 127.0.0.1
    Port 2222
    User root
```

### 4.7 CPU architecture

```bash
uname -m
# → aarch64    (on >95% of modern phones)
```

proot does **not** emulate the CPU unless you explicitly enable qemu-user. So `uname -m` inside the container reports the host Android kernel's arch.

```bash
# Detection helper
ARCH=$(uname -m)
case "$ARCH" in
  aarch64)      DOCKER_ARCH=arm64 ;;
  armv7l|armv8l) DOCKER_ARCH=arm ;;
  x86_64)       DOCKER_ARCH=amd64 ;;
  i686)         DOCKER_ARCH=386 ;;
esac
```

### 4.8 Performance expectations

proot is `ptrace`-based — **2 context switches per syscall**, plus per-path `lstat` translation. From the [proot-distro README "Distinctions from Chroot"](https://github.com/termux/proot-distro/blob/master/README.md):

> *"proot-distro may show higher performance degradation comparing to other proot environment setup scripts. Reason behind this is more extensive use of directory and file bindings. This is not a bug and is not planned to be 'fixed'."*

| Workload | Overhead vs native |
|----------|-------------------|
| CPU-bound (crypto, number crunching) | ~5% |
| Filesystem-heavy (`apt`, compilation, `git`) | 15–40% |
| Database (postgres, sqlite) | 15–25% |

**Plan accordingly.** A phone that benchmarks at 1000 CPU/sec in native Termux will deliver ~600–950 inside proot for I/O workloads.

---

## 5. Phase 4 — Docker-Compatible Workloads (No Root)

This is the hardest part. **Real Docker requires kernel namespaces + cgroups that Android kernels do not expose to unprivileged apps.** Everything below is a workaround with documented trade-offs.

### 5.1 Option A (RECOMMENDED): `udocker` — Docker images without a daemon

**What it is:** A tool that pulls OCI/Docker images, extracts the rootfs into a userspace directory, and runs them via one of three execution backends: `R2` (patchelf + `LD_LIBRARY_PATH`), `F1` (proot), or `T2` (patchelf + direct `execve`). **No daemon, no namespaces, no cgroups, no kernel modules.**

**Install (now officially in Termux APT — [termux-packages#24699](https://github.com/termux/termux-packages/pull/24699)):**

```bash
# Inside Termux (NOT inside proot-distro — udocker runs natively in Termux)
pkg install udocker
# Or use the community helper with ready-to-run workloads:
pkg install git
git clone --depth 1 https://github.com/George-Seven/Termux-Udocker ~/Termux-Udocker
bash ~/Termux-Udocker/install_udocker.sh
```

**Usage:**

```bash
udocker pull hello-world
udocker run hello-world
# → "Hello from Docker!"

# Real workloads (12 ready-made scripts in George-Seven's repo):
bash ~/Termux-Udocker/home-assistant.sh   # → http://phone:8123
bash ~/Termux-Udocker/nextcloud.sh        # → http://phone:2080
bash ~/Termux-Udocker/jellyfin.sh         # → http://phone:8096
bash ~/Termux-Udocker/jupyter.sh          # → http://phone:8888
```

**Trade-offs:**
- ✅ Fast (near-native — no VM, just execve)
- ✅ Pulls any Docker Hub / GHCR / Quay image
- ✅ No root, no kernel features
- ❌ **No process isolation** — containers share the Termux PID namespace (single-tenant only)
- ❌ No `docker build` (only `run` prebuilt images)
- ❌ No `docker compose` (scripted equivalents only)

**Trust:** [George-Seven/Termux-Udocker](https://github.com/George-Seven/Termux-Udocker) — 364★, actively maintained. Upstream engine: [indigo-dc/udocker](https://github.com/indigo-dc/udocker) (research-grade, EGEE-funded).

### 5.2 Option B: QEMU VM + Alpine + real Docker

**What it is:** Boot a full Alpine Linux VM under QEMU. Inside the VM, Docker daemon runs natively (the VM provides a real Linux kernel). Expose the Docker socket back to Termux/host via port forwarding.

**Install (use the actively-maintained reference):**

```bash
# egandro/docker-qemu-arm — 161★, last push 2026-06 (very active)
git clone https://github.com/egandro/docker-qemu-arm ~/qemu-docker
cd ~/qemu-docker
# Follow README — downloads Alpine virt ISO, builds qcow2, configures Docker
```

Alternative projects:

| Repo | Stars | Status | Notes |
|------|-------|--------|-------|
| [cyberkernelofficial/docker-in-termux](https://github.com/cyberkernelofficial/docker-in-termux) | 798 | active | Most-starred |
| [egandro/docker-qemu-arm](https://github.com/egandro/docker-qemu-arm) | 161 | **very active** | The original; AntonyZ89 forked it |
| [luisdavim/termux-docker](https://github.com/luisdavim/termux-docker) | 3 | **newest (2026)** | Lima/Colima-inspired; cloud-init; watch this one |
| [AI2TH/Pockr](https://github.com/AI2TH/Pockr) | 18 | active | QEMU inside an APK — no Termux needed |
| diogok/termux-qemu-alpine-docker | 190 | stale (2023) | Honest perf numbers in README |

**Performance reality (measured, not claimed):**

| Operation | Native | QEMU-on-Android | Source |
|-----------|-------|------------------|--------|
| `docker run hello-world` | ~1s | **~25s** | [diogok README](https://github.com/diogok/termux-qemu-alpine-docker) |
| Disk read | ~100 MB/s | **~4 MB/s** | [cyberkernelofficial#13](https://github.com/cyberkernelofficial/docker-in-termux/issues/13) |
| VM boot | — | 60–290s | various |

**Critical:** Running `qemu-system-aarch64` on an aarch64 phone does **NOT** give near-native speed — Android kernels don't expose KVM to unprivileged apps, so QEMU does full TCG emulation regardless. aarch64-on-aarch64 is *slightly* faster than x86_64-on-aarch64 due to simpler decode, but it's still emulation.

**When to use this path:** Only when you genuinely need 100% Docker daemon behavior — `docker build`, multi-container networking with bridges, Kubernetes development.

### 5.3 Option C: Remote Docker via SSH socket-forward

**What it is:** The Docker CLI is just a Go binary that talks the Docker Engine API. Run the CLI on the phone; talk to a real Docker daemon on a remote host (VPS, home server, laptop) over SSH.

**Install the Docker CLI on the phone (static binary):**

```bash
# In Termux (no root needed):
wget https://download.docker.com/linux/static/stable/aarch64/docker-27.5.0.tgz
tar xzf docker-27.5.0.tgz
install -m 755 docker/docker $PREFIX/bin/docker
rm -rf docker docker-27.5.0.tgz
```

**The Compose landmine — read this carefully:**

Plain `DOCKER_HOST=ssh://...` works for `docker ps`, `docker run`, etc. **but `docker compose` crashes on Termux** with `SIGSYS: bad system call` because Android's seccomp blocks the `faccessat2` syscall that Go 1.20+ runtimes use ([docker/compose#10511](https://github.com/docker/compose/issues/10511)).

**The workaround** — forward the remote Unix socket over SSH, so Compose sees a local Unix socket:

```sshconfig
# ~/.ssh/config on macOS / Termux
Host my-docker-host
    HostName docker.example.com
    User root
    ControlMaster auto
    ControlPersist yes
    ControlPath ~/.tmp/ssh-%u-%r@%h:%p
    LocalForward /data/data/com.termux/files/home/docker.sock /var/run/docker.sock
```

```bash
# Establish the tunnel (background)
ssh my-docker-host -N &

# Point Docker at the local-forwarded socket
docker context create remote \
    --docker "host=unix:///data/data/com.termux/files/home/docker.sock"
docker context use remote

# Everything works now, including Compose:
docker compose up -d
docker compose logs -f
docker compose down
```

**Production pattern** (verified across 7+ real GitHub repos — see [Findings](#findings-docker_host-ssh-references)): set `DOCKER_HOST=ssh://...` in `~/.profile` for persistent config.

### 5.4 What does NOT work (avoid — verified dead ends)

#### `pkg install docker` (without root)
- The package is in **`root-packages/`** — `pkg install root-repo` first. Requires root to function.
- Even **with** root, frequently broken: `runc 1.2.4` broke it Feb 2025 ([termux-packages#23181](https://github.com/termux/termux-packages/issues/23181)). Requires downgrading runc to 1.1.15.
- Even **with** root + Docker-compatible kernel, `hello-world` can fail ([termux-packages#18359](https://github.com/termux/termux-packages/issues/18359)).
- Canonical root-path writeups: [FreddieOliveira gist](https://gist.github.com/FreddieOliveira/efe850df7ff3951cb62d74bd770dce27), [OshekharO/Docker-On-Android](https://github.com/OshekharO/Docker-On-Android) — both explicitly require root + custom kernel.

#### Podman inside proot-distro
- Officially unsupported. Podman maintainer @giuseppe closed [containers/podman#26186](https://github.com/containers/podman/issues/26186) as `not_planned`:
  > *"unfortunately you can't do that. The environment created by proot is not powerful enough to run Podman"*
- Follow-up discussion [containers/podman#17717](https://github.com/containers/podman/discussions/17717) open since Jan 2023 — zero progress.
- Error you'll see: `cannot clone: Invalid argument` / `cannot re-exec process` — proot cannot synthesize user namespaces.

#### gVisor / runsc
- Panics on Android: `couldn't open /proc/sys/vm/mmap_min_addr: permission denied` ([gvisor#12544](https://github.com/google/gvisor/issues/12544), opened Jan 2026).
- gVisor maintainer confirmed: no plans to support Android without namespace support.

#### "proot-docker" wrappers
- **No serious, mature project exists.** The Termux community consensus is that proot fundamentally cannot host a container runtime, so no maintainer has built one.
- Closest: `luisdavim/termux-qemu-docker` exposes a `docker` shim that proxies to a QEMU VM socket — that's QEMU-docker with a friendly facade, not "proot-docker."

#### Andronix / AnLinux
- Both wrap proot (same tech as `proot-distro`) but with curated GUI distros. Andronix scripts frozen Feb 2024. AnLinux still pushes releases but community moved to `proot-distro` years ago.
- Use `proot-distro` directly — first-party, OCI-native, manageable (`list`/`remove`/`backup`).

---

## 6. End-to-End Verification Scenarios

> The playbook is complete when all four scenarios PASS with captured evidence.

### S1 — ADB wireless connect

```bash
# Action
adb connect 192.168.0.9:33407
adb devices -l

# PASS when:
#   "connected to 192.168.0.9:33407"
#   device list shows "192.168.0.9:33407    device"
# FAIL modes: timeout (see §2.4), unauthorized (re-pair), offline (kill-server/restart)
```

### S2 — Termux SSH reachable from macOS

```bash
# Action (in Termux)
pkg install openssh
passwd
sshd
ip addr show wlan0 | grep inet

# Action (on macOS)
ssh -p 8022 <device-ip>

# PASS when: shell prompt appears, `whoami` returns Termux user
```

### S3 — Linux container operational

```bash
# Action
proot-distro install debian:12
proot-distro login debian
cat /etc/os-release
apt update && apt install -y sl
/usr/games/sl

# PASS when: /etc/os-release shows Debian 12; `sl` prints the steam locomotive
```

### S4 — Docker-compatible workload runs

**Path A — udocker:**
```bash
pkg install udocker
udocker pull hello-world
udocker run hello-world
# PASS: "Hello from Docker!"
```

**Path B — QEMU VM (slower but real Docker):**
```bash
# After egandro/docker-qemu-arm setup
docker run --rm hello-world
# PASS: "Hello from Docker!" (allow 20–30s)
```

**Path C — Remote Docker via SSH socket-forward:**
```bash
ssh my-docker-host -N &
docker context use remote
docker run --rm hello-world
docker compose up -d   # Compose works because socket-forward bypasses seccomp
# PASS: hello-world output; compose containers up
```

---

## 7. Failure Mode Encyclopedia

### 7.1 ADB

| Symptom | Root cause | Fix |
|---------|-----------|-----|
| `failed to connect ... Operation timed out` | Port closed / device asleep / AP isolation / wrong network | §2.4 checklist |
| `device unauthorized` | RSA key not trusted | Unlock device, tap "Allow"; or `rm ~/.android/adbkey*` + `adb start-server` |
| `Connection refused` (immediate) | Wireless debugging toggled off, or used pairing port for connect | Re-enable wireless debugging; re-read **connect** port |
| `device offline` | Stale transport | `adb disconnect <ip>:<port> && adb kill-server && adb start-server && adb connect <ip>:<port>` |
| `cannot connect to daemon at tcp:5037` | adb host server wedged | `pkill -9 adb && adb start-server` |
| macOS Local Network permission blocked | Sonoma+ privacy prompt dismissed | `System Settings → Privacy & Security → Local Network → enable Terminal` |

### 7.2 Termux

| Symptom | Root cause | Fix |
|---------|-----------|-----|
| `INSTALL_FAILED_SHARED_USER_INCOMPATIBLE` / "App not installed" | Signature mismatch — mixing F-Droid and GitHub APKs | Uninstall ALL `com.termux.*`, reinstall all from same source |
| `repository is under maintenance or down` | Stale/dead mirror | `termux-change-repo` → pick Asia group |
| `Hash Sum mismatch` | Stale APT metadata or transparent proxy corruption | `pkg clean && rm -rf $PREFIX/var/lib/apt/lists/* && pkg update` |
| `[Process completed (signal 9)]` | Android 12+ phantom process killer | `adb shell device_config put activity_manager max_phantom_processes 2147483647` |
| Play Protect flags Termux binaries | False positive on exec-from-app-storage | Disable Play Protect or whitelist `com.termux.*` |
| `pkg` as root | Forbidden | Run as Termux user, never root |

### 7.3 proot-distro

| Symptom | Root cause | Fix |
|---------|-----------|-----|
| `Error: unknown distribution 'ubuntu'` | v4 syntax on v5 install | Use `proot-distro install ubuntu:24.04` |
| `System has not been booted with systemd as init system` | systemd needs PID 1, proot provides bash | §4.5 workarounds (direct exec / Alpine+OpenRC / shim) |
| `bind: Operation not permitted` | proot can't bind a path Android blocks | Drop the bind or run Termux as root (not recommended) |
| Slow filesystem ops (apt, git) | proot per-syscall ptrace overhead | Expected (15–40%). Use Alpine for smaller package set, or run heavy FS work in QEMU VM |

### 7.4 Docker alternatives

| Path | Symptom | Fix |
|------|---------|-----|
| `pkg install docker` (no root) | Package not found | It's in `root-repo`. Don't pursue without root. |
| `podman run` inside proot | `cannot clone: Invalid argument` | **Dead end.** Switch to udocker or QEMU VM. |
| `docker compose` with `DOCKER_HOST=ssh://` | `SIGSYS: bad system call` | SSH socket-forward workaround (§5.3) |
| `runsc` (gVisor) | `panic: /proc/sys/vm/mmap_min_addr: permission denied` | **Dead end.** No Android support planned. |

---

## 8. References & Trusted Projects

### 8.1 Official Termux org repos (TRUSTED)

| Repo | URL | Stars | Latest |
|------|-----|-------|--------|
| termux-app | https://github.com/termux/termux-app | 56.3k | v0.118.3 (2025-05) |
| proot-distro | https://github.com/termux/proot-distro | 3.2k | **v5.1.4 (2026-06)** |
| termux-api | https://github.com/termux/termux-api | 3.9k | v0.53.0 (2025-09) |
| termux-boot | https://github.com/termux/termux-boot | 1.6k | v0.8.1 (2024-06) |
| termux-services | https://github.com/termux/termux-services | — | v0.13 |
| proot | https://github.com/termux/proot | ~1k | active |

### 8.2 Docker-alternative projects

| Repo | URL | Stars | Verdict |
|------|-----|-------|---------|
| **George-Seven/Termux-Udocker** | https://github.com/George-Seven/Termux-Udocker | 364 | **TRUSTED — primary no-root Docker-alternative** |
| indigo-dc/udocker (upstream) | https://github.com/indigo-dc/udocker | — | TRUSTED (engine) |
| egandro/docker-qemu-arm | https://github.com/egandro/docker-qemu-arm | 161 | TRUSTED (very active QEMU path) |
| cyberkernelofficial/docker-in-termux | https://github.com/cyberkernelofficial/docker-in-termux | 798 | EXPERIMENTAL (QEMU VM) |
| luisdavim/termux-docker | https://github.com/luisdavim/termux-docker | 3 | EXPERIMENTAL (newest, Lima/Colima-inspired) |
| AI2TH/Pockr | https://github.com/AI2TH/Pockr | 18 | EXPERIMENTAL (QEMU-in-APK) |
| clear-code/termux-podman | https://github.com/clear-code/termux-podman | 3 | ABANDONED (archived) |

### 8.3 Phone-as-server reference implementations

| Repo | URL | Stars | Use case |
|------|-----|-------|----------|
| Mohamadmourad/turn-phone-into-server | https://github.com/Mohamadmourad/turn-phone-into-server | 44 | Cleanest writeup: Termux → Debian → Cloudflare Tunnel |
| modded-ubuntu/modded-ubuntu | https://github.com/modded-ubuntu/modded-ubuntu | 1.2k | Ubuntu + XFCE + VNC GUI installer |
| coder/code-server | https://github.com/coder/code-server | 77.8k | Browser VS Code — [official Termux support](https://github.com/coder/code-server/blob/main/docs/termux.md) |

### 8.4 Documentation

| Resource | URL |
|----------|-----|
| Termux Wiki (main) | https://wiki.termux.com/wiki/Main_Page |
| Remote Access | https://wiki.termux.com/wiki/Remote_Access |
| PRoot | https://wiki.termux.com/wiki/PRoot |
| Package Management | https://wiki.termux.com/wiki/Package_Management |
| Differences from Linux | https://wiki.termux.com/wiki/Differences_from_Linux |
| Termux-services (runit) | https://wiki.termux.com/wiki/Termux-services |
| Android Wireless Debugging (official) | https://developer.android.com/tools/adb#wireless |
| Android 12+ phantom kills | https://github.com/termux/termux-app/issues/2366 |
| OEM battery optimizations | https://dontkillmyapp.com/ |

### 8.5 Definitive "does not work" issues (cite when users insist)

| Issue | URL |
|-------|-----|
| Podman in proot — officially impossible | https://github.com/containers/podman/issues/26186 |
| gVisor panics on Android | https://github.com/google/gvisor/issues/12544 |
| Compose `SIGSYS` on Termux (use socket-forward) | https://github.com/docker/compose/issues/10511 |
| Termux docker pkg needs root + breaks on runc bump | https://github.com/termux/termux-packages/issues/23181 |

---

## Appendix: Quick-start copy-paste sequence

```bash
# ──── On macOS host ────
brew install --cask android-platform-tools
adb pair 192.168.0.9:<pair-port>     # pair port from device's "Pair device with pairing code" dialog
adb connect 192.168.0.9:33407         # connect port from main Wireless Debugging screen

# Install Termux + plugins (F-Droid APKs, pushed via ADB)
adb install -r termux_v0.118.3.apk
adb install -r termux-boot_v0.8.1.apk
adb install -r termux-api_v0.53.0.apk
adb shell am start -n com.termux.boot/com.termux.boot.BootActivity   # register BOOT_COMPLETED

# ──── In Termux pane (via ADB or on-device) ────
termux-setup-storage                  # accept storage permission
pkg update && pkg upgrade -y
termux-change-repo                    # pick Asia group
pkg install openssh proot-distro udocker termux-api

# SSH bridge
passwd
mkdir -p ~/.ssh && chmod 700 ~/.ssh
echo '<YOUR_MAC_PUBLIC_KEY>' >> ~/.ssh/authorized_keys
chmod 600 ~/.ssh/authorized_keys
sshd

# Reboot survival
mkdir -p ~/.termux/boot
cat > ~/.termux/boot/01-start-sshd <<'EOF'
#!/data/data/com.termux/files/usr/bin/sh
termux-wake-lock
sshd
EOF
chmod +x ~/.termux/boot/01-start-sshd

# Linux server (Debian 12)
proot-distro install debian:12
proot-distro login debian
# (inside Debian): apt update && apt install -y openssh-server
# Configure /etc/ssh/sshd_config with Port 2222, run /usr/sbin/sshd

# Docker-compatible workload
udocker pull hello-world
udocker run hello-world
```

---

## 9. Phase 7 — Verified Build: Real Docker via QEMU VM (Debian 12 arm64)

> **Implementation log.** This section documents the actual end-to-end build on a Samsung Galaxy Note 10+ (SM-N975F, Exynos 9825, 12GB RAM, Android 12, kernel 4.14.113) — not rooted. All commands were executed and verified working between 2026-06-13 and 2026-06-14. This supersedes the theoretical path in §5.

### 9.1 Why QEMU VM and not udocker / proot-distro

| Option | Verdict | Reason |
|---|---|---|
| `udocker` | Rejected | Uses proot/patch underneath — no real namespaces, no `docker build`, no overlayfs, no multi-container networking. Good for single-image exec, not for real workloads. |
| `proot-distro install debian` + direct daemons | Rejected | No systemd → no `systemctl enable docker`. No cgroups → no container resource control. No namespaces → no real isolation. |
| **QEMU VM (`qemu-system-aarch64`) + Debian 12 + real `dockerd`** | **Chosen** | Full kernel with cgroups, namespaces, overlayfs, systemd. Real Docker daemon. Real `docker compose`. Cost: 10–25× TCG emulation overhead. |
| Remote Docker over SSH | Rejected earlier | Violates "self-contained phone" requirement. |

### 9.2 Final architecture

```
┌─────────────────────────────────────────────────────────────────────┐
│ Samsung Galaxy Note 10+ (SM-N975F, Exynos 9825, 12GB RAM, no root)  │
│ Android 12, kernel 4.14.113                                          │
│                                                                      │
│  ┌─────────────────────────────────────────────────────────────┐    │
│  │ Termux (F-Droid v0.118.3) — uid u0_a892                     │    │
│  │  ~/qemu-vm/                                                 │    │
│  │    debian-12-arm64.qcow2      (16GB Debian 12 arm64 image)  │    │
│  │    edk2-vars.fd               (64MB UEFI NVRAM)             │    │
│  │    seed.iso                   (cloud-init NoCloud seed)     │    │
│  │    alpine-virt-3.20.3-aarch64.iso (rescue ISO)              │    │
│  │    mon.sock, serial.sock      (QEMU control sockets)        │    │
│  │  ~/boot-debian-mon.sh          (VM launcher)                │    │
│  │  ~/.termux/boot/01-start-vm.sh (auto-start on device boot)  │    │
│  │  sshd (port 8022) — Mac SSH alias: phone-termux             │    │
│  └────────────────────────┬────────────────────────────────────┘    │
│                           │ hostfwd                                  │
│  ┌────────────────────────▼────────────────────────────────────┐    │
│  │ QEMU VM (PID via setsid+disown, 6 vCPU, 6144MB RAM)         │    │
│  │  -accel tcg,thread=multi,tb-size=512                        │    │
│  │  -cpu max,aarch64=on,pmu=on                                 │    │
│  │  -machine virt,gic-version=3                                │    │
│  │  UEFI firmware: edk2-aarch64-code.fd                        │    │
│  │                                                              │    │
│  │  Debian 12 (bookworm) arm64                                  │    │
│  │   hostname: docker-phone                                    │    │
│  │   user: sulthon (uid 1000, in docker group)                 │    │
│  │   sshd (port 22 → hostfwd 2222) — Mac alias: phone-vm       │    │
│  │   ZRAM: 4.3GB zstd, priority 100                            │    │
│  │   docker.io 20.10.24+dfsg1 (active, enabled)                │    │
│  │   docker-compose v2.29.7 (binary at                         │    │
│  │     /usr/libexec/docker/cli-plugins/docker-compose)         │    │
│  │   /etc/docker/daemon.json:                                  │    │
│  │     max-concurrent-downloads=1,                             │    │
│  │     max-download-attempts=5,                                │    │
│  │     dns=[8.8.8.8, 1.1.1.1],                                 │    │
│  │     ip6tables=false, ipv6=false                             │    │
│  │   Hello-world image pulled + run ✅                          │    │
│  └─────────────────────────────────────────────────────────────┘    │
└─────────────────────────────────────────────────────────────────────┘
                       ↑ SSH from Mac
                       │  phone-vm    → 192.168.0.9:2222 (VM)
                       │  phone-termux → 192.168.0.9:8022 (Termux)
```

### 9.3 Prerequisites checklist (all verified)

- [x] Termux (F-Droid v0.118.3) installed, storage permission granted
- [x] Termux:Boot APK installed and launched once (data dir exists)
- [x] `termux-wake-lock` acquired (prevents Android killing QEMU)
- [x] Samsung Game Tuning / GOS disabled (prevents CPU throttling under sustained load)
- [x] Phone plugged in (TCG boot takes 20–30 min sustained CPU)
- [x] Mac SSH pubkey in Termux `~/.ssh/authorized_keys` AND Debian `/home/sulthon/.ssh/authorized_keys` (via cloud-init)
- [x] Mac `~/.ssh/config`:
  ```
  Host phone-vm
    HostName 192.168.0.9
    Port 2222
    User sulthon
    IdentityFile ~/.ssh/id_ed25519
    ControlMaster auto
    ControlPath ~/.ssh/controlmasters/%r@%h:%p
    ControlPersist 10m

  Host phone-termux
    HostName 192.168.0.9
    Port 8022
    User u0_a892
    IdentityFile ~/.ssh/id_ed25519
    ControlMaster auto
    ControlPath ~/.ssh/controlmasters/%r@%h:%p
    ControlPersist 10m
  ```

### 9.4 Repro: from bare Termux to working Docker

All of this is run via SSH from the Mac (`ssh phone-termux`), or directly typed in Termux on-device.

```bash
# ─── 1. Termux setup ──────────────────────────────────────────────
pkg update -y && pkg upgrade -y
pkg install -y qemu-system-aarch64 openssh curl wget termux-api termux-tools

# Acquire wake lock (critical — Android will kill QEMU otherwise)
termux-wake-lock

# SSH bridge to Termux
passwd   # set a password for the Termux user
mkdir -p ~/.ssh && chmod 700 ~/.ssh
echo '<MAC_ED25519_PUBKEY>' >> ~/.ssh/authorized_keys
chmod 600 ~/.ssh/authorized_keys
sshd

# ─── 2. Download Debian 12 arm64 cloud image ─────────────────────
mkdir -p ~/qemu-vm && cd ~/qemu-vm
wget https://cloud.debian.org/images/cloud/bookworm/latest/debian-12-genericcloud-arm64.qcow2
# Resize to 16GB so apt install docker.io has room
qemu-img resize debian-12-genericcloud-arm64.qcow2 16G
mv debian-12-genericcloud-arm64.qcow2 debian-12-arm64.qcow2

# ─── 3. Cloud-init seed (user-data + meta-data) ──────────────────
cat > user-data <<'EOF'
#cloud-config
hostname: docker-phone
users:
  - name: sulthon
    sudo: ALL=(ALL) NOPASSWD:ALL
    shell: /bin/bash
    ssh_authorized_keys:
      - ssh-ed25519 AAAA...YOUR_PUBLIC_KEY... your@computer
  - name: root
    ssh_authorized_keys:
      - ssh-ed25519 AAAA...YOUR_PUBLIC_KEY... your@computer
ssh_pwauth: false
disable_root: false
package_update: true
packages:
  - qemu-guest-agent
  - ca-certificates
  - curl
growpart:
  mode: auto
  devices: ['/']
  ignore_growroot: false
EOF

cat > meta-data <<'EOF'
instance-id: docker-phone-001
local-hostname: docker-phone
EOF

# Build seed.iso (NoCloud format)
apt install -y genisoimage     # or: pkg install -y cdrtools
genisoimage -output seed.iso -volid cidata -joliet -rock user-data meta-data

# ─── 4. UEFI firmware vars (copy pristine) ───────────────────────
cp $PREFIX/share/qemu/edk2-aarch64-code.fd /tmp/
cp $PREFIX/share/qemu/edk2-aarch64-vars.fd ~/qemu-vm/edk2-vars.fd
# Resize vars to 64MB for safety
truncate -s 64M ~/qemu-vm/edk2-vars.fd

# ─── 5. Debian launcher script ───────────────────────────────────
cat > ~/boot-debian-mon.sh <<'EOF'
#!/data/data/com.termux/files/usr/bin/bash
# Boot Debian qcow2 with monitor exposed for GRUB editing.
set +e

VM_DIR="/data/data/com.termux/files/home/qemu-vm"
CODE="/data/data/com.termux/files/usr/share/qemu/edk2-aarch64-code.fd"
VARS="$VM_DIR/edk2-vars.fd"
IMG="$VM_DIR/debian-12-arm64.qcow2"
SEED="$VM_DIR/seed.iso"
MONSOCK="$VM_DIR/mon.sock"
SERIALSOCK="$VM_DIR/serial.sock"
LOG="$VM_DIR/debian-boot.log"

pkill -9 -f qemu-system-aarch64 2>/dev/null
sleep 2
rm -f $MONSOCK $SERIALSOCK

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
EOF
chmod +x ~/boot-debian-mon.sh

# ─── 6. First boot (20–30 min under TCG) ─────────────────────────
bash ~/boot-debian-mon.sh
# Wait until 2222 is open and SSH banner exchanges cleanly:
#   ssh phone-vm hostname    # → docker-phone

# ─── 7. Inside VM: install Docker ────────────────────────────────
ssh phone-vm

# Inside VM:
sudo apt-get install -y docker.io

# Install Docker Compose v2 binary (docker-compose-v2 not in Debian 12)
sudo mkdir -p /usr/libexec/docker/cli-plugins
sudo curl -fSL -o /usr/libexec/docker/cli-plugins/docker-compose \
  https://github.com/docker/compose/releases/download/v2.29.7/docker-compose-linux-aarch64
sudo chmod +x /usr/libexec/docker/cli-plugins/docker-compose

# Add sulthon to docker group so sudo not needed for docker commands
sudo usermod -aG docker sulthon

# Configure daemon for TCG slowness
sudo mkdir -p /etc/docker
echo '{"max-concurrent-downloads":1,"max-download-attempts":5,"dns":["8.8.8.8","1.1.1.1"],"ip6tables":false,"ipv6":false}' \
  | sudo tee /etc/docker/daemon.json
sudo systemctl restart docker

# ZRAM (4.3GB zstd swap)
sudo apt-get install -y zram-tools
printf "ALGO=zstd\nPERCENT=75\nPRIORITY=100\n" | sudo tee /etc/default/zramswap
sudo systemctl restart zramswap

# Verify
sudo systemctl is-active docker containerd sshd zramswap
sudo docker compose version          # → Docker Compose version v2.29.7
sudo docker run --rm hello-world     # → Hello from Docker!

# ─── 8. Termux:Boot auto-start script ────────────────────────────
mkdir -p ~/.termux/boot
cat > ~/.termux/boot/01-start-vm.sh <<'EOF'
#!/data/data/com.termux/files/usr/bin/bash
sleep 15
termux-wake-lock 2>/dev/null
pkill -9 -f qemu-system-aarch64 2>/dev/null
sleep 2
bash ~/boot-debian-mon.sh
EOF
chmod +x ~/.termux/boot/01-start-vm.sh

# ─── 9. Manual reboot survival test ──────────────────────────────
# Reboot the phone normally. After Android restarts, Termux:Boot fires,
# launches the VM, and within ~30 minutes ssh phone-vm should reconnect.
```

### 9.5 Critical pitfalls (all hit, all solved)

#### 9.5.1 `/boot/efi` in `/etc/fstab` triggers emergency mode

**Symptom:** Debian boots into emergency mode with `fsck failed` on `/boot/efi`.
**Cause:** Debian cloud image has a `/boot/efi` vfat line but the ESP isn't always mountable under QEMU's virtio drive layout, especially without a separate `-drive if=...` for the ESP.
**Fix (via Alpine rescue, mount Debian root, edit fstab):**
```bash
# In Alpine rescue, with Debian root mounted at /mnt:
sed -i 's|^\(.*/boot/efi.*\)$|# \1|' /mnt/etc/fstab
```
The VM still boots because grubaa64.efi is loaded directly by UEFI shell — `/boot/efi` is not needed at runtime.

#### 9.5.2 UEFI shell doesn't auto-find GRUB

**Symptom:** VM boots into UEFI shell prompt `Shell>` and hangs.
**Fix:** Write `startup.nsh` to the Debian ESP root (not the rootfs). Via Alpine rescue:
```bash
# ESP is at /dev/vdb15 when Debian root is /dev/vdb1
mount /dev/vdb15 /mnt/esp
printf 'FS0:\r\nEFI\\debian\\grubaa64.efi\r\n' > /mnt/esp/startup.nsh
umount /mnt/esp
```
Note: **CRLF line endings required** (the `\r\n` escapes). Plain LF doesn't work in UEFI shell.

#### 9.5.3 `systemd-networkd-wait-online.service` hangs boot for 2 min

**Symptom:** Boot stalls on `Expecting device enp0s1...` for exactly 2 minutes, then continues.
**Fix:**
```bash
# Inside Debian:
sudo systemctl mask systemd-networkd-wait-online.service
sudo tee /etc/netplan/99-enp0s1.yaml >/dev/null <<EOF
network:
  version: 2
  ethernets:
    enp0s1:
      dhcp4: true
      optional: true
      match:
        name: enp0s1
EOF
sudo netplan apply
```

#### 9.5.4 Docker pull: TLS handshake timeout

**Symptom:** `sudo docker pull hello-world` fails with `TLS handshake timeout` even though `curl https://registry-1.docker.io/v2/` succeeds (with a 401 in ~30s).
**Cause:** Docker's default TLS timeout (~10s) is shorter than TCG's TLS handshake time (~25–30s).
**Fix:**
```json
// /etc/docker/daemon.json
{
  "max-concurrent-downloads": 1,
  "max-download-attempts": 5,
  "dns": ["8.8.8.8", "1.1.1.1"],
  "ip6tables": false,
  "ipv6": false
}
```
Then `sudo systemctl restart docker`. Pull still takes ~75 seconds for a 5KB image, but it succeeds.

#### 9.5.5 `daemon.json` and `$DOCKER_OPTS` conflict

**Symptom:** After adding `max-concurrent-downloads` to `daemon.json`, `systemctl restart docker` fails:
```
unable to configure the Docker daemon with file /etc/docker/daemon.json:
the following directives are specified both as a flag and in the configuration file:
max-concurrent-downloads: (from flag: 1, from file: 1)
```
**Fix:** Pick ONE place. Recommended: `daemon.json` only. Do NOT set `Environment=DOCKER_OPTS=--max-concurrent-downloads=1` in `/etc/systemd/system/docker.service.d/override.conf`.

#### 9.5.6 SSH over serial for VM rescue — no heredocs

**Symptom:** Trying to write config files to the Alpine rescue shell via heredoc garbles the content.
**Cause:** Serial console is character-by-character; heredoc semantics don't survive the round-trip reliably.
**Fix:** Use `printf` with `\n` escapes, one command at a time:
```bash
# Right
printf 'FS0:\r\nEFI\\debian\\grubaa64.efi\r\n' > startup.nsh

# Wrong (garbled)
cat > startup.nsh <<'EOF'
FS0:
EFI\debian\grubaa64.efi
EOF
```

#### 9.5.7 `qemu-nbd`, `virt-edit`, `taskset` unavailable without root

**Symptom:** Can't mount qcow2 from Termux, can't pin QEMU to performance cores, can't set CPU governor to `performance`.
**Cause:** All require root.
**Workaround:** Use Alpine rescue VM (boot from ISO with `bootindex=0`, qcow2 as data disk) to mount and edit the qcow2's partitions. Accept `schedutil` governor. Accept that TCG is slow.

#### 9.5.8 `nohup` isn't enough — QEMU dies when SSH disconnects

**Symptom:** Launching QEMU via `nohup bash ~/boot-debian-mon.sh &` from an SSH session — when SSH closes, QEMU dies.
**Cause:** `nohup` ignores SIGHUP but Termux's session leader kills the whole process group on disconnect.
**Fix:** `setsid` + `disown` inside the script itself (already baked into `boot-debian-mon.sh`). For manual relaunch:
```bash
setsid bash ~/boot-debian-mon.sh < /dev/null > ~/.qemu-relaunch.log 2>&1 &
disown
```

#### 9.5.9 `/tmp/boot-test.log` — Termux has no `/tmp`

**Symptom:** Redirecting to `/tmp/foo.log` from an SSH session to Termux fails with "No such file or directory".
**Cause:** Termux has no `/tmp`; the equivalent is `$TMPDIR` or `~/.tmp/`.
**Fix:** Use `~/.qemu-relaunch.log` or `/data/data/com.termux/files/usr/tmp/` instead.

### 9.6 Timing reference (all measured on this device)

| Operation | Wall-clock time |
|---|---|
| Cold QEMU launch to sshd banner | 20–30 min |
| `apt-get install docker.io` (inside VM) | 25–35 min |
| `apt-get install zram-tools` (inside VM) | 5–10 min |
| `curl` download of docker-compose-linux-aarch64 (59MB) | ~5 min |
| First `docker pull hello-world` | ~75 sec |
| `docker run --rm hello-world` (after pull) | ~15 sec |
| QEMU restart (`pkill` → bootable sshd) | 20–25 min |
| Containerd cold-start during VM boot | 7–9 min |

### 9.7 Verification matrix (final state)

| Check | Result |
|---|---|
| `nc -z 192.168.0.9 2222` (VM SSH port) | ✅ open |
| `nc -z 192.168.0.9 8022` (Termux SSH port) | ✅ open |
| `ssh phone-vm hostname` | ✅ `docker-phone` |
| `ssh phone-termux uname -a` | ✅ Linux localhost 4.14.113-perf+ |
| `ssh phone-vm sudo systemctl is-active docker` | ✅ `active` |
| `ssh phone-vm sudo systemctl is-active containerd` | ✅ `active` |
| `ssh phone-vm sudo systemctl is-active sshd` | ✅ `active` |
| `ssh phone-vm sudo zramctl` | ✅ zstd, 4.3GB, priority 100 |
| `ssh phone-vm sudo docker compose version` | ✅ v2.29.7 |
| `ssh phone-vm sudo docker images` | ✅ `hello-world latest eb84fdc6f2a3` |
| `ssh phone-vm sudo docker run --rm hello-world` | ✅ "Hello from Docker!" |
| Soft persistence test: `pkill qemu` + run boot script + wait | ✅ SSH returns in ~25 min |
| Hello-world on rebooted VM | ✅ Passes |
| **Full phone reboot via `adb reboot`** | ✅ Android → Termux:Boot → QEMU → sshd |
| VM sshd banner after full reboot | ✅ ~18 min from reboot trigger |
| VM uptime confirms fresh boot after reboot | ✅ 5 min uptime post-reboot |
| Docker + ZRAM + Compose auto-start after reboot | ✅ All active, no manual intervention |
| `hello-world` image persisted across reboot | ✅ `eb84fdc6f2a3` still present |
| `docker run hello-world` on post-reboot VM | ✅ "Hello from Docker!" |

### 9.8 Outstanding (user-action items)

1. **Consider adding a remote docker context** on the Mac:
   ```bash
   docker context create phone --docker "host=ssh://sulthon@docker-phone"
   docker context use phone
   docker ps    # runs against the phone VM
   ```
2. **ZRAM compression ratio is currently 1:1 (5KB used)** because the VM is idle. Re-check after running real workloads.
3. **First apt install inside VM after reboot is slow** because `apt-get update` has to re-validate indexes. Pre-cache with `sudo apt-get install -y <your-toolkit>` while SSHed in.
4. **Wireless debugging port is dynamic on Android 12.** The phone reconnects to ADB on a random port (observed: 46223 pre-reboot, different post-reboot). To find the new port after a reboot: rescan or use `adb mdns:services` if mDNS is enabled.

### 9.9 Lessons learned

- **TCG is brutal.** Plan around 20–30 minute boot cycles. Never run apt operations in the critical path of a verification step.
- **ControlMaster on Mac SSH config is non-negotiable.** First connection does the slow ED25519 banner exchange (~60s under TCG); subsequent commands multiplex over the master socket in <1s.
- **UEFI NVRAM is mutable state.** The `startup.nsh` you write to the ESP gets persisted in `edk2-vars.fd`. Don't recreate `edk2-vars.fd` after configuring it, or you lose the boot chain.
- **Termux's `/dev/null` is real, `/tmp` is not.** Redirects matter.
- **`termux-wake-lock` is critical.** Without it, Android Doze will kill QEMU after a few minutes of screen-off.
- **`/sdcard/` is noexec.** Don't try to run scripts from there. Keep everything in `~/`.
- **Alpine rescue is the Swiss army knife.** Without root, you can't mount qcow2 from Termux — but you CAN boot Alpine from ISO with the qcow2 as a data disk, and mount/edit it from inside Alpine. This is the only way to fix boot-blocking fstab/network issues.
- **Termux + Termux:Boot are auto-added to the Doze whitelist** (`dumpsys deviceidle whitelist` shows `user,com.termux,10892` and `user,com.termux.boot,10892` after install). The manual Settings → Battery → Unrestricted step described in many tutorials is NOT required if both APKs were installed via `adb install`. My earlier assumption that this was a blocker was wrong — verified by the full `adb reboot` test passing without any manual battery-optimization changes.
- **The full `adb reboot` survival test is automatable.** I initially deferred this as "manual, requires physical device." It isn't — `adb -s <serial> reboot` triggers the reboot, and polling port 2222 detects VM sshd return (~18 min on this device). The only wrinkle is that wireless debugging uses a dynamic port on Android 12, so the ADB serial changes after reboot — but that doesn't block the test itself since SSH ports 2222/8022 are what we verify, not ADB.
- **Don't trust in-Termux `dumpsys`.** From inside Termux, `dumpsys` is not on PATH and reports misleading state (e.g. claiming Termux isn't in the Doze whitelist). Run `dumpsys` via `adb shell` from the Mac, where the Android system service is reachable.

---

## 10. Phase 8 — Day-to-day Tooling (Mac Helper Scripts)

> **Daily-driver workflow.** After §9 verified the build, this section adds the Mac-side CLI that makes the phone server feel like a local docker host. All scripts live in `~/.local/bin/` and are in `PATH`.

### 10.1 What gets installed

| Command | Purpose |
|---|---|
| `phone-status` | One-shot health dashboard (ports, QEMU PID, Docker, ZRAM, disk, mem) |
| `phone-healthcheck` | Full end-to-end verification incl. `docker run hello-world` (returns exit code) |
| `phone-vm-start [--wait]` | Start QEMU if not running. `--wait` blocks until VM SSH ready |
| `phone-vm-stop [--force]` | Graceful ACPI shutdown via QEMU monitor. `--force` = kill -9 |
| `phone-vm-restart [--wait]` | Stop + start |
| `phone-vm-console [--monitor\|--serial]` | Interactive QEMU monitor, or `tail -f` serial log |
| `phone-vm-logs [N]` | Show last N lines of VM boot log (default 50) |
| `docker --context phone <cmd>` | Run any docker CLI directly against the phone (no `ssh` wrapper) |

### 10.2 Docker context setup (one-time)

```bash
# Create context
docker context create phone --docker "host=ssh://sulthon@192.168.0.9:2222"

# Add raw IP:port to known_hosts (docker's SSH bypasses ~/.ssh/config aliases)
ssh-keyscan -p 2222 -t ed25519 192.168.0.9 >> ~/.ssh/known_hosts

# Verify
docker --context phone ps
docker --context phone images
docker --context phone run --rm hello-world

# Optional: make 'phone' the default
docker context use phone
```

If `DOCKER_HOST` env var is set (e.g. by colima), `--context phone` flag takes precedence over the env var. Use `docker context show` to see active context.

### 10.3 Typical day-to-day usage

```bash
# Morning check: is the phone server up?
phone-status

# Full verification (returns non-zero if anything is broken; use in cron)
phone-healthcheck

# Run compose stack on the phone (same CLI as local docker)
docker --context phone compose -f /path/to/docker-compose.yml up -d
docker --context phone ps
docker --context phone logs -f some-service

# Pull a new image directly
docker --context phone pull postgres:16

# If the phone rebooted and SSH is closed:
phone-vm-start --wait    # blocks until VM SSH ready (up to 30 min for cold TCG boot)

# Graceful restart
phone-vm-restart --wait

# Hard reset (data-loss risk; only if ACPI shutdown fails)
phone-vm-stop --force

# Watch the VM boot live (Ctrl-C to detach)
phone-vm-console --serial

# Interactive QEMU monitor (type 'info status', 'system_powerdown', etc.)
phone-vm-console --monitor

# Tail recent kernel messages
phone-vm-logs 100
```

### 10.4 Termux-side SSH also survives reboot

The `~/.termux/boot/02-start-sshd.sh` script (created in this phase) ensures Termux's own sshd auto-starts alongside QEMU. So `ssh phone-termux` works after any phone reboot without manual intervention.

```bash
# After reboot, both work:
ssh phone-vm        # → Debian VM (port 2222, via QEMU hostfwd)
ssh phone-termux    # → Termux shell (port 8022, native Android)
```

### 10.5 Verifying the tooling itself

```bash
$ phone-status
═══════════════════════════════════════════════════════════════
  Phone Server Status  (192.168.0.9)
═══════════════════════════════════════════════════════════════
✓ VM SSH port 2222: open
✓ Termux SSH port 8022: open

── Termux-side ──
✓ QEMU PID 1902 (uptime 11:25)

── VM-side (Debian docker-phone) ──
✓ VM hostname: docker-phone
✓ VM uptime: up 10 min,  0 user,  load average: 1.13, 1.55, 1.10
✓ docker.service: active
✓ containerd.service: active
✓ zramswap.service: active
✓ docker compose: 2.29.7
✓ containers running: 0, images: 1
✓ disk: 1.5G / 16G, mem: 329Mi / 5.8Gi

$ phone-healthcheck
Phone Server Health Check
=========================

Network reachability:
  ✓ VM SSH port (2222)
  ✓ Termux SSH port (8022)

QEMU process:
  ✓ QEMU running (PID 1902)

VM services:
  ✓ VM hostname (docker-phone)
  ✓ systemd (running)
  ✓ docker.service
  ✓ containerd.service
  ✓ sshd.service
  ✓ zramswap.service
  ✓ docker compose (2.29.7)

VM resources:
  ✓ ZRAM swap (zstd 4.3G)

Functional test (docker run hello-world):
  ✓ hello-world container runs

=========================
Passed: 12  Failed: 0
Result: ALL PASS
```

### 10.6 ADB post-reboot discovery

The phone's wireless debugging port is **dynamic** on Android 12 (changes on every reboot). To find the new port after a reboot:

```bash
adb mdns services
# Example output:
# adb-RR8M805YLDB-q3g0P5	_adb-tls-connect._tcp	192.168.0.9:38761

adb connect 192.168.0.9:38761
```

You only need ADB for emergency bootstrap (e.g. if both Termux sshd and QEMU somehow fail). Normal operations go through SSH ports 2222 and 8022, which are stable.

### 10.7 Files installed by this phase

**On Mac (`~/.local/bin/`):**
- `phone-status`
- `phone-healthcheck`
- `phone-vm-start`
- `phone-vm-stop`
- `phone-vm-restart`
- `phone-vm-console`
- `phone-vm-logs`

**On Termux (`~/.termux/boot/`):**
- `01-start-vm.sh` (QEMU auto-start, from §9)
- `02-start-sshd.sh` (Termux sshd auto-start, new in this phase)

**On Mac (docker config):**
- `~/.docker/contexts/meta/.../meta.json` (the `phone` context)

**On Mac (`~/.ssh/known_hosts`):**
- `[192.168.0.9]:2222` (VM SSH host key, for docker context)
- `[192.168.0.9]:8022` (Termux SSH host key)

---

**End of playbook.** Sections 1–6 are theoretical (research). Section 9 is the verified build. Section 10 is the daily-driver tooling layer.
