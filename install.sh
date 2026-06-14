#!/usr/bin/env bash
# install.sh — One-command installer for android-docker-qemu
#
# Usage (curl | bash):
#   curl -fsSL https://raw.githubusercontent.com/sulthonzh/android-docker-qemu/main/install.sh | bash
#
# Usage (download + review first — RECOMMENDED for first-time users):
#   curl -fsSL https://raw.githubusercontent.com/sulthonzh/android-docker-qemu/main/install.sh -o install.sh
#   less install.sh                                    # review what it does
#   bash install.sh                                    # then run it
#
# Pass arguments to the underlying setup script:
#   bash install.sh --github your-username             # phone: non-interactive
#   bash install.sh --phone-ip 192.168.0.9             # computer: non-interactive
#   bash install.sh --dry-run                          # either: preview
#
# ─── What this installer does ───────────────────────────────────────────────
#   1. Downloads the repo tarball from GitHub (HTTPS-only, pinned to main)
#   2. Verifies the tarball extracted correctly (run.sh must exist)
#   3. Auto-detects your environment (Termux on Android, Mac, or Linux)
#   4. Hands off to run.sh, which runs the appropriate setup script
#   5. Cleans up the temp directory on exit (unless --keep)
#
# ─── What this installer does NOT do ────────────────────────────────────────
#   ✗ Does NOT use sudo (everything is user-level: ~/.local/bin, ~/.ssh,
#     ~/.termux/boot, ~/qemu-vm)
#   ✗ Does NOT modify system files (/etc, /usr, /System)
#   ✗ Does NOT phone home or collect telemetry
#   ✗ Does NOT execute code from anywhere except this repo and GitHub
#   ✗ Does NOT install packages without showing you what's being installed
#
# ─── Source / audit / report issues ─────────────────────────────────────────
#   Repo:   https://github.com/sulthonzh/android-docker-qemu
#   Issues: https://github.com/sulthonzh/android-docker-qemu/issues

set -euo pipefail

# ─── Color helpers (bash 3.2 compatible — works on macOS default bash) ─────
if [[ -t 1 ]]; then
  GREEN="\033[32m"; YELLOW="\033[33m"; RED="\033[31m"; BLUE="\033[34m"; BOLD="\033[1m"; DIM="\033[2m"; RESET="\033[0m"
else
  GREEN=""; YELLOW=""; RED=""; BLUE=""; BOLD=""; DIM=""; RESET=""
fi
log()   { printf "${BLUE}[%s]${RESET} %s\n" "$(date +%H:%M:%S)" "$*"; }
ok()    { printf "${GREEN}[%s] ✓${RESET} %s\n" "$(date +%H:%M:%S)" "$*"; }
warn()  { printf "${YELLOW}[%s] !${RESET} %s\n" "$(date +%H:%M:%S)" "$*"; }
die()   { printf "${RED}[%s] ✗${RESET} %s\n" "$(date +%H:%M:%S)" "$*" >&2; exit 1; }

# ─── Constants ──────────────────────────────────────────────────────────────
REPO="sulthonzh/android-docker-qemu"
BRANCH="main"
TARBALL_URL="https://codeload.github.com/${REPO}/tar.gz/refs/heads/${BRANCH}"
VERSION="1.0.0"

# ─── Arg parsing ────────────────────────────────────────────────────────────
KEEP=false
FORCE_TTY=false
ARGS=()
while [[ $# -gt 0 ]]; do
  case "$1" in
    --keep)         KEEP=true; shift ;;
    --force-tty)    FORCE_TTY=true; shift ;;   # for testing when piped
    --version|-V)   echo "install.sh $VERSION ($REPO@$BRANCH)"; exit 0 ;;
    -h|--help)
      sed -n '2,40p' "$0" 2>/dev/null | sed 's/^# \{0,1\}//' || true
      exit 0
      ;;
    --) shift; ARGS+=("$@"); break ;;
    *) ARGS+=("$1"); shift ;;
  esac
done

# ─── Preamble: tell the user exactly what we're going to do ────────────────
if [[ -t 1 || "$FORCE_TTY" == "true" ]]; then
  printf "\n${BOLD}android-docker-qemu installer${RESET} ${DIM}v${VERSION}${RESET}\n"
  printf "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━\n"
  printf "This will:\n"
  printf "  1. Download the repo from ${BLUE}github.com/${REPO}${RESET}\n"
  printf "  2. Extract it to a temporary directory\n"
  printf "  3. Run ${BOLD}./run.sh${RESET}, which auto-detects your device\n"
  printf "  4. Clean up the temp directory on exit\n"
  printf "\n"
  printf "This will ${BOLD}NOT${RESET} use sudo, modify system files, or phone home.\n"
  printf "Audit the installer source first if you prefer:\n"
  printf "  ${DIM}https://github.com/${REPO}/blob/${BRANCH}/install.sh${RESET}\n"
  printf "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━\n\n"
fi

# ─── Detect environment (early bail if unsupported) ────────────────────────
detect_env() {
  if [[ -n "${PREFIX:-}" && "${PREFIX}" == *"com.termux"* ]]; then
    echo "termux"
  elif [[ "$(uname 2>/dev/null)" == "Darwin" ]]; then
    echo "mac"
  elif [[ "$(uname 2>/dev/null)" == "Linux" ]]; then
    echo "linux"
  else
    echo "unknown"
  fi
}

ENV=$(detect_env)
case "$ENV" in
  termux) log "Detected ${BOLD}Termux on Android${RESET} — phone setup will run" ;;
  mac)    log "Detected ${BOLD}macOS${RESET} — computer setup will run" ;;
  linux)  log "Detected ${BOLD}Linux${RESET} — computer setup will run" ;;
  *)      die "Unsupported environment. Run inside Termux, or on macOS/Linux." ;;
esac

# ─── Dependencies check ────────────────────────────────────────────────────
log "Checking dependencies..."
for cmd in curl tar bash; do
  command -v "$cmd" >/dev/null 2>&1 || die "Required command not found: $cmd"
done
ok "curl, tar, bash available"

# ─── Create temp directory ─────────────────────────────────────────────────
# Use mktemp -d for portability (works on macOS, Linux, and Termux)
TMP_DIR=$(mktemp -d 2>/dev/null || mktemp -d -t android-docker-qemu)
log "Temp directory: ${DIM}${TMP_DIR}${RESET}"

# Cleanup trap — runs on EXIT, INT, TERM regardless of success/failure
cleanup() {
  EXIT_CODE=$?
  if [[ "$KEEP" == "true" ]]; then
    [[ $EXIT_CODE -eq 0 ]] && ok "Repo kept at: $TMP_DIR (--keep)"
  else
    rm -rf "$TMP_DIR"
    log "Cleaned up temp directory"
  fi
  exit $EXIT_CODE
}
trap cleanup EXIT INT TERM

# ─── Download the repo tarball ─────────────────────────────────────────────
log "Downloading repo from ${TARBALL_URL}"
log "${DIM}(HTTPS-only, pinned to ${BRANCH} branch)${RESET}"

TARBALL="$TMP_DIR/repo.tar.gz"
HTTP_CODE=$(curl -fsSL -w '%{http_code}' -o "$TARBALL" "$TARBALL_URL" 2>/dev/null) || {
  die "Download failed (HTTP $HTTP_CODE). Check your internet connection and try again."
}
[[ "$HTTP_CODE" == "200" ]] || die "Download failed with HTTP status $HTTP_CODE"
ok "Downloaded ($(wc -c < "$TARBALL" | tr -d ' ') bytes)"

# ─── Extract the tarball ───────────────────────────────────────────────────
log "Extracting..."
tar -xzf "$TARBALL" -C "$TMP_DIR" || die "tar extraction failed"
rm -f "$TARBALL"

# GitHub tarballs extract to ${REPO}-${BRANCH}/ (with the slash turned into a dash)
EXTRACTED_DIR="$TMP_DIR/$(ls "$TMP_DIR" | head -1)"
[[ -d "$EXTRACTED_DIR" ]] || die "Extraction did not produce expected directory"

# ─── Verify the extracted repo has the entry point ─────────────────────────
[[ -f "$EXTRACTED_DIR/run.sh" ]] || die "run.sh missing in extracted repo — corrupt download?"
[[ -x "$EXTRACTED_DIR/run.sh" ]] || chmod +x "$EXTRACTED_DIR/run.sh"
ok "Verified: repo extracted correctly"

# Show what's in the repo (transparency)
if [[ -t 1 || "$FORCE_TTY" == "true" ]]; then
  printf "\n${DIM}Extracted files:${RESET}\n"
  (cd "$EXTRACTED_DIR" && ls -1 | sed 's/^/  /')
  printf "\n"
fi

# ─── Hand off to run.sh ────────────────────────────────────────────────────
log "Handing off to ${BOLD}run.sh${RESET}..."
[[ ${#ARGS[@]} -gt 0 ]] && log "${DIM}Forwarding args: ${ARGS[*]}${RESET}"

cd "$EXTRACTED_DIR"
# Replace the current process with run.sh so the cleanup trap still fires
# correctly on exit (bash's exit triggers EXIT trap).
bash ./run.sh "${ARGS[@]}" || die "run.sh exited with status $?"
