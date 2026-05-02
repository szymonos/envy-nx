# Installation provenance record writer.
# Writes ~/.config/dev-env/install.json with setup metadata.
# Compatible with bash 3.2 and zsh (sourced by both).
#
# Usage:
#   source .assets/lib/install_record.sh
#
#   # set variables before calling (or before trap fires):
#   _IR_ENTRY_POINT="nix"      # nix, linux, wsl/nix
#   _IR_VERSION="v1.2.0"       # optional: skip git detection, use this version
#   _IR_SCRIPT_ROOT="/path"    # repo root, for git version detection (unused when _IR_VERSION set)
#   _IR_REPO_PATH="/path"      # absolute path to repo root
#   _IR_REPO_URL="https://..."  # HTTPS clone URL for the repo
#   _IR_SCOPES="az shell"      # space-separated scope list
#   _IR_MODE="install"         # install, upgrade, reconfigure, remove
#   _IR_PLATFORM="Linux"       # macOS, Linux
#
#   # call directly or from an EXIT trap:
#   write_install_record <status> <phase> [error_message]

# shellcheck disable=SC2034  # DEV_ENV_DIR used by sourcing scripts
DEV_ENV_DIR="$HOME/.config/dev-env"

# Ensure nix-installed tools (jq, git) are in PATH.
# Non-interactive shells (bash -c) don't source profile.d, so we load
# the nix profile here if the nix bin directory isn't already in PATH.
if ! command -v jq &>/dev/null; then
  for _ir_nix_profile in \
    "$HOME/.nix-profile/etc/profile.d/nix.sh" \
    /nix/var/nix/profiles/default/etc/profile.d/nix-daemon.sh; do
    # shellcheck source=/dev/null
    if [ -f "$_ir_nix_profile" ]; then
      . "$_ir_nix_profile"
      break
    fi
  done
  unset _ir_nix_profile
fi

# Incremental flush helper. Writes the current phase as "in_progress" (or
# the supplied status) without touching the EXIT trap path. Idempotent and
# silent on failure - we never want a flush failure to abort setup.
#
# Usage (from setup.sh after each _ir_phase= assignment):
#   _ir_flush                   # status defaults to "in_progress"
#   _ir_flush in_progress       # explicit
#
# The EXIT trap continues to do the final write with status=success|failed.
# If the script is killed (SIGKILL/OOM) before the trap fires, the on-disk
# install.json reflects the last in-progress phase - which is the failure-
# mode the previous EXIT-only design could not capture.
_ir_flush() {
  [ "${_ir_skip:-false}" = "true" ] && return 0
  local _flush_status="${1:-in_progress}" _flush_error="${2:-}"
  write_install_record "$_flush_status" "${_ir_phase:-unknown}" "$_flush_error" 2>/dev/null || true
}

# write_install_record <status> <phase> [error_message]
write_install_record() {
  local status="${1:-unknown}" phase="${2:-unknown}" error="${3:-}"
  local entry_point="${_IR_ENTRY_POINT:-unknown}"

  mkdir -p "$DEV_ENV_DIR"

  # Stable installed_at across all writes within the same setup run. First
  # call captures current time; subsequent calls (mid-run flushes + EXIT
  # trap) reuse it so the timestamp reflects "when did the install happen",
  # not "when was the record last touched".
  local installed_at
  if [ -n "${_IR_INSTALLED_AT:-}" ]; then
    installed_at="$_IR_INSTALLED_AT"
  else
    installed_at="$(date -u +%Y-%m-%dT%H:%M:%SZ)"
    _IR_INSTALLED_AT="$installed_at"
    export _IR_INSTALLED_AT
  fi

  # version priority: caller-supplied > git describe > VERSION file > "unknown"
  local version="" source="" source_ref=""
  if [ -n "${_IR_VERSION:-}" ]; then
    version="$_IR_VERSION"
    source="${_IR_SOURCE:-git}"
    source_ref="${_IR_SOURCE_REF:-}"
  else
    local script_root="${_IR_SCRIPT_ROOT:-}"
    if [ -n "$script_root" ] && git -C "$script_root" rev-parse --is-inside-work-tree &>/dev/null; then
      version="$(git -C "$script_root" describe --tags --dirty 2>/dev/null ||
        git -C "$script_root" rev-parse --short HEAD 2>/dev/null)" || true
      source="git"
      source_ref="$(git -C "$script_root" rev-parse HEAD 2>/dev/null)" || true
    elif [ -n "$script_root" ] && [ -f "$script_root/VERSION" ]; then
      version="$(<"$script_root/VERSION")"
      source="tarball"
    else
      source="tarball"
    fi
  fi
  version="${version:-unknown}"

  local nix_ver=""
  nix_ver="$(nix --version 2>/dev/null)" || true

  # Capture the bash major.minor that ran setup. Distinguishes Apple's
  # frozen 3.2 (the bash 3.2 compatibility constraint everyone's first
  # macOS run hits) from modern bash 5+ on Linux/WSL/brewed-macOS.
  # Useful for triaging bug reports - "is this a bash 3.2 path failure?"
  # is one less question to ask. BASH_VERSINFO is always set in any
  # bash-executed script, so no fallback needed.
  local bash_ver="${BASH_VERSINFO[0]}.${BASH_VERSINFO[1]}"

  if command -v jq &>/dev/null; then
    local scopes_json="[]"
    if [ -n "${_IR_SCOPES:-}" ]; then
      # shellcheck disable=SC2086  # intentional word splitting
      scopes_json="$(printf '%s\n' $_IR_SCOPES | jq -R 'select(length > 0)' | jq -sc .)" || scopes_json="[]"
    fi

    jq -n \
      --arg entry_point "$entry_point" \
      --arg version "$version" \
      --arg source "$source" \
      --arg source_ref "${source_ref:-}" \
      --arg repo_path "${_IR_REPO_PATH:-}" \
      --arg repo_url "${_IR_REPO_URL:-}" \
      --argjson scopes "$scopes_json" \
      --argjson allow_unfree "${_IR_ALLOW_UNFREE:-false}" \
      --arg installed_at "$installed_at" \
      --arg installed_by "$(id -un)" \
      --arg platform "${_IR_PLATFORM:-unknown}" \
      --arg arch "$(uname -m)" \
      --arg mode "${_IR_MODE:-unknown}" \
      --arg status "$status" \
      --arg phase "$phase" \
      --arg error "$error" \
      --arg nix_version "${nix_ver:-}" \
      --arg bash_version "$bash_ver" \
      --arg shell "${SHELL:-}" \
      '{
        entry_point: $entry_point,
        version: $version,
        source: $source,
        source_ref: $source_ref,
        repo_path: $repo_path,
        repo_url: $repo_url,
        scopes: $scopes,
        allow_unfree: $allow_unfree,
        installed_at: $installed_at,
        installed_by: $installed_by,
        platform: $platform,
        arch: $arch,
        mode: $mode,
        status: $status,
        phase: $phase,
        error: $error,
        nix_version: $nix_version,
        bash_version: $bash_version,
        shell: $shell
      }' >"$DEV_ENV_DIR/install.json" 2>/dev/null
  else
    # fallback: write minimal JSON without jq (early failures)
    cat >"$DEV_ENV_DIR/install.json" <<IREOF
{
  "entry_point": "$entry_point",
  "version": "$version",
  "source": "$source",
  "repo_path": "${_IR_REPO_PATH:-}",
  "repo_url": "${_IR_REPO_URL:-}",
  "installed_at": "$installed_at",
  "installed_by": "$(id -un)",
  "platform": "${_IR_PLATFORM:-unknown}",
  "arch": "$(uname -m)",
  "status": "$status",
  "phase": "$phase",
  "bash_version": "$bash_ver"
}
IREOF
  fi
}
