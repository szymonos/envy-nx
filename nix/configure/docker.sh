#!/usr/bin/env bash
# Post-install Docker configuration (no root required).
#
# Linux: verifies docker is on PATH and the user is in the docker group.
# macOS: verifies the colima + docker CLI trio installed by the `docker` scope,
# then upserts a managed YAML block into colima's template and every existing
# profile so the host's ca-custom.crt (mirrored at /mnt/envy-certs inside the
# VM) is trusted by docker/containerd on every `colima start`. This is the
# VM-side equivalent of the host-side cert handling in §3g of ARCHITECTURE.md.
#
# Arg 1: unattended ("true"/"false", default "false"). When "true", silently
# proceeds (no prompts); used by phase_configure_per_scope under --unattended.
: '
nix/configure/docker.sh
nix/configure/docker.sh true   # unattended
'
set -eo pipefail

unattended="${1:-false}"
SCRIPT_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
# shellcheck source=/dev/null
. "$SCRIPT_ROOT/.assets/lib/helpers.sh"
# shellcheck source=/dev/null
. "$SCRIPT_ROOT/.assets/lib/profile_block.sh"

info() { printf "\e[96m%s\e[0m\n" "$*"; }
ok() { printf "\e[32m%s\e[0m\n" "$*"; }
warn() { printf "\e[33m%s\e[0m\n" "$*" >&2; }

# Sentinel marker used in colima.yaml files. Keep stable - users may have
# existing managed blocks from prior runs that we need to upsert in place.
COLIMA_BLOCK_MARKER="envy-nx:certs"
COLIMA_HOST_CERT_DIR="$HOME/.config/certs"
COLIMA_VM_MOUNT="/mnt/envy-certs"
COLIMA_VM_CERT="/usr/local/share/ca-certificates/envy-nx.crt"

# Compose the YAML body that gets sandwiched between the sentinel comments.
# Top-level keys (mounts, provision) are at column 0 - the block is inserted
# at the bottom of colima.yaml, so this is valid YAML as-is.
# The home mount must stay listed: colima mounts ~ only when `mounts` is empty,
# and any non-empty list replaces that default, hiding host paths from docker.
_colima_block_content() {
  cat <<YAML
mounts:
  - location: "~"
    writable: true
  - location: "${COLIMA_HOST_CERT_DIR}"
    mountPoint: ${COLIMA_VM_MOUNT}
    writable: false
provision:
  - mode: system
    script: |
      #!/bin/sh
      [ -f ${COLIMA_VM_MOUNT}/ca-custom.crt ] || exit 0
      cmp -s ${COLIMA_VM_MOUNT}/ca-custom.crt ${COLIMA_VM_CERT} 2>/dev/null && exit 0
      cp ${COLIMA_VM_MOUNT}/ca-custom.crt ${COLIMA_VM_CERT}
      update-ca-certificates
      systemctl restart docker || true
YAML
}

# Print the top-level `key:` section found outside the sentinel block: the key
# line plus its indented lines, blank lines dropped and quotes removed so that
# colima's re-serialized quoting compares equal to ours.
_colima_section() {
  local yaml="$1" key="$2"
  awk -v key="$key:" -v begin="# >>> $COLIMA_BLOCK_MARKER >>>" -v end="# <<< $COLIMA_BLOCK_MARKER <<<" '
    $0 == begin { in_block = 1; next }
    $0 == end { in_block = 0; next }
    in_block { next }
    in_sec && /^[^[:space:]]/ { in_sec = 0 }
    index($0, key) == 1 { in_sec = 1 }
    in_sec && NF { gsub(/"/, ""); sub(/[[:space:]]+$/, ""); print }
  ' "$yaml"
}

# Lima/colima uses Go's yaml.v3 which rejects duplicate top-level keys, and our
# sentinel block defines both `mounts` and `provision`, so any copy of those
# keys outside the block must go before the upsert. Safe to remove:
# - colima's empty scaffolding (`mounts: []`, `provision: null`);
# - our own block with its markers lost: `colima start` re-serializes
#   colima.yaml, dropping comments and moving the keys to their usual spots.
#   mounts must match the block exactly (or the certs-only form it had before
#   the home mount was added); provision must be a single entry that installs
#   our cert, so a user's extra entry beside it is never deleted.
# Anything else is user customization and the caller skips the file.
#
# Returns 0 if safe to proceed (sections stripped or already absent),
# 1 if the user has customized mounts/provision outside our sentinel block.
_colima_strip_default_scaffolding() {
  local yaml="$1"
  local tmp mounts provision ours_mounts legacy_mounts
  mounts="$(_colima_section "$yaml" mounts)"
  provision="$(_colima_section "$yaml" provision)"
  tmp="$(mktemp)"
  _colima_block_content >"$tmp"
  ours_mounts="$(_colima_section "$tmp" mounts)"
  legacy_mounts="$(printf 'mounts:\n  - location: %s\n    mountPoint: %s\n    writable: false' \
    "$COLIMA_HOST_CERT_DIR" "$COLIMA_VM_MOUNT")"
  case "$mounts" in
  '' | 'mounts: []' | "$ours_mounts" | "$legacy_mounts") ;;
  *)
    rm -f "$tmp"
    return 1
    ;;
  esac
  case "$provision" in
  '' | 'provision: null') ;;
  *)
    if [ "$(printf '%s\n' "$provision" | grep -c '^  - ')" != 1 ] ||
      ! printf '%s\n' "$provision" | grep -qF "cp $COLIMA_VM_MOUNT/ca-custom.crt"; then
      rm -f "$tmp"
      return 1
    fi
    ;;
  esac
  awk -v begin="# >>> $COLIMA_BLOCK_MARKER >>>" -v end="# <<< $COLIMA_BLOCK_MARKER <<<" '
    $0 == begin { in_block = 1; print; next }
    $0 == end { in_block = 0; print; next }
    in_block { print; next }
    in_sec && /^[^[:space:]]/ { in_sec = 0 }
    /^(mounts|provision):/ { in_sec = 1 }
    in_sec && NF { next }
    { print }
  ' "$yaml" >"$tmp"
  command mv -f "$tmp" "$yaml"
  return 0
}

# Apply the cert mount + provision block to a single colima.yaml file.
# - target_label: short label for log lines (e.g. "default", "_templates/default").
_colima_apply_block() {
  local yaml="$1" target_label="$2"
  local content_tmp
  [ -f "$yaml" ] || touch "$yaml"
  if ! _colima_strip_default_scaffolding "$yaml"; then
    warn "$target_label: skipped - colima.yaml has custom mounts/provision."
    warn "  Move your customizations into the sentinel block manually, or"
    warn "  back up & delete the file and re-run setup."
    return 0
  fi
  content_tmp="$(mktemp)"
  _colima_block_content >"$content_tmp"
  manage_block "$yaml" "$COLIMA_BLOCK_MARKER" upsert "$content_tmp"
  rm -f "$content_tmp"
  ok "$target_label: cert mount + provision block upserted"
}

# Darwin arm: enumerate colima profiles + template, apply block to each.
_configure_macos_colima() {
  if ! command -v colima >/dev/null 2>&1; then
    warn "colima not found - skipping colima cert provisioning"
    warn "  (the docker scope on macOS expects colima from nix; run \`nx upgrade\`)"
    return 0
  fi
  if ! command -v docker >/dev/null 2>&1; then
    warn "docker CLI not found - colima will boot but \`docker\` won't work"
    warn "  (run \`nx upgrade\` to reinstall the docker scope)"
  fi
  # Resolve the template path via colima itself - it's the source of truth and
  # has varied across colima versions. Falls back to the documented default.
  local template
  template="$(colima template --print 2>/dev/null)" || template="$HOME/.colima/_templates/default.yaml"
  mkdir -p "$(dirname "$template")"
  _io_step "writing colima template (applies to new profiles)"
  _colima_apply_block "$template" "_templates/$(basename "$template")"
  # Existing profile yamls. Only directories that contain a colima.yaml are
  # profiles; sibling dirs like _lima, _config, _disks, _networks, _templates
  # are colima internals and are skipped naturally by the file check.
  local profile_dir profile_yaml profile_name applied=0
  if [ -d "$HOME/.colima" ]; then
    for profile_dir in "$HOME"/.colima/*/; do
      profile_yaml="${profile_dir}colima.yaml"
      [ -f "$profile_yaml" ] || continue
      profile_name="$(basename "$profile_dir")"
      _io_step "writing colima profile: $profile_name"
      _colima_apply_block "$profile_yaml" "profile/$profile_name"
      applied=$((applied + 1))
    done
  fi
  if [ "$applied" -gt 0 ]; then
    if colima status >/dev/null 2>&1; then
      info "colima is running - restart to apply the new provision script:"
      info "  colima restart"
    fi
  else
    info "no existing colima profiles - run \`colima start\` to create one"
    info "(the template above will be applied automatically)"
  fi
  # `unattended` is accepted for future-prompt symmetry with nodejs.sh; the
  # current flow only emits hints (never prompts), so it's currently unused.
  : "${unattended}"
}

case "$(uname -s)" in
Darwin)
  _configure_macos_colima
  ;;
*)
  # Linux: verify docker is on PATH and user is in the docker group.
  if command -v docker >/dev/null 2>&1; then
    if groups | grep -qw docker; then
      ok "docker is available and user is in docker group"
    else
      warn "docker is installed but $(whoami) is not in the docker group."
      warn "Run: sudo usermod -aG docker $(whoami)"
    fi
  else
    warn "docker is not installed. Install it separately (requires root)."
  fi
  ;;
esac
