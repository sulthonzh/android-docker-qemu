#!/usr/bin/env bash
# run.sh — One entry point for both phone and computer setup.
#
# This script detects where it's running and dispatches to the right setup:
#   - Inside Termux (Android phone) → runs setup-phone.sh
#   - On Mac/Linux                  → runs setup-computer.sh
#
# Usage:
#   ./run.sh [args passed to the underlying setup script]
#
# Examples:
#   ./run.sh                                  # interactive on either device
#   ./run.sh --github myuser                 # phone: fetch SSH key from GitHub
#   ./run.sh --phone-ip 192.168.0.9          # computer: provide phone IP
#   ./run.sh --dry-run                       # either: preview without changes
#
# Source: https://github.com/sulthonzh/android-docker-qemu

set -uo pipefail

# Color helpers
if [[ -t 1 ]]; then
  GREEN="\033[32m"; BLUE="\033[34m"; BOLD="\033[1m"; RESET="\033[0m"
else
  GREEN=""; BLUE=""; BOLD=""; RESET=""
fi

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"

# Detect environment
detect_env() {
  # Termux sets PREFIX=/data/data/com.termux/files/usr
  if [[ -n "${PREFIX:-}" && "${PREFIX}" == *"com.termux"* ]]; then
    echo "termux"
  elif [[ "$(uname 2>/dev/null)" == "Darwin" ]]; then
    echo "mac"
  elif [[ "$(uname 2>/dev/null)" == "Linux" ]]; then
    # Check we're not inside an Android proot/chroot
    if [[ -f "/proc/version" ]] && grep -qi "android" /proc/version 2>/dev/null; then
      echo "android-linux"
    else
      echo "linux"
    fi
  else
    echo "unknown"
  fi
}

ENV=$(detect_env)

case "$ENV" in
  termux)
    printf "${GREEN}[run.sh]${RESET} Detected ${BOLD}Termux on Android${RESET} — running phone setup\n\n"
    exec bash "$SCRIPT_DIR/setup-phone.sh" "$@"
    ;;
  mac|linux)
    case "$ENV" in
      mac)   ENV_PRETTY="Mac" ;;
      linux) ENV_PRETTY="Linux" ;;
    esac
    printf "${GREEN}[run.sh]${RESET} Detected ${BOLD}${ENV_PRETTY}${RESET} computer — running computer setup\n\n"
    exec bash "$SCRIPT_DIR/setup-computer.sh" "$@"
    ;;
  android-linux)
    printf "${GREEN}[run.sh]${RESET} Looks like you're on Android via non-Termux Linux env.\n"
    printf "This setup only works inside ${BOLD}Termux${RESET}.\n"
    printf "Install Termux from F-Droid: https://f-droid.org/packages/com.termux/\n"
    exit 1
    ;;
  *)
    printf "Could not detect environment. Set \$PREFIX (Termux) or run on Mac/Linux.\n"
    exit 1
    ;;
esac
