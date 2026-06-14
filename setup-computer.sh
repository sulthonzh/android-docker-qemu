#!/bin/bash
# setup-computer.sh — Configure your Mac/Linux computer to use the phone as a Docker host
#
# Run this script ON YOUR COMPUTER (Mac or Linux).
# It installs helper scripts, SSH config, and a Docker context.
#
# Usage:
#   ./setup-computer.sh                          # interactive
#   ./setup-computer.sh --phone-ip 192.168.0.9   # provide IP directly
#   ./setup-computer.sh --phone-ip 192.168.0.9 --vm-user sulthon --vm-port 2222
#   ./setup-computer.sh --dry-run                # show what would happen
#
# Prerequisites:
#   1. Docker installed (Docker Desktop, Colima, or OrbStack on Mac; docker.io on Linux)
#   2. SSH key generated (run: ssh-keygen -t ed25519)
#   3. Phone has finished running setup-phone.sh and QEMU is booting/booted
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

TOTAL_STEPS=5

# ─── Arg parsing ────────────────────────────────────────────────────────────
PHONE_IP=""
VM_USER="sulthon"
VM_PORT="2222"
TERMUX_USER="u0_a892"
TERMUX_PORT="8022"
SSH_KEY="$HOME/.ssh/id_ed25519"
DRY_RUN=false

while [[ $# -gt 0 ]]; do
  case "$1" in
    --phone-ip)     PHONE_IP="$2"; shift 2 ;;
    --vm-user)      VM_USER="$2"; shift 2 ;;
    --vm-port)      VM_PORT="$2"; shift 2 ;;
    --termux-user)  TERMUX_USER="$2"; shift 2 ;;
    --termux-port)  TERMUX_PORT="$2"; shift 2 ;;
    --ssh-key)      SSH_KEY="$2"; shift 2 ;;
    --dry-run)      DRY_RUN=true; shift ;;
    -h|--help)
      sed -n '2,18p' "$0" | sed 's/^# \{0,1\}//'
      exit 0 ;;
    *) die "Unknown argument: $1 (try --help)" ;;
  esac
done

# ─── Safety checks ──────────────────────────────────────────────────────────
[[ -d "$(dirname "$SSH_KEY")" ]] || die "SSH key directory not found: $(dirname "$SSH_KEY") (run: ssh-keygen -t ed25519)"

if ! command -v docker >/dev/null; then
  die "docker not found. Install Docker Desktop / Colima / OrbStack first."
fi
if ! command -v ssh >/dev/null; then
  die "ssh not found. Install OpenSSH client."
fi

REPO_ROOT="$(cd "$(dirname "$0")" && pwd)"

if $DRY_RUN; then
  warn "DRY RUN — no actions will be taken"
fi

# Resolve phone IP interactively if not provided
if [[ -z "$PHONE_IP" ]]; then
  echo ""
  read -r -p "Enter your phone's IP address (shown by setup-phone.sh, e.g. 192.168.0.9): " PHONE_IP
  [[ -n "$PHONE_IP" ]] || die "Phone IP is required"
  [[ "$PHONE_IP" =~ ^[0-9]{1,3}(\.[0-9]{1,3}){3}$ ]] || die "Invalid IP: $PHONE_IP"
fi

# ─── Step 1: Install helper scripts ─────────────────────────────────────────
step 1 "Install phone-* helper scripts to ~/.local/bin/"

BIN_DIR="$HOME/.local/bin"
mkdir -p "$BIN_DIR"

if $DRY_RUN; then
  log "Would copy $REPO_ROOT/mac/phone-* → $BIN_DIR/"
else
  for f in phone-healthcheck phone-status phone-vm-start phone-vm-stop phone-vm-restart phone-vm-console phone-vm-logs; do
    [[ -f "$REPO_ROOT/mac/$f" ]] || die "Helper script missing in repo: $REPO_ROOT/mac/$f"
    cp "$REPO_ROOT/mac/$f" "$BIN_DIR/$f"
    chmod +x "$BIN_DIR/$f"
  done
  ok "7 helper scripts installed to $BIN_DIR"

  # Warn if ~/.local/bin is not on PATH
  case ":${PATH:-}:" in
    *":$BIN_DIR:"*) ;;
    *)
      warn "$BIN_DIR is not on your PATH"
      echo "    Add this to your ~/.zshrc or ~/.bashrc:"
      echo "      export PATH=\"$BIN_DIR:\$PATH\""
      ;;
  esac
fi

# ─── Step 2: Add SSH config entries (phone-vm, phone-termux) ────────────────
step 2 "Add SSH config entries for 'phone-vm' and 'phone-termux'"

SSH_CONFIG="$HOME/.ssh/config"
touch "$SSH_CONFIG"
chmod 600 "$SSH_CONFIG"

# Patch helper scripts to use the resolved IP/port/user (in-place edits of the copied files)
if ! $DRY_RUN; then
  for f in phone-healthcheck phone-status phone-vm-start phone-vm-stop phone-vm-restart phone-vm-console phone-vm-logs; do
    sed -i.bak \
      -e "s|^PHONE_IP=.*|PHONE_IP=\"${PHONE_IP}\"|" \
      -e "s|^VM_PORT=.*|VM_PORT=\"${VM_PORT}\"|" \
      -e "s|^TERMUX_PORT=.*|TERMUX_PORT=\"${TERMUX_PORT}\"|" \
      -e "s|^TERMUX_USER=.*|TERMUX_USER=\"${TERMUX_USER}\"|" \
      "$BIN_DIR/$f" 2>/dev/null
    rm -f "$BIN_DIR/$f.bak"
  done
  ok "Helper scripts patched with IP=$PHONE_IP"
fi

# Add SSH config entries (idempotent — check for Host phone-vm)
if ! $DRY_RUN; then
  if grep -q "^Host phone-vm$" "$SSH_CONFIG"; then
    ok "SSH config already has 'phone-vm' entry, skipping"
  else
    {
      echo ""
      echo "# ─── Android phone Docker host (added by android-docker-qemu setup-computer.sh) ───"
      echo "Host phone-vm"
      echo "    HostName $PHONE_IP"
      echo "    User $VM_USER"
      echo "    Port $VM_PORT"
      echo "    IdentityFile $SSH_KEY"
      echo "    StrictHostKeyChecking accept-new"
      echo ""
      echo "Host phone-termux"
      echo "    HostName $PHONE_IP"
      echo "    User $TERMUX_USER"
      echo "    Port $TERMUX_PORT"
      echo "    IdentityFile $SSH_KEY"
      echo "    StrictHostKeyChecking accept-new"
      echo "# ─── end android-docker-qemu ───"
    } >> "$SSH_CONFIG"
    ok "SSH config updated with phone-vm and phone-termux entries"
  fi
fi

# ─── Step 3: Copy SSH public key to phone (Termux side) ─────────────────────
step 3 "Copy your SSH public key to Termux (for phone-termux management access)"

PUBKEY_FILE="${SSH_KEY}.pub"
if [[ ! -f "$PUBKEY_FILE" ]]; then
  warn "Public key not found: $PUBKEY_KEY — skipping ssh-copy-id"
elif $DRY_RUN; then
  log "Would run: ssh-copy-id -p $TERMUX_PORT $TERMUX_USER@$PHONE_IP"
else
  log "Copying key to Termux (you'll enter the Termux password once)..."
  ssh-copy-id -p "$TERMUX_PORT" -i "$PUBKEY_FILE" "$TERMUX_USER@$PHONE_IP" 2>&1 | sed 's/^/    /' || warn "ssh-copy-id failed (you may need to copy the key manually)"
  ok "SSH key copied to Termux authorized_keys"
fi

# ─── Step 4: Create Docker context ──────────────────────────────────────────
step 4 "Create Docker context 'phone' (points at the VM via SSH)"

# Clear any conflicting DOCKER_HOST for this shell
unset DOCKER_HOST 2>/dev/null || true

if $DRY_RUN; then
  log "Would run: docker context create phone --docker host=ssh://$VM_USER@$PHONE_IP:$VM_PORT"
else
  # Remove existing context if present (recreate with current IP)
  if docker context inspect phone >/dev/null 2>&1; then
    log "Existing 'phone' context found, removing and recreating..."
    docker context rm phone >/dev/null 2>&1 || true
  fi
  docker context create phone \
    --docker "host=ssh://$VM_USER@$PHONE_IP:$VM_PORT" \
    >/dev/null 2>&1 || die "docker context create failed"
  ok "Docker context 'phone' created"

  # Seed known_hosts (docker ssh bypasses ~/.ssh/config aliases)
  log "Adding $PHONE_IP:$VM_PORT to ~/.ssh/known_hosts..."
  ssh-keyscan -p "$VM_PORT" -t ed25519,rsa "$PHONE_IP" >> "$HOME/.ssh/known_hosts" 2>/dev/null || true
  ok "known_hosts seeded"
fi

# ─── Step 5: Verify connectivity ────────────────────────────────────────────
step 5 "Verify connectivity (VM must have finished booting)"

if $DRY_RUN; then
  warn "Dry run complete. Re-run without --dry-run to actually set up."
  exit 0
fi

echo ""
log "Testing SSH to Termux (port $TERMUX_PORT)..."
if ssh -o ConnectTimeout=5 -o BatchMode=yes -p "$TERMUX_PORT" "$TERMUX_USER@$PHONE_IP" 'echo OK' 2>/dev/null | grep -q OK; then
  ok "Termux SSH reachable"
else
  warn "Termux SSH not reachable yet — the Termux sshd may still be starting"
fi

echo ""
log "Testing SSH to VM (port $VM_PORT)..."
if ssh -o ConnectTimeout=5 -o BatchMode=yes "phone-vm" 'echo OK' 2>/dev/null | grep -q OK; then
  ok "VM SSH reachable"
  VM_READY=true
else
  warn "VM SSH not reachable — it may still be booting (20–30 min cold start)"
  warn "Run 'phone-vm-start --wait' to block until ready, then re-run this script or run 'phone-healthcheck'"
  VM_READY=false
fi

if [[ "$VM_READY" == "true" ]]; then
  echo ""
  log "Testing Docker context..."
  if docker --context phone info >/dev/null 2>&1; then
    ok "Docker context works! Running hello-world..."
    docker --context phone run --rm hello-world 2>&1 | head -20
  else
    warn "Docker context created but 'docker info' failed — Docker daemon may still be starting inside the VM"
    warn "Wait a few minutes and run: docker --context phone info"
  fi
fi

echo ""
echo "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"
echo "  Setup complete!"
echo ""
echo "  Day-to-day commands:"
echo "    phone-healthcheck                  # full health check (exit code)"
echo "    phone-status                       # quick human-readable state"
echo "    phone-vm-start --wait              # start VM, wait until ready"
echo "    phone-vm-stop                      # graceful shutdown"
echo ""
echo "  Using Docker:"
echo "    docker --context phone run --rm hello-world"
echo "    docker --context phone compose -f docker/docker-compose.example.yml up -d"
echo ""
echo "  (Optional) Make the phone the default context:"
echo "    docker context use phone"
echo "    unset DOCKER_HOST   # Mac users with Colima/Docker Desktop — see tutorial §8.2"
echo "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"
