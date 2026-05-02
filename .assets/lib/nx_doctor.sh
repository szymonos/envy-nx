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
#        - empty stdout                                  -> skip (don't record)
#        - "pass"                                        -> recorded as pass
#        - "warn<TAB><detail>"                           -> recorded as warn
#        - "warn<TAB><detail><TAB><remediation>"         -> warn with Fix hint
#        - "fail<TAB><detail>"                           -> recorded as fail
#        - "fail<TAB><detail><TAB><remediation>"         -> fail with Fix hint
#      The optional remediation is rendered as `Fix: <text>` indented under the
#      check line and included in the JSON output and ~/.config/dev-env/doctor.log.
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
  scope_bins_in_profile
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
  if ! command -v nix >/dev/null 2>&1; then
    printf 'fail\tnix not found in PATH\tinstall Nix from https://nixos.org/download (or re-clone envy-nx and run .assets/scripts/linux_setup.sh)\n'
    return
  fi
  # Extract the trailing X.Y[.Z] from `nix --version`. Output format varies by distribution:
  #   "nix (Nix) 2.18.1"                     -> 2.18.1
  #   "nix (Determinate Nix 3.6.5) 2.34.1"   -> 2.34.1 (the trailing number is the actual nix version)
  # Floor: 2.18 (flake-stability era used by current nixpkgs-unstable; older nix produces cryptic errors).
  local _ver _major _minor
  _ver="$(nix --version 2>/dev/null | grep -oE '[0-9]+\.[0-9]+(\.[0-9]+)?' | tail -1)"
  if [ -z "$_ver" ]; then
    printf 'warn\tnix present but version not parseable\trun nix --version manually; if output is malformed, reinstall nix from https://nixos.org/download\n'
    return
  fi
  _major="${_ver%%.*}"
  _minor="${_ver#*.}"
  _minor="${_minor%%.*}"
  if [ "$_major" -lt 2 ] || { [ "$_major" -eq 2 ] && [ "$_minor" -lt 18 ]; }; then
    printf 'fail\tnix %s is below the supported floor (2.18)\tupgrade nix via .assets/provision/install_nix.sh or https://nixos.org/download\n' "$_ver"
    return
  fi
  echo "pass"
}

_check_flake_lock() {
  if [ ! -f "$ENV_DIR/flake.lock" ]; then
    printf 'fail\t%s/flake.lock not found\tre-run nix/setup.sh to generate ~/.config/nix-env/flake.lock\n' "$ENV_DIR"
    return
  fi
  if ! command -v jq >/dev/null 2>&1; then
    printf 'warn\tflake.lock exists but jq not available to validate\tinstall jq, then re-run nx doctor\n'
    return
  fi
  local _rev
  _rev="$(jq -r '.nodes.nixpkgs.locked.rev // empty' "$ENV_DIR/flake.lock" 2>/dev/null)" || true
  if [ -n "$_rev" ]; then
    echo "pass"
  else
    printf 'warn\tflake.lock exists but nixpkgs node not found\tre-run nx upgrade to refresh flake.lock\n'
  fi
}

_check_env_dir_files() {
  # Verify durable nix-env state files exist. Sync'd by
  # phase_bootstrap_sync_env_dir on every setup run; missing files mean a
  # botched install and subsequent `nx` / `nix profile upgrade` runs fail
  # in opaque ways.
  local _missing="" _f
  # >>> nx-libs generated >>> (regenerate: python3 -m tests.hooks.gen_nx_completions)
  for _f in flake.nix nx.sh nx_lifecycle.sh nx_pkg.sh nx_profile.sh nx_scope.sh nx_doctor.sh profile_block.sh config.nix; do
    # <<< nx-libs generated <<<
    [ -f "$ENV_DIR/$_f" ] || _missing="${_missing:+$_missing, }$_f"
  done
  if [ -z "$_missing" ]; then
    echo "pass"
  else
    printf 'fail\tmissing in %s: %s\trun nx self sync to copy lib files into ~/.config/nix-env/\n' "$ENV_DIR" "$_missing"
  fi
}

_check_install_record() {
  if [ ! -f "$DEV_ENV_DIR/install.json" ]; then
    printf 'warn\t%s/install.json not found\tre-run nix/setup.sh to record install provenance\n' "$DEV_ENV_DIR"
    return
  fi
  if ! command -v jq >/dev/null 2>&1; then
    echo "pass"
    return
  fi
  local _status _phase
  _status="$(jq -r '.status // empty' "$DEV_ENV_DIR/install.json" 2>/dev/null)" || true
  if [ -z "$_status" ]; then
    printf 'warn\tinstall.json exists but missing status field\tre-run nix/setup.sh to refresh provenance\n'
  elif [ "$_status" = "success" ]; then
    echo "pass"
  else
    _phase="$(jq -r '.phase // "unknown"' "$DEV_ENV_DIR/install.json" 2>/dev/null)" || true
    printf 'warn\tlast run status: %s (phase: %s)\tinspect ~/.config/dev-env/setup.log and re-run nix/setup.sh\n' "$_status" "$_phase"
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
    printf 'warn\tcannot verify (scope files or install.json not found)\tre-run nix/setup.sh to populate scope files and install.json\n'
    return
  fi
  local _scopes _missing="" _scope _bin _bins
  _scopes="$(jq -r '.scopes[]? // empty' "$DEV_ENV_DIR/install.json" 2>/dev/null)" || true
  for _scope in $_scopes; do
    [ -f "$_scopes_dir/$_scope.nix" ] || continue
    _bins="$(sed -n 's/^# bins: *//p' "$_scopes_dir/$_scope.nix")" || true
    # Sentinel `(external-installer)` marks scopes managed by an installer
    # other than nix (e.g. conda via miniforge), so neither command -v
    # nor ~/.nix-profile/bin checks apply.
    case "$_bins" in '('*) continue ;; esac
    for _bin in $_bins; do
      command -v "$_bin" >/dev/null 2>&1 || _missing="${_missing:+$_missing, }$_scope/$_bin"
    done
  done
  if [ -z "$_missing" ]; then
    echo "pass"
  else
    printf 'warn\tmissing: %s\trun nx upgrade; if a scope was removed by hand, re-add via nx scope add <scope>\n' "$_missing"
  fi
}

_check_scope_bins_in_profile() {
  # Behavior check (tighter than scope_binaries): for each scope's # bins:,
  # verify the binary exists specifically under ~/.nix-profile/bin/, not just
  # somewhere on $PATH. Catches the case where the binary is found via system
  # install or another tool but nix never actually provided it - meaning the
  # scope is silently broken and `nx upgrade` / uninstall would leave the
  # user with a binary they cannot manage. Skipped when ~/.nix-profile is
  # absent (no nix install) or when the inputs scope_binaries needs are missing.
  [ -d "$HOME/.nix-profile/bin" ] || return
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
    return
  fi
  local _scopes _missing="" _scope _bin _bins
  _scopes="$(jq -r '.scopes[]? // empty' "$DEV_ENV_DIR/install.json" 2>/dev/null)" || true
  for _scope in $_scopes; do
    [ -f "$_scopes_dir/$_scope.nix" ] || continue
    _bins="$(sed -n 's/^# bins: *//p' "$_scopes_dir/$_scope.nix")" || true
    # Sentinel `(external-installer)` - see _check_scope_binaries above.
    case "$_bins" in '('*) continue ;; esac
    for _bin in $_bins; do
      [ -x "$HOME/.nix-profile/bin/$_bin" ] || _missing="${_missing:+$_missing, }$_scope/$_bin"
    done
  done
  if [ -z "$_missing" ]; then
    echo "pass"
  else
    printf 'fail\tnot in ~/.nix-profile/bin: %s\trun nx upgrade to reinstall the scope; if found on PATH from another source, that binary is not nix-managed\n' "$_missing"
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
  # Count BOTH the new marker (nix:managed, since 1.5) and the legacy marker
  # (nix-env managed, <= 1.4) as a managed block. Users who upgraded but
  # haven't yet run `nx profile regenerate` still have the legacy block;
  # that's a valid transitional state, not a failure. Migration happens
  # silently on the next regenerate call. After the legacy migration
  # window closes, drop the _legacy_count line.
  local _new_count _legacy_count
  _new_count="$(grep -cF '# >>> nix:managed >>>' "$_rc" 2>/dev/null || true)"
  _legacy_count="$(grep -cF '# >>> nix-env managed >>>' "$_rc" 2>/dev/null || true)"
  _count=$((_new_count + _legacy_count))
  _name="$(basename "$_rc")"
  if [ "$_count" = "0" ] 2>/dev/null; then
    printf 'fail\tno managed block in %s\trun nx profile regenerate to insert the managed block\n' "$_name"
  elif [ "$_count" -gt 1 ] 2>/dev/null; then
    printf 'fail\t%d duplicate blocks in %s\trun nx profile regenerate (it deduplicates the block)\n' "$_count" "$_name"
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
    printf 'fail\treferenced by %s but missing in ~/.config/shell/: %s\trun nx self sync to refresh ~/.config/shell/\n' \
      "$(basename "$_rc")" "$_missing"
  fi
}

_check_cert_bundle() {
  # Only relevant when custom certs exist (MITM proxy / corporate CA).
  # No ca-custom.crt means no interception detected - bundle is not needed.
  local _dir="$HOME/.config/certs" _detail="" _fix=""
  if [ ! -f "$_dir/ca-custom.crt" ]; then
    echo "pass"
    return
  fi
  if [ ! -e "$_dir/ca-bundle.crt" ]; then
    _detail="ca-bundle.crt missing"
    _fix="run cert_intercept (from .assets/config/shell_cfg/functions.sh) to rebuild ~/.config/certs/ca-bundle.crt"
  fi
  if [ ! -f "$HOME/.vscode-server/server-env-setup" ] ||
    ! grep -q 'NODE_EXTRA_CA_CERTS' "$HOME/.vscode-server/server-env-setup" 2>/dev/null; then
    _detail="${_detail:+$_detail; }NODE_EXTRA_CA_CERTS not in server-env-setup"
    _fix="${_fix:+$_fix && }re-run nix/setup.sh to refresh ~/.vscode-server/server-env-setup"
  fi
  if [ -z "$_detail" ]; then
    echo "pass"
  else
    printf 'fail\t%s\t%s\n' "$_detail" "$_fix"
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
    printf 'warn\tnix PATH not in server-env-setup\trun nx upgrade to regenerate ~/.vscode-server/server-env-setup\n'
  fi
}

_check_nix_profile() {
  if ! command -v nix >/dev/null 2>&1; then
    printf 'fail\tnix not available\tinstall Nix from https://nixos.org/download (or re-clone envy-nx and run .assets/scripts/linux_setup.sh)\n'
    return
  fi
  if nix profile list --json 2>/dev/null | grep -q 'nix-env' ||
    nix profile list 2>/dev/null | grep -q 'nix-env'; then
    echo "pass"
  else
    printf 'fail\tnix-env not found in nix profile list\tre-run nix/setup.sh to install the nix-env profile\n'
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
      printf 'fail\tdangling symlink -> %s\trun nx upgrade; the previous generation may have been garbage-collected\n' "$_target"
    fi
  elif [ -d "$_link" ]; then
    printf 'warn\t%s is a directory, not a symlink (unexpected layout)\tmove ~/.nix-profile aside (it should be a symlink) and re-run nix/setup.sh\n' "$_link"
  else
    printf 'fail\t%s not found\tre-run nix/setup.sh to recreate ~/.nix-profile\n' "$_link"
  fi
}

_check_overlay_dir() {
  # Only audited when the user has opted into an overlay directory.
  [ -n "${NIX_ENV_OVERLAY_DIR:-}" ] || return
  if [ -d "$NIX_ENV_OVERLAY_DIR" ] && [ -r "$NIX_ENV_OVERLAY_DIR" ]; then
    echo "pass"
  else
    printf 'fail\tNIX_ENV_OVERLAY_DIR=%s is not a readable directory\tverify NIX_ENV_OVERLAY_DIR points at an existing readable directory or unset it\n' "$NIX_ENV_OVERLAY_DIR"
  fi
}

_check_version_skew() {
  # Skipped under tests (NX_DOCTOR_SKIP_NETWORK=1) to avoid 100s of parallel
  # `gh api` calls hammering GitHub - rate limits aside, `gh` can hang
  # indefinitely when auth is expired/missing in a sandbox HOME because it
  # tries to prompt on /dev/tty. Tests explicitly opt out; production users
  # see normal behavior.
  [ "${NX_DOCTOR_SKIP_NETWORK:-0}" = "1" ] && return
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
  # Production safety: best-effort timeout on the gh call so a hung auth
  # prompt or unreachable network doesn't wedge `nx doctor`. 5s is generous -
  # normal gh api responses are <500ms. timeout(1) ships with GNU coreutils
  # (Linux/WSL); macOS userland doesn't have it but brewed coreutils provides
  # `gtimeout`. When neither is available the gh call runs unbounded - gh's
  # internal http timeout (~30s) is the worst-case fallback.
  local _ghcmd
  if command -v timeout >/dev/null 2>&1; then
    _ghcmd="timeout 5 gh"
  elif command -v gtimeout >/dev/null 2>&1; then
    _ghcmd="gtimeout 5 gh"
  else
    _ghcmd="gh"
  fi
  # shellcheck disable=SC2086  # intentional split of "timeout 5 gh" into argv
  _latest_tag="$($_ghcmd api "repos/$_slug/releases/latest" --jq '.tag_name' 2>/dev/null)" || true
  _latest="${_latest_tag#v}"
  [ -n "$_latest" ] || return
  if [ -n "$_installed" ] && [ "$_latest" != "$_installed" ]; then
    printf 'warn\tinstalled %s, latest release %s\tgit pull && nx upgrade to reach the latest release\n' "$_installed" "$_latest"
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
_dr_log_path="$DEV_ENV_DIR/doctor.log"
_dr_log_body=""

while [ $# -gt 0 ]; do
  case "$1" in
  --json) _dr_json="true" ;;
  --strict) _dr_strict="true" ;;
  esac
  shift
done

# Append a line to the log buffer (no ANSI codes; mirrors terminal layout).
_log_line() {
  _dr_log_body="${_dr_log_body}$1
"
}

_record() {
  local name="$1" status="$2" detail="${3:-}" remediation="${4:-}"
  if [ "$status" = "pass" ]; then
    _dr_pass=$((_dr_pass + 1))
    [ "$_dr_json" = "false" ] && printf '\e[32m  PASS  %s\e[0m\n' "$name"
    _log_line "  PASS  $name"
  elif [ "$status" = "warn" ]; then
    _dr_warn=$((_dr_warn + 1))
    [ "$_dr_json" = "false" ] && printf '\e[33m  WARN  %s: %s\e[0m\n' "$name" "$detail"
    _log_line "  WARN  $name: $detail"
    if [ -n "$remediation" ]; then
      [ "$_dr_json" = "false" ] && printf '\e[33m        Fix: %s\e[0m\n' "$remediation"
      _log_line "        Fix: $remediation"
    fi
  else
    _dr_fail=$((_dr_fail + 1))
    [ "$_dr_json" = "false" ] && printf '\e[31m  FAIL  %s: %s\e[0m\n' "$name" "$detail"
    _log_line "  FAIL  $name: $detail"
    if [ -n "$remediation" ]; then
      [ "$_dr_json" = "false" ] && printf '\e[31m        Fix: %s\e[0m\n' "$remediation"
      _log_line "        Fix: $remediation"
    fi
  fi
  [ -n "$_dr_checks" ] && _dr_checks="$_dr_checks,"
  local _esc_d _esc_r
  _esc_d="$(printf '%s' "$detail" | sed 's/\\/\\\\/g; s/"/\\"/g')"
  _esc_r="$(printf '%s' "$remediation" | sed 's/\\/\\\\/g; s/"/\\"/g')"
  _dr_checks="${_dr_checks}{\"name\":\"$name\",\"status\":\"$status\",\"detail\":\"$_esc_d\",\"remediation\":\"$_esc_r\"}"
}

_run_check() {
  local _name="$1" _result _status _detail _remediation _rest
  _result="$("_check_$_name")" || true
  [ -z "$_result" ] && return
  case "$_result" in
  *$'\t'*)
    _status="${_result%%$'\t'*}"
    _rest="${_result#*$'\t'}"
    case "$_rest" in
    *$'\t'*)
      _detail="${_rest%%$'\t'*}"
      _remediation="${_rest#*$'\t'}"
      ;;
    *)
      _detail="$_rest"
      _remediation=""
      ;;
    esac
    ;;
  *)
    _status="$_result"
    _detail=""
    _remediation=""
    ;;
  esac
  _record "$_name" "$_status" "$_detail" "$_remediation"
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
  _summary=""
  if [ "$_dr_fail" -gt 0 ]; then
    _summary="$(printf '  %d passed, %d warnings, %d failed' "$_dr_pass" "$_dr_warn" "$_dr_fail")"
    printf '\e[31m%s\e[0m\n' "$_summary"
  elif [ "$_dr_warn" -gt 0 ]; then
    _summary="$(printf '  %d passed, %d warnings' "$_dr_pass" "$_dr_warn")"
    printf '\e[33m%s\e[0m\n' "$_summary"
  else
    _summary="$(printf '  all %d checks passed' "$_dr_pass")"
    printf '\e[32m%s\e[0m\n' "$_summary"
  fi

  # Write plain-text log to $DEV_ENV_DIR/doctor.log (atomic). Header carries
  # context useful when sharing the log: invocation time, host, invoking shell
  # (so the reader can see which rc file the shell_profile check audited),
  # and the resolved nix-env / dev-env directories.
  _log_shell="${NX_INVOKING_SHELL:-}"
  if [ -z "$_log_shell" ]; then
    if [ -n "${ZSH_VERSION:-}" ]; then
      _log_shell="zsh"
    elif [ -n "${SHELL:-}" ]; then
      _log_shell="$(basename "$SHELL")"
    else
      _log_shell="bash"
    fi
  fi
  _log_date="$(date -u +'%Y-%m-%dT%H:%M:%SZ' 2>/dev/null)" || _log_date="unknown"
  _log_host="$(uname -nsr 2>/dev/null)" || _log_host="unknown"
  if mkdir -p "$(dirname "$_dr_log_path")" 2>/dev/null; then
    _log_tmp="${_dr_log_path}.tmp.$$"
    {
      printf 'nx doctor diagnostics\n'
      printf 'date:    %s\n' "$_log_date"
      printf 'host:    %s\n' "$_log_host"
      printf 'shell:   %s\n' "$_log_shell"
      printf 'env_dir: %s\n' "$ENV_DIR"
      printf 'dev_dir: %s\n' "$DEV_ENV_DIR"
      printf '\n'
      printf '%s' "$_dr_log_body"
      printf '\n%s\n' "$_summary"
    } >"$_log_tmp" 2>/dev/null && mv "$_log_tmp" "$_dr_log_path" 2>/dev/null || rm -f "$_log_tmp" 2>/dev/null
  fi

  if [ $((_dr_fail + _dr_warn)) -gt 0 ] && [ -f "$_dr_log_path" ]; then
    printf '  Full log: %s\n' "$_dr_log_path"
  fi
fi

if [ "$_dr_strict" = "true" ]; then
  [ $((_dr_fail + _dr_warn)) -eq 0 ] || exit 1
else
  [ "$_dr_fail" -eq 0 ] || exit 1
fi
