# Security & Transparency

This document explains exactly what the installer and setup scripts do, what they don't do, and where to look if you want to verify any of it.

---

## TL;DR

The installer (`install.sh`) is `curl | bash`-safe. It downloads the repo from GitHub over HTTPS, extracts it to a temp directory, runs `run.sh`, and cleans up. It does **not** use `sudo`, modify system files, or phone home.

---

## The full call graph

When you run `curl -fsSL .../install.sh | bash`, here's everything that happens, in order:

```
1. install.sh (curl-piped)
   ├─ Checks dependencies: curl, tar, bash
   ├─ Detects environment: Termux / Mac / Linux
   ├─ Creates a temp directory via mktemp -d
   ├─ Downloads repo tarball from:
   │    https://codeload.github.com/sulthonzh/android-docker-qemu/tar.gz/refs/heads/main
   │  (HTTPS-only, GitHub's own CDN, pinned to main branch)
   ├─ Extracts tarball to the temp directory
   ├─ Verifies run.sh exists in the extracted repo (corruption check)
   ├─ Runs: bash ./run.sh "$@"
   └─ Cleans up the temp directory (unless --keep)
       (runs even on error/Ctrl-C, via trap)

2. run.sh (local dispatcher)
   ├─ Detects environment (same logic as install.sh)
   └─ Execs setup-phone.sh (if Termux) OR setup-computer.sh (if Mac/Linux)

3a. setup-phone.sh (only runs inside Termux on Android)
    ├─ pkg install: qemu-system-aarch64 qemu-utils genisoimage openssh wget curl termux-api
    ├─ termux-wake-lock (prevents Android from killing QEMU)
    ├─ Downloads Debian 12 cloud image from cloud.debian.org (~1.2 GB)
    ├─ Resizes image to 16 GB
    ├─ Builds cloud-init seed.iso with user's SSH key
    ├─ Copies boot scripts to ~/boot-debian-mon.sh and ~/.termux/boot/
    ├─ Starts sshd (Termux's own)
    └─ Launches QEMU (setsid + disown so it survives SSH disconnect)

3b. setup-computer.sh (runs on Mac/Linux)
    ├─ Copies 7 helper scripts to ~/.local/bin/
    ├─ Patches the helper scripts with your phone's IP/port
    ├─ Appends entries to ~/.ssh/config (phone-vm, phone-termux)
    ├─ Runs ssh-copy-id to Termux (you enter the Termux password once)
    ├─ Runs ssh-keyscan to seed ~/.ssh/known_hosts
    ├─ Creates Docker context named "phone"
    └─ Tests SSH + Docker connectivity
```

---

## What the scripts DO

| Action | Where | Why |
|---|---|---|
| Install packages via `pkg install` | Termux only | QEMU, openssh, etc. — no root required |
| Download Debian 12 cloud image | `~/qemu-` | Official image from cloud.debian.org |
| Create `~/qemu-vm/` | Phone | Disk image, seed.iso, UEFI vars, logs |
| Copy scripts to `~/boot-debian-mon.sh` | Phone | QEMU launcher |
| Copy scripts to `~/.termux/boot/` | Phone | Auto-start on phone reboot |
| Copy scripts to `~/.local/bin/` | Computer | Helper commands |
| Append to `~/.ssh/config` | Computer | `phone-vm` and `phone-termux` aliases |
| Append to `~/.ssh/known_hosts` | Computer | Avoid first-connection prompt |
| Run `ssh-copy-id` to Termux | Computer | Key-based auth for management |
| Create Docker context `phone` | Computer | `docker --context phone` syntax |
| Start QEMU + sshd | Phone | The actual server |

## What the scripts DON'T do

| Forbidden action | Enforcement |
|---|---|
| **`sudo` anywhere** | No `sudo` in any script. `grep -r sudo *.sh` returns nothing (except in comment examples). |
| **Modify `/etc/`, `/usr/`, `/System/`** | No writes to system paths. All writes are under `$HOME` (or `$PREFIX` inside Termux). |
| **Phone home / telemetry** | No outbound network calls except: (1) downloading the Debian cloud image from cloud.debian.org, (2) `ssh-copy-id` to your phone's IP, (3) `ssh-keyscan` to your phone's IP, (4) `docker pull` from Docker Hub. All user-visible. |
| **Execute code from elsewhere** | Only this repo + GitHub CDN (tarball) + Debian's official mirror + Docker Hub. No `eval $(curl ...)`, no sourcing remote scripts. |
| **Hide what's being installed** | Every command is printed via `log()`/`ok()`/`warn()` before execution. `set -x` available via `bash -x install.sh`. |
| **Survive without cleanup** | Temp directory is removed via `trap cleanup EXIT INT TERM` — runs even on Ctrl-C or error. |
| **Store secrets in the repo** | SSH keys are user-supplied (via `--github`, `--key`, or interactive prompt). Cloud-init template uses `<YOUR_PUBLIC_KEY_HERE>` placeholder. Verified by pre-commit secret scan. |

---

## How to verify any of this yourself

### 1. Read the installer before running

```bash
curl -fsSL https://raw.githubusercontent.com/sulthonzh/android-docker-qemu/main/install.sh -o install.sh
less install.sh
```

The whole thing is ~190 lines, heavily commented.

### 2. Dry-run the installer

```bash
curl -fsSL https://raw.githubusercontent.com/sulthonzh/android-docker-qemu/main/install.sh \
  | bash -s -- --dry-run
```

Every command that *would* run is printed, nothing is actually executed.

### 3. Inspect the downloaded tarball before running anything

```bash
curl -fsSL https://raw.githubusercontent.com/sulthonzh/android-docker-qemu/main/install.sh \
  | bash -s -- --keep    # extracts to temp dir, doesn't delete it
# Look at the temp dir path printed at the end, then inspect it
```

### 4. Pin to a specific commit SHA (highest reproducibility)

Instead of `main`, you can pin to a specific commit:

```bash
curl -fsSL https://raw.githubusercontent.com/sulthonzh/android-docker-qemu/COMMIT_SHA/install.sh | bash
```

Replace `COMMIT_SHA` with the full 40-character SHA from [the commit history](https://github.com/sulthonzh/android-docker-qemu/commits/main).

### 5. Diff against a known-good version

```bash
# Local install.sh vs remote
diff install.sh <(curl -fsSL https://raw.githubusercontent.com/sulthonzh/android-docker-qemu/main/install.sh)
```

---

## Reporting a security issue

If you find a security vulnerability, **do not open a public issue**. Email `sulthonzh` via the email listed on [github.com/sulthonzh](https://github.com/sulthonzh) (or use GitHub's [private vulnerability reporting](https://github.com/sulthonzh/android-docker-qemu/security/advisories/new)).

---

## A note on `curl | bash`

Piping curl to bash is inherently trust-on-first-use. **You're executing whatever the server returns.** Mitigations in this installer:

- ✅ HTTPS-only (raw.githubusercontent.com enforces TLS)
- ✅ Repo is public and auditable
- ✅ Installer is heavily commented, short (~190 lines)
- ✅ `--dry-run` shows every action before execution
- ✅ Pinned to a specific branch (pin to a SHA for full reproducibility)

If you don't trust it: don't pipe. Download, read, then run.

```bash
curl -fsSL https://raw.githubusercontent.com/sulthonzh/android-docker-qemu/main/install.sh -o install.sh
less install.sh
bash install.sh
```
