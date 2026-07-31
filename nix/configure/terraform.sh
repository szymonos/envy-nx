#!/usr/bin/env bash
# Post-install terraform configuration: use tfswitch to install the latest
# terraform binary to ~/.local/bin (already in PATH via the nx-managed env block).
: '
nix/configure/terraform.sh
'
set -eo pipefail

INSTALL_DIR="$HOME/.local/bin"

if command -v terraform &>/dev/null; then
  ver=$(terraform version -json 2>/dev/null | jq -r '.terraform_version // empty' 2>/dev/null || true)
  if [[ -n "$ver" ]]; then
    # stdout, not stderr: this runs via _io_run, which captures stderr and only
    # replays it on failure -- a stderr label would be swallowed on success.
    printf "\e[32mterraform v%s already installed\e[0m\n" "$ver"
    return 0 2>/dev/null || exit 0
  fi
fi

mkdir -p "$INSTALL_DIR"
printf "\e[96minstalling terraform via tfswitch to %s...\e[0m\n" "$INSTALL_DIR"
tfswitch --bin "$INSTALL_DIR/terraform" --latest
