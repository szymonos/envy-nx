: '
# Sourced, not run directly. After `source .assets/lib/nx_rev.sh`:
_nx_rev_resolve "$HOME/.config/nix-env" false
_nx_rev_resolve "$HOME/.config/nix-env" true
_nx_rev_locked_epoch "$HOME/.config/nix-env"
_nx_rev_is_downgrade "$HOME/.config/nix-env" 1787964612
_nx_lock_backup "$HOME/.config/nix-env"
'

# Shared nixpkgs-revision resolution for the two upgrade entry points:
# `nix/setup.sh` (nix/lib/phases/nix_profile.sh) and the repo-less in-place
# `nx upgrade` (.assets/lib/nx_pkg.sh). Both must land on the same revision - if
# they diverge, which nixpkgs a user gets depends on which command they
# happened to type.
#
# The revision ladder, highest precedence first:
#   1. pinned    - $ENV_DIR/pinned_rev, set by `nx pin set`. Explicit user
#                  intent, always wins.
#   2. latest    - caller passed --latest. nixpkgs-unstable HEAD, which no CI
#                  has built. Opt-in only.
#   3. validated - $ENV_DIR/nixpkgs_rev.json, advanced by CI only after the
#                  full suite passes on Linux and macOS.
#   4. none      - no validated rev on disk (install predates the rev file).
#                  Caller keeps the existing lock rather than reaching for HEAD.
#
# bash 3.2 / BSD sed only - this file is on the nix setup path.

# Read one scalar field out of nixpkgs_rev.json. That file's shape is owned by
# this repo (flat, one field per line), so a sed extraction is exact and keeps
# the resolver working when jq is absent - jq only ships in the base_init
# scope, so it is likely but not guaranteed to be in the profile.
function _nx_rev_json_field() {
  local _file="$1" _field="$2"
  [ -f "$_file" ] || return 0
  sed -n 's/.*"'"$_field"'"[[:space:]]*:[[:space:]]*"\{0,1\}\([0-9a-zA-Z._-]*\)"\{0,1\}.*/\1/p' "$_file" |
    head -1
}

# Epoch of the nixpkgs revision currently in flake.lock, or "" when it cannot
# be determined. Prefers jq (exact node addressing). Without jq, falls back to
# a sed scan that is only trusted when the lock contains exactly one
# `lastModified` - true while nixpkgs is the flake's single input, and the
# guard is what stops a second input from silently yielding another node's
# timestamp. Callers treat "" as "cannot compare" and proceed.
function _nx_rev_locked_epoch() {
  local _lock="$1/flake.lock"
  [ -f "$_lock" ] || return 0
  if command -v jq >/dev/null 2>&1; then
    jq -r '.nodes.nixpkgs.locked.lastModified // empty' "$_lock" 2>/dev/null
    return 0
  fi
  local _hits
  _hits="$(grep -c '"lastModified"' "$_lock" 2>/dev/null)" || _hits=0
  [ "$_hits" = "1" ] || return 0
  sed -n 's/.*"lastModified"[[:space:]]*:[[:space:]]*\([0-9]*\).*/\1/p' "$_lock" | head -1
}

# Resolve the revision this machine should move to.
#
# $1 env dir, $2 "true" when the caller passed --latest.
# stdout: "<mode> <rev>", or a bare "<mode>" for the `latest` and `none`
# modes, which carry no revision. Callers must not assume a second field.
function _nx_rev_resolve() {
  local _env_dir="$1" _want_latest="${2:-false}" _rev=""

  if [ -f "$_env_dir/pinned_rev" ]; then
    _rev="$(tr -d '[:space:]' <"$_env_dir/pinned_rev")"
    if [ -n "$_rev" ]; then
      printf 'pinned %s\n' "$_rev"
      return 0
    fi
  fi

  if [ "$_want_latest" = "true" ]; then
    printf 'latest\n'
    return 0
  fi

  _rev="$(_nx_rev_json_field "$_env_dir/nixpkgs_rev.json" rev)"
  if [ -n "$_rev" ]; then
    printf 'validated %s\n' "$_rev"
    return 0
  fi

  printf 'none\n'
}

# True (0) when the validated rev is not newer than what is already locked.
#
# Guards the case the whole rolling pin exists to allow: a user who moved ahead
# with `nx upgrade --latest` must not be dragged backwards by a later default
# upgrade, which is what would happen whenever the CI bump is blocked. Going
# back stays available, but only deliberately, via `nx pin set`.
#
# Returns 1 (not a downgrade - proceed) whenever either side is unknown or
# non-numeric: an unverifiable comparison must not block an upgrade.
function _nx_rev_is_downgrade() {
  local _env_dir="$1" _candidate="$2" _locked
  _locked="$(_nx_rev_locked_epoch "$_env_dir")"
  case "$_candidate" in '' | *[!0-9]*) return 1 ;; esac
  case "$_locked" in '' | *[!0-9]*) return 1 ;; esac
  [ "$_candidate" -le "$_locked" ]
}

# flake.lock is the per-machine record of the revision in use, and it is
# rewritten before the slow, cancellable `nix profile upgrade`. Both upgrade
# paths snapshot it first and put it back when the profile never received the
# new revision, so a failed or interrupted upgrade stays on the last working one.
#
# $1 env dir. stdout: backup path, or "" when there is no lock yet.
function _nx_lock_backup() {
  local _lock="$1/flake.lock" _bak
  [ -f "$_lock" ] || return 0
  _bak="$(mktemp "${_lock}.bak.XXXXXX")" || return 1
  command cp "$_lock" "$_bak" || {
    command rm -f "$_bak"
    return 1
  }
  printf '%s\n' "$_bak"
}

# $1 env dir, $2 backup path from _nx_lock_backup. No-op for an empty path.
function _nx_lock_restore() {
  [ -n "${2:-}" ] && [ -f "$2" ] || return 0
  command mv "$2" "$1/flake.lock"
}
