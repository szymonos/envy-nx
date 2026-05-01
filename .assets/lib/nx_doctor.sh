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

_dr_pass=0 _dr_fail=0 _dr_warn=0
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

_check() {
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
  if [ -n "$_dr_checks" ]; then
    _dr_checks="$_dr_checks,"
  fi
  local escaped_detail
  escaped_detail="$(printf '%s' "$detail" | sed 's/\\/\\\\/g; s/"/\\"/g')"
  _dr_checks="${_dr_checks}{\"name\":\"$name\",\"status\":\"$status\",\"detail\":\"$escaped_detail\"}"
}

# -- 1. nix_available --------------------------------------------------------
if command -v nix >/dev/null 2>&1; then
  _check "nix_available" "pass"
else
  _check "nix_available" "fail" "nix not found in PATH"
fi

# -- 2. flake_lock ------------------------------------------------------------
if [ -f "$ENV_DIR/flake.lock" ]; then
  if command -v jq >/dev/null 2>&1; then
    _nixpkgs_rev="$(jq -r '.nodes.nixpkgs.locked.rev // empty' "$ENV_DIR/flake.lock" 2>/dev/null)" || true
    if [ -n "$_nixpkgs_rev" ]; then
      _check "flake_lock" "pass"
    else
      _check "flake_lock" "warn" "flake.lock exists but nixpkgs node not found"
    fi
  else
    _check "flake_lock" "warn" "flake.lock exists but jq not available to validate"
  fi
else
  _check "flake_lock" "fail" "$ENV_DIR/flake.lock not found"
fi

# -- 3. env_dir_files --------------------------------------------------------
# Verify the durable nix-env state files exist. Each is sync'd by
# phase_bootstrap_sync_env_dir on every setup run; missing files mean a
# botched install (sync failed mid-run, or files were manually deleted) and
# subsequent `nx` commands or `nix/setup.sh` runs will fail in opaque ways.
_env_missing=""
for _f in flake.nix nx.sh nx_doctor.sh profile_block.sh config.nix; do
  [ -f "$ENV_DIR/$_f" ] || _env_missing="${_env_missing:+$_env_missing, }$_f"
done
if [ -z "$_env_missing" ]; then
  _check "env_dir_files" "pass"
else
  _check "env_dir_files" "fail" "missing in $ENV_DIR: $_env_missing"
fi

# -- 4. install_record -------------------------------------------------------
if [ -f "$DEV_ENV_DIR/install.json" ]; then
  if command -v jq >/dev/null 2>&1; then
    _ir_status="$(jq -r '.status // empty' "$DEV_ENV_DIR/install.json" 2>/dev/null)" || true
    if [ -n "$_ir_status" ]; then
      if [ "$_ir_status" = "success" ]; then
        _check "install_record" "pass"
      else
        _ir_phase="$(jq -r '.phase // "unknown"' "$DEV_ENV_DIR/install.json" 2>/dev/null)" || true
        _check "install_record" "warn" "last run status: $_ir_status (phase: $_ir_phase)"
      fi
    else
      _check "install_record" "warn" "install.json exists but missing status field"
    fi
  else
    _check "install_record" "pass"
  fi
else
  _check "install_record" "warn" "$DEV_ENV_DIR/install.json not found"
fi

# -- 5. scope_binaries -------------------------------------------------------
# Parse "# bins:" comments from scope .nix files (single source of truth).
_scopes_dir=""
for _sd_path in \
  "$ENV_DIR/scopes" \
  "$(cd "$(dirname "$0")/../../nix/scopes" 2>/dev/null && pwd)"; do
  if [ -d "$_sd_path" ]; then
    _scopes_dir="$_sd_path"
    break
  fi
done

if [ -n "$_scopes_dir" ] && [ -f "$DEV_ENV_DIR/install.json" ] && command -v jq >/dev/null 2>&1; then
  _installed_scopes="$(jq -r '.scopes[]? // empty' "$DEV_ENV_DIR/install.json" 2>/dev/null)" || true
  _missing_bins=""
  for _scope in $_installed_scopes; do
    _nix_file="$_scopes_dir/$_scope.nix"
    [ -f "$_nix_file" ] || continue
    _bins="$(sed -n 's/^# bins: *//p' "$_nix_file")" || true
    for _bin in $_bins; do
      if ! command -v "$_bin" >/dev/null 2>&1; then
        _missing_bins="${_missing_bins:+$_missing_bins, }$_scope/$_bin"
      fi
    done
  done
  if [ -z "$_missing_bins" ]; then
    _check "scope_binaries" "pass"
  else
    _check "scope_binaries" "warn" "missing: $_missing_bins"
  fi
else
  _check "scope_binaries" "warn" "cannot verify (scope files or install.json not found)"
fi

# -- 6. shell_profile --------------------------------------------------------
# Audit only the rc file matching the invoking shell. nx.sh sets
# NX_INVOKING_SHELL based on $BASH_VERSION/$ZSH_VERSION (it's sourced into
# the user's shell, so it knows which one). Default to bash for direct
# script invocations (bats tests, manual `bash nx_doctor.sh`). Pwsh has
# its own `nx profile doctor` (in _aliases_nix.ps1) and is not audited here.
case "${NX_INVOKING_SHELL:-bash}" in
zsh) _rc="$HOME/.zshrc" ;;
*) _rc="$HOME/.bashrc" ;;
esac
_profile_ok=true
_profile_detail=""
_block_marker="nix-env managed"
if [ -f "$_rc" ]; then
  _count="$(grep -cF "# >>> $_block_marker >>>" "$_rc" 2>/dev/null || true)"
  _rc_name="$(basename "$_rc")"
  if [ "$_count" = "0" ] 2>/dev/null; then
    _profile_detail="no managed block in $_rc_name"
    _profile_ok=false
  elif [ "$_count" -gt 1 ] 2>/dev/null; then
    _profile_detail="$_count duplicate blocks in $_rc_name"
    _profile_ok=false
  fi
fi
if [ "$_profile_ok" = true ]; then
  _check "shell_profile" "pass"
else
  _check "shell_profile" "fail" "$_profile_detail"
fi

# -- 7. shell_config_files ---------------------------------------------------
# The managed block sources files from ~/.config/shell/. Most are guarded
# with `[ -f ]` (silent no-op when missing) but `aliases_nix.sh` is
# unguarded - missing it spams "No such file or directory" on every shell
# start. Even guarded misses silently lose functionality, so flag any
# referenced file that doesn't resolve.
_shell_missing=""
if [ -f "$_rc" ]; then
  while IFS= read -r _ref; do
    [ -z "$_ref" ] && continue
    _path="$(printf '%s' "$_ref" | sed "s|^\\\$HOME|$HOME|")"
    [ -f "$_path" ] || _shell_missing="${_shell_missing:+$_shell_missing, }${_ref##*/}"
  done < <(grep -oE '\$HOME/\.config/shell/[a-zA-Z0-9_]+\.(sh|bash|zsh)' "$_rc" 2>/dev/null | sort -u)
fi
if [ -z "$_shell_missing" ]; then
  _check "shell_config_files" "pass"
else
  _check "shell_config_files" "fail" "referenced by $(basename "$_rc") but missing in ~/.config/shell/: $_shell_missing"
fi

# -- 8. cert_bundle -----------------------------------------------------------
# Only relevant when custom certs exist (MITM proxy / corporate CA).
# No ca-custom.crt means no interception detected - bundle is not needed.
_cert_dir="$HOME/.config/certs"
_cert_ok=true
_cert_detail=""
if [ -f "$_cert_dir/ca-custom.crt" ]; then
  if [ ! -e "$_cert_dir/ca-bundle.crt" ]; then
    _cert_detail="ca-bundle.crt missing"
    _cert_ok=false
  fi
  if [ ! -f "$HOME/.vscode-server/server-env-setup" ] ||
    ! grep -q 'NODE_EXTRA_CA_CERTS' "$HOME/.vscode-server/server-env-setup" 2>/dev/null; then
    _cert_detail="${_cert_detail:+$_cert_detail; }NODE_EXTRA_CA_CERTS not in server-env-setup"
    _cert_ok=false
  fi
fi
if [ "$_cert_ok" = true ]; then
  _check "cert_bundle" "pass"
else
  _check "cert_bundle" "fail" "$_cert_detail"
fi

# -- 9. vscode_server_env ----------------------------------------------------
if [ -d "$HOME/.nix-profile/bin" ]; then
  if [ -f "$HOME/.vscode-server/server-env-setup" ] &&
    grep -q 'nix-profile/bin' "$HOME/.vscode-server/server-env-setup" 2>/dev/null; then
    _check "vscode_server_env" "pass"
  else
    _check "vscode_server_env" "warn" "nix PATH not in server-env-setup; run: nx upgrade"
  fi
fi

# -- 10. nix_profile ---------------------------------------------------------
if command -v nix >/dev/null 2>&1; then
  if nix profile list --json 2>/dev/null | grep -q 'nix-env'; then
    _check "nix_profile" "pass"
  elif nix profile list 2>/dev/null | grep -q 'nix-env'; then
    _check "nix_profile" "pass"
  else
    _check "nix_profile" "fail" "nix-env not found in nix profile list"
  fi
else
  _check "nix_profile" "fail" "nix not available"
fi

# -- 11. nix_profile_link ----------------------------------------------------
# `nix_profile` checks the registry; this verifies the on-disk symlink that
# user shells (PATH=$HOME/.nix-profile/bin) and managed blocks rely on. A
# dangling symlink (pointing at a removed generation) breaks every nix-built
# binary even though nix-env is still listed in `nix profile list`.
_np_link="$HOME/.nix-profile"
if [ -L "$_np_link" ]; then
  if [ -e "$_np_link" ]; then
    _check "nix_profile_link" "pass"
  else
    _np_target="$(readlink "$_np_link" 2>/dev/null)" || _np_target="<unreadable>"
    _check "nix_profile_link" "fail" "dangling symlink -> $_np_target"
  fi
elif [ -d "$_np_link" ]; then
  _check "nix_profile_link" "warn" "$_np_link is a directory, not a symlink (unexpected layout)"
else
  _check "nix_profile_link" "fail" "$_np_link not found"
fi

# -- 12. overlay_dir ---------------------------------------------------------
if [ -n "${NIX_ENV_OVERLAY_DIR:-}" ]; then
  if [ -d "$NIX_ENV_OVERLAY_DIR" ] && [ -r "$NIX_ENV_OVERLAY_DIR" ]; then
    _check "overlay_dir" "pass"
  else
    _check "overlay_dir" "fail" "NIX_ENV_OVERLAY_DIR=$NIX_ENV_OVERLAY_DIR is not a readable directory"
  fi
fi

# -- 13. version_skew --------------------------------------------------------
if command -v gh >/dev/null 2>&1 && command -v jq >/dev/null 2>&1; then
  _repo_slug=""
  for _git_dir in \
    "$(cd "$(dirname "$0")/../.." 2>/dev/null && pwd)" \
    "$ENV_DIR"; do
    if [ -d "$_git_dir/.git" ] 2>/dev/null; then
      _repo_slug="$(git -C "$_git_dir" remote get-url origin 2>/dev/null |
        sed -n 's|.*github\.com[:/]\(.*\)\.git$|\1|p')" || true
      [ -n "$_repo_slug" ] && break
    fi
  done
  if [ -n "$_repo_slug" ]; then
    _installed_ver=""
    if [ -f "$DEV_ENV_DIR/install.json" ]; then
      _installed_ver="$(jq -r '.version // empty' "$DEV_ENV_DIR/install.json" 2>/dev/null)" || true
    fi
    _latest_tag="$(gh api "repos/$_repo_slug/releases/latest" --jq '.tag_name' 2>/dev/null)" || true
    _latest_ver="${_latest_tag#v}"
    if [ -n "$_latest_ver" ] && [ -n "$_installed_ver" ] && [ "$_latest_ver" != "$_installed_ver" ]; then
      _check "version_skew" "warn" "installed $_installed_ver, latest release $_latest_ver"
    elif [ -n "$_latest_ver" ]; then
      _check "version_skew" "pass"
    fi
  fi
fi

# -- Summary ------------------------------------------------------------------
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
