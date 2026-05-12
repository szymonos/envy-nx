#!/usr/bin/env bash
# Post-install Google Cloud CLI configuration (cross-platform, Nix variant)
# gcloud is installed via the official tarball into $HOME/google-cloud-sdk
# (not via Nix) so `gcloud components install` keeps working - Nix's
# google-cloud-sdk writes the "managed by external package manager" marker
# that blocks `components install`, breaking gke-gcloud-auth-plugin.
: '
nix/configure/gcloud.sh           # gcloud only
nix/configure/gcloud.sh true      # gcloud + auto-install gke-gcloud-auth-plugin
'
set -eo pipefail

with_gke="${1:-false}"

SCRIPT_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "$SCRIPT_ROOT/../.." && pwd)"

info() { printf "\e[96m%s\e[0m\n" "$*"; }

info "installing google-cloud-cli (gcloud)..."
# patch the certifi bundle with custom CA certificates so gcloud works behind
# a MITM proxy; no-op when ~/.config/certs/ca-bundle.crt is absent
"$REPO_ROOT/.assets/provision/install_gcloud.sh" --with_gke "$with_gke" --fix_certify true
