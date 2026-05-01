#!/usr/bin/env bash
: '
# run health check
bash .assets/lib/nx_doctor.sh
# :strict mode (warnings are failures)
bash .assets/lib/nx_doctor.sh --strict
# :JSON output
bash .assets/lib/nx_doctor.sh --json
'
set -eo pipefail

ENV_DIR="${ENV_DIR:-$HOME/.config/nix-env}"
DEV_ENV_DIR="${DEV_ENV_DIR:-$HOME/.config/dev-env}"

# ---------------------------------------------------------------------------
# Adding a check:
#   1. Define `_check_<name>` that prints one of:
#        - empty stdout              -> skip (don't record)
#        - "pass"                    -> recorded as pass
#        - "warn<TAB><detail>"       -> recorded as warn
#        - "fail<TAB><detail>"       -> recorded as fail
#      Functions read globals (ENV_DIR, DEV_ENV_DIR, HOME); never write to them.
#   2. Add the name to CHECKS in the desired execution order.
#   3. Add a bats test in tests/bats/test_nx_doctor.bats.
#   4. Update ARCHITECTURE.md and docs/nx.md tables.
# ---------------------------------------------------------------------------

CHECKS="
  nix_available
  flake_lock
  env_dir_files
  install_record
  scope_binaries
  shell_profile
  shell_config_files
  cert_bundle
  vscode_server_env
  nix_profile
  nix_profile_link
  overlay_dir
  version_skew
"

# ---- check functions -------------------------------------------------------

_check_nix_available() {
  if command -v nix >/dev/null 2>&1; then
    echo "pass"
  else
    printf 'fail\tnix not found in PATH\n'
  fi
}

_check_flake_lock() {
  if [ ! -f "$ENV_DIR/flake.lock" ]; then
    printf 'fail\t%s/flake.lock not found\n' "$ENV_DIR"
    return
  fi
  if ! command -v jq >/dev/null 2>&1; then
    echo "warn	flake.lock exists but jq not available to validate"
    return
  fi
  local _rev
  _rev="$(jq -r '.nodes.nixpkgs.locked.rev // empty' "$ENV_DIR/flake.lock" 2>/dev/null)" || true
  if [ -n "$_rev" ]; then
    echo "pass"
  else
    echo "warn	flake.lock exists but nixpkgs node not found"
  fi
}

_check_env_dir_files() {
  # Verify durable nix-env state files exist. Sync'd by
  # phase_bootstrap_sync_env_dir on every setup run; missing files mean a
  # botched install and subsequent `nx` / `nix profile upgrade` runs fail
  # in opaque ways.
  local _missing="" _f
  for _f in flake.nix nx.sh nx_pkg.sh nx_scope.sh nx_profile.sh nx_lifecycle.sh nx_doctor.sh profile_block.sh config.nix; do
    [ -f "$ENV_DIR/$_f" ] || _missing="${_missing:+$_missing, }$_f"
  done
  if [ -z "$_missing" ]; then
    echo "pass"
  else
    printf 'fail\tmissing in %s: %s\n' "$ENV_DIR" "$_missing"
  fi
}

_check_install_record() {
  if [ ! -f "$DEV_ENV_DIR/install.json" ]; then
    printf 'warn\t%s/install.json not found\n' "$DEV_ENV_DIR"
    return
  fi
  if ! command -v jq >/dev/null 2>&1; then
    echo "pass"
    return
  fi
  local _status _phase
  _status="$(jq -r '.status // empty' "$DEV_ENV_DIR/install.json" 2>/dev/null)" || true
  if [ -z "$_status" ]; then
    echo "warn	install.json exists but missing status field"
  elif [ "$_status" = "success" ]; then
    echo "pass"
  else
    _phase="$(jq -r '.phase // "unknown"' "$DEV_ENV_DIR/install.json" 2>/dev/null)" || true
    printf 'warn\tlast run status: %s (phase: %s)\n' "$_status" "$_phase"
  fi
}

_check_scope_binaries() {
  # Parse "# bins:" comments from scope .nix files (single source of truth).
  local _scopes_dir="" _sd
  for _sd in \
    "$ENV_DIR/scopes" \
    "$(cd "$(dirname "$0")/../../nix/scopes" 2>/dev/null && pwd)"; do
    if [ -d "$_sd" ]; then
      _scopes_dir="$_sd"
      break
    fi
  done
  if [ -z "$_scopes_dir" ] || [ ! -f "$DEV_ENV_DIR/install.json" ] || ! command -v jq >/dev/null 2>&1; then
    echo "warn	cannot verify (scope files or install.json not found)"
    return
  fi
  local _scopes _missing="" _scope _bin _bins
  _scopes="$(jq -r '.scopes[]? // empty' "$DEV_ENV_DIR/install.json" 2>/dev/null)" || true
  for _scope in $_scopes; do
    [ -f "$_scopes_dir/$_scope.nix" ] || continue
    _bins="$(sed -n 's/^# bins: *//p' "$_scopes_dir/$_scope.nix")" || true
    for _bin in $_bins; do
      command -v "$_bin" >/dev/null 2>&1 || _missing="${_missing:+$_missing, }$_scope/$_bin"
    done
  done
  if [ -z "$_missing" ]; then
    echo "pass"
  else
    printf 'warn\tmissing: %s\n' "$_missing"
  fi
}

# Resolve the rc file matching the invoking shell. Used by both shell_profile
# and shell_config_files so the choice stays consistent.
#
# Resolution order:
#   1. NX_INVOKING_SHELL env var - set by the `nx` shell wrapper from
#      $BASH_VERSION / $ZSH_VERSION before delegating to this script. The
#      reliable signal for `nx doctor` invocations.
#   2. In-script $ZSH_VERSION - only set when the script was invoked as
#      `zsh nx_doctor.sh` (rare; the shebang is bash).
#   3. Basename of $SHELL - the user's login shell. Best available signal
#      for direct `bash nx_doctor.sh` invocations from any terminal.
#   4. Final fallback: bash.
_invoking_rc() {
  local _shell="${NX_INVOKING_SHELL:-}"
  if [ -z "$_shell" ]; then
    if [ -n "${ZSH_VERSION:-}" ]; then
      _shell="zsh"
    elif [ -n "${SHELL:-}" ]; then
      _shell="$(basename "$SHELL")"
    else
      _shell="bash"
    fi
  fi
  case "$_shell" in
  zsh) echo "$HOME/.zshrc" ;;
  *) echo "$HOME/.bashrc" ;;
  esac
}

_check_shell_profile() {
  # Audit only the rc file matching the invoking shell - nx.sh sets
  # NX_INVOKING_SHELL based on $BASH_VERSION/$ZSH_VERSION; direct
  # invocations (bats tests, manual `zsh nx_doctor.sh`) fall back to
  # auto-detection in _invoking_rc(). Pwsh has its own `nx profile doctor`
  # (in _aliases_nix.ps1) and is not audited here.
  local _rc _count _name
  _rc="$(_invoking_rc)"
  [ -f "$_rc" ] || {
    echo "pass"
    return
  }
  _count="$(grep -cF '# >>> nix-env managed >>>' "$_rc" 2>/dev/null || true)"
  _name="$(basename "$_rc")"
  if [ "$_count" = "0" ] 2>/dev/null; then
    printf 'fail\tno managed block in %s\n' "$_name"
  elif [ "$_count" -gt 1 ] 2>/dev/null; then
    printf 'fail\t%d duplicate blocks in %s\n' "$_count" "$_name"
  else
    echo "pass"
  fi
}

_check_shell_config_files() {
  # The managed block sources files from ~/.config/shell/. Most are guarded
  # with `[ -f ]` (silent no-op when missing) but `aliases_nix.sh` is
  # unguarded - missing it spams "No such file or directory" on every shell
  # start. Even guarded misses silently lose functionality, so flag any
  # referenced file that doesn't resolve.
  local _rc _missing="" _ref _path
  _rc="$(_invoking_rc)"
  [ -f "$_rc" ] || {
    echo "pass"
    return
  }
  while IFS= read -r _ref; do
    [ -z "$_ref" ] && continue
    _path="$(printf '%s' "$_ref" | sed "s|^\\\$HOME|$HOME|")"
    [ -f "$_path" ] || _missing="${_missing:+$_missing, }${_ref##*/}"
  done < <(grep -oE '\$HOME/\.config/shell/[a-zA-Z0-9_]+\.(sh|bash|zsh)' "$_rc" 2>/dev/null | sort -u)
  if [ -z "$_missing" ]; then
    echo "pass"
  else
    printf 'fail\treferenced by %s but missing in ~/.config/shell/: %s\n' \
      "$(basename "$_rc")" "$_missing"
  fi
}

_check_cert_bundle() {
  # Only relevant when custom certs exist (MITM proxy / corporate CA).
  # No ca-custom.crt means no interception detected - bundle is not needed.
  local _dir="$HOME/.config/certs" _detail=""
  if [ ! -f "$_dir/ca-custom.crt" ]; then
    echo "pass"
    return
  fi
  [ -e "$_dir/ca-bundle.crt" ] || _detail="ca-bundle.crt missing"
  if [ ! -f "$HOME/.vscode-server/server-env-setup" ] ||
    ! grep -q 'NODE_EXTRA_CA_CERTS' "$HOME/.vscode-server/server-env-setup" 2>/dev/null; then
    _detail="${_detail:+$_detail; }NODE_EXTRA_CA_CERTS not in server-env-setup"
  fi
  if [ -z "$_detail" ]; then
    echo "pass"
  else
    printf 'fail\t%s\n' "$_detail"
  fi
}

_check_vscode_server_env() {
  # Only audited when nix is installed (the env-setup is what makes nix tools
  # visible to VS Code Server extensions, which don't source ~/.bashrc).
  [ -d "$HOME/.nix-profile/bin" ] || return
  if [ -f "$HOME/.vscode-server/server-env-setup" ] &&
    grep -q 'nix-profile/bin' "$HOME/.vscode-server/server-env-setup" 2>/dev/null; then
    echo "pass"
  else
    echo "warn	nix PATH not in server-env-setup; run: nx upgrade"
  fi
}

_check_nix_profile() {
  if ! command -v nix >/dev/null 2>&1; then
    echo "fail	nix not available"
    return
  fi
  if nix profile list --json 2>/dev/null | grep -q 'nix-env' ||
    nix profile list 2>/dev/null | grep -q 'nix-env'; then
    echo "pass"
  else
    echo "fail	nix-env not found in nix profile list"
  fi
}

_check_nix_profile_link() {
  # `nix_profile` checks the registry; this verifies the on-disk symlink that
  # user shells (PATH=$HOME/.nix-profile/bin) and managed blocks rely on. A
  # dangling symlink (pointing at a removed generation) breaks every nix-built
  # binary even though nix-env is still listed in `nix profile list`.
  local _link="$HOME/.nix-profile" _target
  if [ -L "$_link" ]; then
    if [ -e "$_link" ]; then
      echo "pass"
    else
      _target="$(readlink "$_link" 2>/dev/null)" || _target="<unreadable>"
      printf 'fail\tdangling symlink -> %s\n' "$_target"
    fi
  elif [ -d "$_link" ]; then
    printf 'warn\t%s is a directory, not a symlink (unexpected layout)\n' "$_link"
  else
    printf 'fail\t%s not found\n' "$_link"
  fi
}

_check_overlay_dir() {
  # Only audited when the user has opted into an overlay directory.
  [ -n "${NIX_ENV_OVERLAY_DIR:-}" ] || return
  if [ -d "$NIX_ENV_OVERLAY_DIR" ] && [ -r "$NIX_ENV_OVERLAY_DIR" ]; then
    echo "pass"
  else
    printf 'fail\tNIX_ENV_OVERLAY_DIR=%s is not a readable directory\n' "$NIX_ENV_OVERLAY_DIR"
  fi
}

_check_version_skew() {
  # Only audited when gh+jq are available (no point fetching releases without them).
  command -v gh >/dev/null 2>&1 || return
  command -v jq >/dev/null 2>&1 || return
  local _slug="" _git_dir _installed _latest_tag _latest
  for _git_dir in \
    "$(cd "$(dirname "$0")/../.." 2>/dev/null && pwd)" \
    "$ENV_DIR"; do
    if [ -d "$_git_dir/.git" ] 2>/dev/null; then
      _slug="$(git -C "$_git_dir" remote get-url origin 2>/dev/null |
        sed -n 's|.*github\.com[:/]\(.*\)\.git$|\1|p')" || true
      [ -n "$_slug" ] && break
    fi
  done
  [ -n "$_slug" ] || return
  _installed=""
  if [ -f "$DEV_ENV_DIR/install.json" ]; then
    _installed="$(jq -r '.version // empty' "$DEV_ENV_DIR/install.json" 2>/dev/null)" || true
  fi
  _latest_tag="$(gh api "repos/$_slug/releases/latest" --jq '.tag_name' 2>/dev/null)" || true
  _latest="${_latest_tag#v}"
  [ -n "$_latest" ] || return
  if [ -n "$_installed" ] && [ "$_latest" != "$_installed" ]; then
    printf 'warn\tinstalled %s, latest release %s\n' "$_installed" "$_latest"
  else
    echo "pass"
  fi
}

# ---- runner ----------------------------------------------------------------

_dr_pass=0
_dr_fail=0
_dr_warn=0
_dr_json="false"
_dr_strict="false"
_dr_checks=""

while [ $# -gt 0 ]; do
  case "$1" in
  --json) _dr_json="true" ;;
  --strict) _dr_strict="true" ;;
  esac
  shift
done

_record() {
  local name="$1" status="$2" detail="${3:-}"
  if [ "$status" = "pass" ]; then
    _dr_pass=$((_dr_pass + 1))
    [ "$_dr_json" = "false" ] && printf '\e[32m  PASS  %s\e[0m\n' "$name"
  elif [ "$status" = "warn" ]; then
    _dr_warn=$((_dr_warn + 1))
    [ "$_dr_json" = "false" ] && printf '\e[33m  WARN  %s: %s\e[0m\n' "$name" "$detail"
  else
    _dr_fail=$((_dr_fail + 1))
    [ "$_dr_json" = "false" ] && printf '\e[31m  FAIL  %s: %s\e[0m\n' "$name" "$detail"
  fi
  [ -n "$_dr_checks" ] && _dr_checks="$_dr_checks,"
  local _esc
  _esc="$(printf '%s' "$detail" | sed 's/\\/\\\\/g; s/"/\\"/g')"
  _dr_checks="${_dr_checks}{\"name\":\"$name\",\"status\":\"$status\",\"detail\":\"$_esc\"}"
}

_run_check() {
  local _name="$1" _result _status _detail
  _result="$("_check_$_name")" || true
  [ -z "$_result" ] && return
  case "$_result" in
  *$'\t'*)
    _status="${_result%%$'\t'*}"
    _detail="${_result#*$'\t'}"
    ;;
  *)
    _status="$_result"
    _detail=""
    ;;
  esac
  _record "$_name" "$_status" "$_detail"
}

for _name in $CHECKS; do
  _run_check "$_name"
done

# ---- summary ---------------------------------------------------------------

if [ "$_dr_json" = "true" ]; then
  _overall="ok"
  [ "$_dr_warn" -gt 0 ] && _overall="degraded"
  [ "$_dr_fail" -gt 0 ] && _overall="broken"
  if command -v jq >/dev/null 2>&1; then
    printf '{"status":"%s","pass":%d,"warn":%d,"fail":%d,"checks":[%s]}' \
      "$_overall" "$_dr_pass" "$_dr_warn" "$_dr_fail" "$_dr_checks" | jq .
  else
    printf '{"status":"%s","pass":%d,"warn":%d,"fail":%d,"checks":[%s]}\n' \
      "$_overall" "$_dr_pass" "$_dr_warn" "$_dr_fail" "$_dr_checks"
  fi
else
  printf '\n'
  if [ "$_dr_fail" -gt 0 ]; then
    printf '\e[31m  %d passed, %d warnings, %d failed\e[0m\n' "$_dr_pass" "$_dr_warn" "$_dr_fail"
  elif [ "$_dr_warn" -gt 0 ]; then
    printf '\e[33m  %d passed, %d warnings\e[0m\n' "$_dr_pass" "$_dr_warn"
  else
    printf '\e[32m  all %d checks passed\e[0m\n' "$_dr_pass"
  fi
fi

if [ "$_dr_strict" = "true" ]; then
  [ $((_dr_fail + _dr_warn)) -eq 0 ] || exit 1
else
  [ "$_dr_fail" -eq 0 ] || exit 1
fi
