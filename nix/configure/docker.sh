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
_colima_block_content() {
  cat <<YAML
mounts:
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

# Lima/colima uses Go's yaml.v3 which rejects duplicate top-level keys.
# colima writes empty `mounts: []` and `provision: null` as scaffolding -
# our sentinel block defines both keys, so we must strip the defaults before
# the upsert. Only the literal scaffolding lines are touched; non-default user
# values are left alone (and the caller skips the upsert with a warning).
#
# Returns 0 if safe to proceed (scaffolding stripped or already absent),
# 1 if the user has customized mounts/provision outside our sentinel block.
_colima_strip_default_scaffolding() {
  local yaml="$1"
  local tmp begin_tag end_tag
  begin_tag="$(printf '# >>> %s >>>' "$COLIMA_BLOCK_MARKER")"
  end_tag="$(printf '# <<< %s <<<' "$COLIMA_BLOCK_MARKER")"
  # Quick scan: are there top-level mounts:/provision: lines outside our block
  # that aren't the default empty forms? Track block boundaries with awk.
  local non_default
  non_default="$(awk -v begin="$begin_tag" -v end="$end_tag" '
    BEGIN { in_block = 0 }
    $0 == begin { in_block = 1; next }
    $0 == end { in_block = 0; next }
    in_block { next }
    /^mounts:[[:space:]]*\[\][[:space:]]*$/ { next }
    /^provision:[[:space:]]*null[[:space:]]*$/ { next }
    /^mounts:[[:space:]]*$/ { print "mounts"; next }
    /^mounts:/ { print "mounts"; next }
    /^provision:[[:space:]]*$/ { print "provision"; next }
    /^provision:/ { print "provision"; next }
  ' "$yaml" | sort -u)"
  if [ -n "$non_default" ]; then
    return 1
  fi
  # Safe to strip the scaffolding lines. Write to tmp + atomic rename.
  tmp="$(mktemp)"
  awk -v begin="$begin_tag" -v end="$end_tag" '
    BEGIN { in_block = 0 }
    $0 == begin { in_block = 1; print; next }
    $0 == end { in_block = 0; print; next }
    in_block { print; next }
    /^mounts:[[:space:]]*\[\][[:space:]]*$/ { next }
    /^provision:[[:space:]]*null[[:space:]]*$/ { next }
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
