#!/usr/bin/env bash
: '
# Install Google Cloud CLI from the official tarball into $HOME/google-cloud-sdk.
# Skips when already installed (re-run is a no-op; refresh via
# `gcloud components update` or the deferred `nx upgrade --all` flag).
.assets/provision/install_gcloud.sh
.assets/provision/install_gcloud.sh --with_gke true --fix_certify true
'
set -euo pipefail

if [ $EUID -eq 0 ]; then
  printf '\e[31;1mDo not run the script as root.\e[0m\n' >&2
  exit 1
fi

# parse named parameters
with_gke=${with_gke:-false}
fix_certify=${fix_certify:-false}
while [ $# -gt 0 ]; do
  if [[ $1 == *"--"* ]]; then
    param="${1/--/}"
    declare $param="$2"
  fi
  shift
done

SCRIPT_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
. "$SCRIPT_ROOT/.assets/lib/helpers.sh"

GCLOUD_HOME="$HOME/google-cloud-sdk"
GCLOUD_BIN="$GCLOUD_HOME/bin/gcloud"

# Skip-on-installed gate. Re-runs of `nix/setup.sh` do not refresh gcloud;
# users upgrade explicitly via `gcloud components update` or the deferred
# `nx upgrade --all` flag (see design/followups.md).
if [ -x "$GCLOUD_BIN" ]; then
  ver="$("$GCLOUD_BIN" version 2>/dev/null | sed -En 's/Google Cloud SDK ([0-9.]+).*/\1/p' | head -n1 || true)"
  printf '\e[32mgcloud v%s already installed at %s; skipping (use `gcloud components update` to refresh).\e[0m\n' \
    "${ver:-?}" "$GCLOUD_HOME" >&2
  if [ "$with_gke" = "true" ] && ! [ -x "$GCLOUD_HOME/bin/gke-gcloud-auth-plugin" ]; then
    _io_step "installing gke-gcloud-auth-plugin component"
    CLOUDSDK_CORE_DISABLE_PROMPTS=1 "$GCLOUD_BIN" components install --quiet gke-gcloud-auth-plugin >&2
  fi
  if [ "$fix_certify" = "true" ]; then
    "$SCRIPT_ROOT/.assets/fix/fix_gcloud_certs.sh"
  fi
  exit 0
fi

# System-gcloud collision: log and continue. The :gcloud env block prepends
# $HOME/google-cloud-sdk/bin so the tarball install wins on PATH.
sys_gcloud="$(command -v gcloud 2>/dev/null || true)"
if [ -n "$sys_gcloud" ] && [ "$sys_gcloud" != "$GCLOUD_BIN" ]; then
  printf '\e[33mNote: shadowing system gcloud at %s; tarball install will win on PATH.\e[0m\n' "$sys_gcloud" >&2
fi

# OS+arch detection. Google's archive names use linux/darwin for OS and
# x86_64/arm for arch; uname -m returns aarch64/arm64, mapped to arm.
case "$(uname -s)" in
Linux) os='linux' ;;
Darwin) os='darwin' ;;
*)
  printf '\e[31;1mUnsupported OS: %s\e[0m\n' "$(uname -s)" >&2
  exit 1
  ;;
esac
case "$(uname -m)" in
x86_64 | amd64) arch='x86_64' ;;
aarch64 | arm64) arch='arm' ;;
*)
  printf '\e[31;1mUnsupported architecture: %s\e[0m\n' "$(uname -m)" >&2
  exit 1
  ;;
esac

# Resolve floating-latest from the rapid channel manifest.
for cmd in curl jq tar; do
  if ! command -v "$cmd" &>/dev/null; then
    printf '\e[31;1mThe \e[1m%s\e[22m command is required.\e[0m\n' "$cmd" >&2
    exit 1
  fi
done
_io_step "resolving latest gcloud version"
metadata_uri='https://dl.google.com/dl/cloudsdk/channels/rapid/components-2.json'
ver="$(curl -fsSL "$metadata_uri" | jq -r '.version')"
if [ -z "$ver" ] || [ "$ver" = "null" ]; then
  printf '\e[31;1mFailed to resolve latest gcloud version from %s.\e[0m\n' "$metadata_uri" >&2
  exit 1
fi

archive="google-cloud-cli-${ver}-${os}-${arch}.tar.gz"
url="https://dl.google.com/dl/cloudsdk/channels/rapid/downloads/${archive}"

cache_dir="$HOME/.cache/gcloud-install"
mkdir -p "$cache_dir"
# Cross-platform mktemp: GNU `mktemp -p` is unavailable on BSD/macOS; passing
# the full template path works on both.
tmp_dir="$(mktemp -d "$HOME/.gcloud-install.XXXXXX")"
trap 'rm -rf "$tmp_dir"' EXIT

printf '\e[96minstalling Google Cloud CLI v%s (%s/%s)...\e[0m\n' "$ver" "$os" "$arch" >&2

_io_step "downloading $archive"
if ! download_file --uri "$url" --target_dir "$cache_dir"; then
  printf '\e[31;1mFailed to download Google Cloud CLI archive.\e[0m\n' >&2
  exit 1
fi

_io_step "extracting Google Cloud CLI archive"
tar -zxf "$cache_dir/$archive" -C "$tmp_dir"

# Atomic-ish swap: rm + mv. Same-filesystem mv is atomic; the rm leaves a
# small window, tolerable for a per-user dir no other process is reading.
rm -rf "$GCLOUD_HOME"
mv "$tmp_dir/google-cloud-sdk" "$GCLOUD_HOME"

# Run the bundled installer. PATH/completion/cert env are managed by the
# :gcloud env block (.assets/lib/nx_profile.sh), so install.sh skips its
# own rc-file edits.
_io_step "running bundled gcloud install.sh"
CLOUDSDK_CORE_DISABLE_PROMPTS=1 "$GCLOUD_HOME/install.sh" \
  --quiet \
  --usage-reporting false \
  --path-update false \
  --bash-completion false \
  --rc-path /dev/null >/dev/null

if [ "$with_gke" = "true" ]; then
  _io_step "installing gke-gcloud-auth-plugin component"
  CLOUDSDK_CORE_DISABLE_PROMPTS=1 "$GCLOUD_BIN" components install --quiet gke-gcloud-auth-plugin >&2
fi

if [ "$fix_certify" = "true" ]; then
  "$SCRIPT_ROOT/.assets/fix/fix_gcloud_certs.sh"
fi

printf '\e[32mInstalled Google Cloud CLI v%s at %s.\e[0m\n' "$ver" "$GCLOUD_HOME" >&2
