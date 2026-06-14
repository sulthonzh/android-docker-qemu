# Run Real Docker on Android — No Root, No Tricks, Just QEMU

> Turn any non-rooted Android phone into a real Docker host running Debian 12 in a QEMU virtual machine. Survives phone reboots. Uses real `dockerd` + Docker Compose v2, not a proot/udocker lookalike.

📖 **Full step-by-step tutorial** → https://dev.to/sulthonzh/run-real-docker-on-android-no-root-no-tricks-just-qemu-15jn

---

## The architecture

```
                      Your computer
                      (Mac or Linux)
                            │
                            │  ssh
                            ▼
  ╔══════════════════════════════════════════════════════╗
  ║           ANDROID PHONE  (not rooted)                ║
  ║                                                      ║
  ║   ┌──────────────────────────────────────────────┐   ║
  ║   │  TERMUX   (regular Android app)              │   ║
  ║   │                                              │   ║
  ║   │     • qemu-system-aarch64   emulator         │   ║
  ║   │     • debian.qcow2          disk image       │   ║
  ║   │     • boot scripts          auto-start VM    │   ║
  ║   │     • sshd :8022            mgmt port        │   ║
  ║   └──────────────────────┬───────────────────────┘   ║
  ║                          │ launches                  ║
  ║                          ▼                           ║
  ║   ┌──────────────────────────────────────────────┐   ║
  ║   │  QEMU VM   (real ARM64 hardware emulation)   │   ║
  ║   │                                              │   ║
  ║   │     • Debian 12 (bookworm)                   │   ║
  ║   │     • real dockerd + Docker Compose v2       │   ║
  ║   │     • systemd  (works, unlike proot)         │   ║
  ║   │     • sshd :22  → forwarded to host :2222    │   ║
  ║   └──────────────────────────────────────────────┘   ║
  ╚══════════════════════════════════════════════════════╝

  Two SSH targets (run from your computer):

    ssh phone-termux   →   port 8022   →   Termux shell
    ssh phone-vm       →   port 2222   →   Debian VM
```

**Why QEMU and not proot-distro / udocker?** Those don't give you a real kernel — no systemd, no cgroups, no real namespaces. Docker refuses to start, or containers aren't isolated. QEMU gives you a real Linux kernel at the cost of speed (~10–25× overhead from TCG software emulation).

---

## What you get

- ✅ A real Debian 12 VM running inside your phone
- ✅ Real `dockerd` + Docker Compose v2 (not a compatibility layer)
- ✅ Survives phone reboots (via Termux:Boot)
- ✅ Manageable from your computer via SSH, like any remote Docker host
- ✅ Works on any non-rooted Android phone with ~6 GB RAM

---

## Requirements

| Requirement | Why |
|---|---|
| Android phone, **not rooted**, ~6 GB+ RAM | QEMU needs RAM; rooting would void the point |
| Termux (from F-Droid, not Play Store) | Play Store version is deprecated and broken |
| Termux:Boot (from F-Droid) | Auto-starts the VM after phone reboot |
| Computer on the same Wi-Fi as the phone | For SSH (Tailscale works too, out of scope here) |
| ~5 GB free storage on the phone | Debian image + Docker images |
| Patience (cold boot takes 20–30 min) | TCG software emulation is slow — fundamental limitation |

---

## Quick start

This repo ships a `run.sh` that auto-detects where it's running (Termux on phone vs Mac/Linux computer) and does the right thing. Two manual prereqs you can't avoid (Android restrictions), then it's one command per device.

### Prerequisites (manual, ~5 minutes)

On your phone:

1. **Install Termux** from [F-Droid](https://f-droid.org/packages/com.termux/) (NOT the Play Store version — it's deprecated and broken)
2. **Install Termux:Boot** from [F-Droid](https://f-droid.org/packages/com.termux.boot/), then **open it once** (this registers the BOOT_COMPLETED receiver — Android requires the manual open)
3. Open Termux and run:
   ```bash
   termux-setup-storage    # tap "Allow" on the Android dialog
   pkg update && pkg install -y git
   ```

On your computer: install Docker ([Docker Desktop](https://www.docker.com/products/docker-desktop/), [Colima](https://github.com/abiosoft/colima), or [OrbStack](https://orbstack.dev/) on Mac; `docker.io` on Linux) and generate an SSH key (`ssh-keygen -t ed25519`).

### Setup (one command per device)

**On the phone** (inside Termux):

```bash
git clone https://github.com/sulthonzh/android-docker-qemu
cd android-docker-qemu
./run.sh
```

`run.sh` detects Termux and runs `setup-phone.sh`. It will:
- Install QEMU and dependencies (~2 min)
- Download + resize the Debian 12 cloud image (~5 min)
- Build the cloud-init seed with your SSH key (prompts for GitHub username, or paste)
- Install the QEMU launcher + boot scripts
- Start the VM
- Print the phone's IP address

The VM then boots for **20–30 minutes** (TCG software emulation — fundamental limitation).

**On your computer** (Mac or Linux):

```bash
git clone https://github.com/sulthonzh/android-docker-qemu
cd android-docker-qemu
./run.sh
```

`run.sh` detects Mac/Linux and runs `setup-computer.sh`. It will:
- Install the `phone-*` helper scripts to `~/.local/bin/`
- Add `phone-vm` and `phone-termux` entries to `~/.ssh/config`
- Copy your SSH public key to Termux (so you can manage the phone)
- Create a Docker context named `phone` pointing at the VM via SSH
- Run a connectivity test

**Day-to-day usage:**

```bash
phone-healthcheck                  # full end-to-end health check
phone-status                       # quick human-readable state summary
phone-vm-start --wait              # start VM if not running, wait until ready
phone-vm-stop                      # graceful ACPI shutdown

docker --context phone run --rm hello-world
docker --context phone compose -f docker/docker-compose.example.yml up -d
```

📖 **Read the full tutorial for the why behind every step** → https://dev.to/sulthonzh/run-real-docker-on-android-no-root-no-tricks-just-qemu-15jn

### Non-interactive usage (for scripts / CI)

```bash
# Phone: fetch SSH key from GitHub, no prompts
./run.sh --github your-github-username

# Computer: provide phone IP directly, no prompts
./run.sh --phone-ip 192.168.0.9

# Either: preview without changes
./run.sh --dry-run
```

---

## What's in this repo

```
.
├── run.sh                       One entry point — detects phone vs computer, dispatches
├── setup-phone.sh               Phone setup (runs inside Termux)
├── setup-computer.sh            Computer setup (Mac/Linux)
├── README.md                    You are here
├── PLAYBOOK.md                  The full 1500-line engineering playbook (deep dive)
├── termux/                      Files that install ON THE PHONE (Termux side)
│   ├── boot-debian-mon.sh       QEMU launcher script
│   ├── 01-start-vm.sh           Termux:Boot auto-start hook
│   └── cloud-init/
│       ├── user-data            VM cloud-init config (TEMPLATE — replace SSH key!)
│       └── meta-data            VM instance metadata
├── vm/                          Files that install INSIDE THE VM
│   ├── docker-daemon.json       /etc/docker/daemon.json — tuned for TCG
│   └── zramswap.default         /etc/default/zramswap — ZRAM swap config
├── mac/                         Mac/Linux helper scripts (installed by setup-computer.sh)
│   ├── phone-healthcheck        End-to-end verification with exit code
│   ├── phone-status             Human-readable current state
│   ├── phone-vm-start           Start the VM (with optional --wait)
│   ├── phone-vm-stop            Graceful ACPI shutdown
│   ├── phone-vm-restart         Stop + start
│   ├── phone-vm-console         Attach to QEMU monitor (Ctrl-C to detach)
│   └── phone-vm-logs            Tail recent VM kernel logs
├── docker/
│   └── docker-compose.example.yml   Minimal test stack (traefik/whoami)
└── docs/
    └── TROUBLESHOOTING.md       Solutions for the 5 most common failures
```

---

## Performance expectations (be honest with yourself)

| Operation | Time | Why |
|---|---|---|
| Cold QEMU boot | 20–30 min | TCG translates every ARM instruction in software |
| `docker pull hello-world` | ~75 sec | TLS handshake is slow under emulation |
| `docker pull <real image>` | 5–15 min | First pull is always slowest |
| `docker compose up` (cached) | ~10 sec | After images are cached, it's fine |
| Container runtime perf | 10–25× slower than native | Software emulation tax |

This is **not** a production server. It's a learning environment, a CI experiment, a self-hosted playground that uses hardware you already own. If you need real performance, root the phone or use a Raspberry Pi.

---

## Why this exists

Every "Docker on Android" tutorial I found was lying — either it required root, or it used `proot-distro`/`udocker` which **aren't Docker** (no systemd, no cgroups, no real isolation). This repo is the only path I found that gives you **a real Docker daemon running real containers on a non-rooted phone**: Debian in QEMU, inside Termux.

---

## Troubleshooting

See **[docs/TROUBLESHOOTING.md](docs/TROUBLESHOOTING.md)** for the 5 most common failures and their fixes. For everything else, open an [Issue](https://github.com/sulthonzh/android-docker-qemu/issues).

---

## Star this repo ⭐

If this saved you a weekend of trial and error, give it a star. It helps other people find it — "no-root Docker on Android" is a common question and most of the answers are bad.

---

## License

MIT — see [LICENSE](LICENSE). Do whatever you want. Attribution appreciated but not required.

---

## Acknowledgments

- The **Termux** team — without Termux this entire approach would be impossible.
- The **QEMU** project — software emulation of aarch64 is a marvel.
- **Debian Cloud Team** — for publishing clean cloud images that just work.
