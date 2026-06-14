#!/data/data/com.termux/files/usr/bin/bash
# setup-phone.sh — Install Debian 12 + Docker + QEMU inside Termux (no root)
#
# Run this script INSIDE Termux on your Android phone.
# It installs everything and starts the VM.
#
# Usage:
#   ./setup-phone.sh                          # interactive (prompts for SSH key)
#   ./setup-phone.sh --github USERNAME         # fetch SSH key from github.com/USERNAME.keys
#   ./setup-phone.sh --key "ssh-ed25519 ..."   # provide SSH key directly
#   ./setup-phone.sh --dry-run                 # show what would happen, do nothing
#   ./setup-phone.sh --resume                  # skip already-done steps
#
# Prerequisites (must be done manually BEFORE running this):
#   1. Install Termux from F-Droid (NOT Play Store — it's deprecated)
#   2. Install Termux:Boot from F-Droid, open it once (registers BOOT_COMPLETED)
#   3. In Termux: run `termux-setup-storage` and tap "Allow"
#   4. In Termux: run `pkg update && pkg install -y git`
#
# Source: https://github.com/sulthonzh/android-docker-qemu
# Tutorial: https://dev.to/sulthonzh/run-real-docker-on-android-no-root-no-tricks-just-qemu-15jn

set -uo pipefail

# ─── Color helpers ──────────────────────────────────────────────────────────
if [[ -t 1 ]]; then
  GREEN="\033[32m"; YELLOW="\033[33m"; RED="\033[31m"; BLUE="\033[34m"; BOLD="\033[1m"; RESET="\033[0m"
else
  GREEN=""; YELLOW=""; RED=""; BLUE=""; BOLD=""; RESET=""
fi
log()   { printf "${BLUE}[%s]${RESET} %s\n" "$(date +%H:%M:%S)" "$*"; }
ok()    { printf "${GREEN}[%s] ✓${RESET} %s\n" "$(date +%H:%M:%S)" "$*"; }
warn()  { printf "${YELLOW}[%s] !${RESET} %s\n" "$(date +%H:%M:%S)" "$*"; }
err()   { printf "${RED}[%s] ✗${RESET} %s\n" "$(date +%H:%M:%S)" "$*" >&2; }
die()   { err "$*"; exit 1; }
step()  { printf "\n${BOLD}${BLUE}━━━ Step %d/%d: %s ━━━${RESET}\n" "$1" "$TOTAL_STEPS" "$2"; }

TOTAL_STEPS=7

# ─── Arg parsing ────────────────────────────────────────────────────────────
GITHUB_USER=""
SSH_KEY=""
DRY_RUN=false
RESUME=false

while [[ $# -gt 0 ]]; do
  case "$1" in
    --github)  GITHUB_USER="$2"; shift 2 ;;
    --key)     SSH_KEY="$2"; shift 2 ;;
    --dry-run) DRY_RUN=true; shift ;;
    --resume)  RESUME=true; shift ;;
    -h|--help)
      sed -n '2,20p' "$0" | sed 's/^# \{0,1\}//'
      exit 0 ;;
    *) die "Unknown argument: $1 (try --help)" ;;
  esac
done

# ─── Safety checks ──────────────────────────────────────────────────────────
[[ "$(id -un)" == "" ]] && die "Cannot determine user. Are you in Termux?"
[[ -z "${PREFIX:-}" ]] && die "PREFIX not set. This script must run inside Termux."
[[ "${PREFIX}" != *"com.termux"* ]] && die "This script must run inside Termux (PREFIX=$PREFIX)."

if $DRY_RUN; then
  warn "DRY RUN — no actions will be taken"
fi

# ─── Resolve SSH public key ─────────────────────────────────────────────────
resolve_ssh_key() {
  if [[ -n "$SSH_KEY" ]]; then
    [[ "$SSH_KEY" =~ ^ssh-(ed25519|rsa) ]] || die "--key must start with 'ssh-ed25519' or 'ssh-rsa'"
    echo "$SSH_KEY"
    return
  fi
  if [[ -n "$GITHUB_USER" ]]; then
    log "Fetching SSH key for GitHub user '$GITHUB_USER'..."
    local key
    key=$(curl -fsSL "https://github.com/$GITHUB_USER.keys" 2>/dev/null | head -1) || true
    [[ -n "$key" ]] || die "No SSH keys found at github.com/$GITHUB_USER.keys — check username or use --key"
    echo "$key"
    return
  fi
  # Interactive
  echo ""
  echo "Your VM needs an SSH public key so you can log in from your computer."
  echo "Options:"
  echo "  1. Enter your GitHub username (we'll fetch the key from github.com/USERNAME.keys)"
  echo "  2. Paste the key directly (from ~/.ssh/id_ed25519.pub on your computer)"
  echo ""
  read -r -p "Choose [1/2]: " choice
  case "$choice" in
    1)
      read -r -p "GitHub username: " gu
      [[ -n "$gu" ]] || die "No username entered"
      local key
      key=$(curl -fsSL "https://github.com/$gu.keys" 2>/dev/null | head -1) || true
      [[ -n "$key" ]] || die "No keys at github.com/$gu.keys"
      echo "$key"
      ;;
    2)
      echo "Paste your PUBLIC key (starts with 'ssh-ed25519' or 'ssh-rsa'). End with Ctrl-D:"
      local pasted
      pasted=$(cat)
      [[ "$pasted" =~ ^ssh-(ed25519|rsa) ]] || die "Pasted text doesn't look like an SSH public key"
      echo "$pasted"
      ;;
    *) die "Invalid choice" ;;
  esac
}

# ─── Step 1: Install packages ───────────────────────────────────────────────
step 1 "Installing Termux packages (qemu, openssh, wget, genisoimage)"
if $RESUME && command -v qemu-system-aarch64 >/dev/null; then
  ok "qemu already installed, skipping"
else
  if $DRY_RUN; then
    log "Would run: pkg install -y qemu-system-aarch64 qemu-utils genisoimage openssh wget curl termux-api"
  else
    pkg install -y qemu-system-aarch64 qemu-utils genisoimage openssh wget curl termux-api || die "pkg install failed"
    ok "Packages installed"
  fi
fi

# ─── Step 2: Acquire wake lock ──────────────────────────────────────────────
step 2 "Acquiring wake lock (prevents Android from killing QEMU)"
if $DRY_RUN; then
  log "Would run: termux-wake-lock"
else
  termux-wake-lock 2>/dev/null || warn "termux-wake-lock not available — install termux-api"
  ok "Wake lock held"
fi

# ─── Step 3: Download + resize Debian cloud image ───────────────────────────
step 3 "Download Debian 12 arm64 cloud image (~1.2 GB, may take several minutes)"
VM_DIR="$HOME/qemu-vm"
mkdir -p "$VM_DIR"
cd "$VM_DIR" || die "Cannot cd to $VM_DIR"

IMG="debian-12-arm64.qcow2"
DEBIAN_URL="https://cloud.debian.org/images/cloud/bookworm/latest/debian-12-genericcloud-arm64.qcow2"

if $RESUME && [[ -f "$IMG" ]]; then
  ok "Debian image already present ($IMG), skipping download"
else
  if $DRY_RUN; then
    log "Would download: $DEBIAN_URL"
    log "Would resize: qemu-img resize $IMG 16G"
  else
    log "Downloading Debian 12 cloud image..."
    wget -q --show-progress -O "debian-12-genericcloud-arm64.qcow2" "$DEBIAN_URL" || die "Download failed"
    log "Resizing to 16 GB..."
    qemu-img resize "debian-12-genericcloud-arm64.qcow2" 16G || die "Resize failed"
    mv "debian-12-genericcloud-arm64.qcow2" "$IMG"
    ok "Image ready: $VM_DIR/$IMG (16 GB)"
  fi
fi

# ─── Step 4: Build cloud-init seed with user's SSH key ──────────────────────
step 4 "Build cloud-init seed (injects your SSH key into the VM)"

if $DRY_RUN; then
  log "Would prompt for SSH key (or use --github / --key)"
  log "Would write: $VM_DIR/user-data, meta-data, seed.iso"
else
  PUBKEY=$(resolve_ssh_key) || die "Could not resolve SSH key"
  log "Using key: ${PUBKEY:0:40}..."

  cat > user-data <<EOF
#cloud-config
hostname: docker-phone
users:
  - name: sulthon
    sudo: ALL=(ALL) NOPASSWD:ALL
    shell: /bin/bash
    ssh_authorized_keys:
      - $PUBKEY
  - name: root
    ssh_authorized_keys:
      - $PUBKEY
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

  cat > meta-data <<EOF
instance-id: docker-phone-001
local-hostname: docker-phone
EOF

  genisoimage -output seed.iso -volid cidata -joliet -rock user-data meta-data >/dev/null 2>&1 || die "genisoimage failed"
  rm -f user-data meta-data   # don't leave the key in plaintext on disk
  ok "seed.iso built with your SSH key"
fi

# ─── Step 5: Copy UEFI firmware vars ────────────────────────────────────────
step 5 "Prepare UEFI firmware vars"
CODE_FD="$PREFIX/share/qemu/edk2-aarch64-code.fd"
VARS_FD="$VM_DIR/edk2-vars.fd"

if $DRY_RUN; then
  log "Would copy: $CODE_FD → (referenced in-place)"
  log "Would copy + resize: edk2-aarch64-vars.fd → $VARS_FD (64M)"
else
  [[ -f "$CODE_FD" ]] || die "UEFI code missing: $CODE_FD (qemu package not fully installed?)"
  if [[ ! -f "$VARS_FD" ]] || [[ $RESUME == false ]]; then
    cp "$PREFIX/share/qemu/edk2-aarch64-vars.fd" "$VARS_FD"
    truncate -s 64M "$VARS_FD"
    ok "UEFI vars ready"
  else
    ok "UEFI vars already present, preserving"
  fi
fi

# ─── Step 6: Install launcher + boot scripts ────────────────────────────────
step 6 "Install QEMU launcher and Termux:Boot auto-start scripts"

# Find the repo root (we're in $VM_DIR but the scripts are in the repo)
# The user clones the repo somewhere, then runs setup-phone.sh from there.
# Save repo root before we cd'd into VM_DIR.
REPO_ROOT="${REPO_ROOT:-$(cd "$(dirname "$0")" && pwd)}"

if $DRY_RUN; then
  log "Would copy: $REPO_ROOT/termux/boot-debian-mon.sh → ~/boot-debian-mon.sh"
  log "Would copy: $REPO_ROOT/termux/01-start-vm.sh → ~/.termux/boot/01-start-vm.sh"
  log "Would create: ~/.termux/boot/02-start-sshd.sh"
else
  # Launcher
  cp "$REPO_ROOT/termux/boot-debian-mon.sh" "$HOME/boot-debian-mon.sh"
  chmod +x "$HOME/boot-debian-mon.sh"
  ok "Launcher: ~/boot-debian-mon.sh"

  # Termux:Boot scripts
  mkdir -p "$HOME/.termux/boot"
  cp "$REPO_ROOT/termux/01-start-vm.sh" "$HOME/.termux/boot/01-start-vm.sh"
  chmod +x "$HOME/.termux/boot/01-start-vm.sh"
  ok "Boot hook: ~/.termux/boot/01-start-vm.sh"

  # Also start Termux's own sshd on boot (for management access)
  cat > "$HOME/.termux/boot/02-start-sshd.sh" <<'EOF'
#!/data/data/com.termux/files/usr/bin/bash
sleep 30
termux-wake-lock 2>/dev/null
sshd
EOF
  chmod +x "$HOME/.termux/boot/02-start-sshd.sh"
  ok "Boot hook: ~/.termux/boot/02-start-sshd.sh"

  # Start sshd now too
  pgrep -x sshd >/dev/null || sshd
  ok "Termux sshd running on port 8022"
fi

# ─── Step 7: Start the VM ───────────────────────────────────────────────────
step 7 "Launch QEMU VM (first boot takes 20–30 minutes under TCG emulation)"

if $DRY_RUN; then
  log "Would run: bash ~/boot-debian-mon.sh"
  warn "Dry run complete. Re-run without --dry-run to actually start."
  exit 0
fi

# Check if already running
if pgrep -f qemu-system-aarch64 >/dev/null; then
  ok "QEMU already running (PID $(pgrep -f qemu-system-aarch64 | head -1))"
else
  bash "$HOME/boot-debian-mon.sh"
  ok "QEMU started"
fi

# Show IP address for the user
IP=$(ip addr show wlan0 2>/dev/null | grep -oP 'inet \K[0-9.]+' | head -1)
if [[ -n "$IP" ]]; then
  ok "Phone IP: $IP"
fi

echo ""
echo "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"
echo "  VM is booting. This takes 20–30 minutes (software emulation)."
echo ""
echo "  NEXT STEPS (on your computer):"
echo "    1. Clone this repo: git clone https://github.com/sulthonzh/android-docker-qemu"
echo "    2. cd android-docker-qemu"
echo "    3. ./run.sh   # auto-detects computer, runs setup-computer.sh"
echo ""
if [[ -n "$IP" ]]; then
  echo "  When setup-computer.sh asks for the phone IP, enter: $IP"
fi
echo ""
echo "  To check boot progress on the phone:"
echo "    tail -f ~/qemu-vm/debian-boot.log"
echo ""
echo "  To verify the VM is ready (from your computer, once booted):"
echo "    ssh phone-vm hostname    # should return 'docker-phone'"
echo "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"
