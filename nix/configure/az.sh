#!/usr/bin/env bash
# Post-install Azure CLI configuration (cross-platform, Nix variant)
# Azure CLI is installed via uv (not Nix) for better cross-platform compatibility.
: '
nix/configure/az.sh
'
set -eo pipefail

SCRIPT_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "$SCRIPT_ROOT/../.." && pwd)"

info() { printf "\e[96m%s\e[0m\n" "$*"; }

info "installing azure-cli via uv..."
# patch the certifi bundle with custom CA certificates so az works behind a MITM proxy;
# no-op when ~/.config/certs/ca-custom.crt is absent (cross-platform: Linux distro stores
# and macOS keychain interception both land in the same custom bundle path)
"$REPO_ROOT/.assets/provision/install_azurecli_uv.sh" --fix_certify true
