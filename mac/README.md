# Mac/Linux helper scripts — install to ~/.local/bin/ (or anywhere on $PATH).
#
# These scripts wrap common operations against the phone-based Docker host.
# They assume you've already set up SSH as described in the tutorial.
#
# Make executable after install:  chmod +x ~/.local/bin/phone-*
#
# Required env vars (or put in ~/.config/phone.env and source it):
#   PHONE_IP       — phone's LAN IP (default: 192.168.0.9)
#   TERMUX_PORT    — Termux SSH port (default: 8022)
#   VM_PORT        — VM SSH port (default: 2222)
#   SSH_KEY        — path to private key (default: ~/.ssh/id_ed25519)
