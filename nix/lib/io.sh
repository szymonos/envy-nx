# Side-effect wrappers for nix/setup.sh phases.
# Tests override these functions to stub external commands.

# -- Structured output helpers -------------------------------------------------
# Format: timestamp|LEVEL|source:line|<phase>caller: message
# Mirrors PowerShell Show-LogContext: timestamp|LEVEL|script:line|<ScriptBlock><Process>: msg
# Terminal gets colored output; log file gets plain text (append only).

# shellcheck disable=SC2059
_log_msg() {
  local level="$1" color="$2" is_err="$3"
  shift 3
  local _ts _src _ctx _line
  _ts="$(date +'%Y-%m-%d %H:%M:%S')"
  _src="${BASH_SOURCE[2]##*/}:${BASH_LINENO[1]}"
  _ctx="<${_ir_phase:-main}>${FUNCNAME[2]:-main}"
  printf -v _line "\e[32m%s\e[0m|\e[%sm%s\e[0m|\e[90m%s\e[0m|\e[90m%s\e[0m: %s" \
    "$_ts" "$color" "$level" "$_src" "$_ctx" "$*"
  if [[ "$is_err" == "1" ]]; then
    printf '%s\n' "$_line" >&2
  else
    printf '%s\n' "$_line"
  fi
  if [[ -n "${_SETUP_LOG_FILE:-}" ]]; then
    printf '%s|%s|%s|%s: %s\n' "$_ts" "$level" "$_src" "$_ctx" "$*" >>"$_SETUP_LOG_FILE"
  fi
}

info() { _log_msg "INFO" "94" "0" "$@"; }
ok() { _log_msg "OK" "32" "0" "$@"; }
warn() { _log_msg "WARNING" "93" "1" "$@"; }
err() { _log_msg "ERROR" "91" "1" "$@"; }

# -- Thin shims for external commands ------------------------------------------
# Phases call these instead of the raw commands. Tests redefine them to assert
# the right commands are issued without executing them.
#
# nix gets a github.com token so flake fetches avoid the unauthenticated API
# rate limit (60 req/h). Sources: GITHUB_TOKEN (CI/headless), `gh auth token`,
# then the plaintext token in gh's hosts.yml - on a first run the config (e.g.
# synced by wsl_setup.ps1) exists before nix has installed gh itself. Both gh
# sources are scoped to github.com so a GHE token is never sent to github.com.
# The token goes in NIX_CONFIG, not --extra-access-tokens: argv is
# world-readable (ps, /proc/<pid>/cmdline). `extra-access-tokens` appends, so
# an inherited NIX_CONFIG is kept; the prefix assignment scopes it to one call.
_io_nix() {
  if [[ -z "${_io_gh_token:-}" ]]; then
    _io_gh_token="${GITHUB_TOKEN:-}"
    if [[ -z "$_io_gh_token" ]] && command -v gh >/dev/null 2>&1; then
      _io_gh_token="$(gh auth token -h github.com 2>/dev/null)" || _io_gh_token=""
    fi
    if [[ -z "$_io_gh_token" && -f "$HOME/.config/gh/hosts.yml" ]]; then
      _io_gh_token="$(sed -n '/^github\.com:/,/^[^ ]/s/^ *oauth_token: *//p' "$HOME/.config/gh/hosts.yml" | head -n 1)"
    fi
  fi
  if [[ -n "$_io_gh_token" ]]; then
    local _nl=$'\n'
    NIX_CONFIG="${NIX_CONFIG:+$NIX_CONFIG$_nl}extra-access-tokens = github.com=$_io_gh_token" nix "$@"
  else
    nix "$@"
  fi
}
_io_nix_eval() { nix eval --impure --raw --expr "$1"; }
# No --proto/--tlsv1.2: $1 is $NIX_ENV_TLS_PROBE_URL, which the user may point at
# an http:// endpoint (nx_doctor.sh strips an http:// prefix from it), and a
# rejected protocol or TLS floor would be reported as a MITM cert failure.
_io_curl_probe() { curl -sS "$1" >/dev/null 2>&1; } # tls-probe-ok: probe URL is user-supplied and may be http://
# Insecure variant: bypasses cert validation (-k). Used by the MITM probe to
# distinguish "TLS cert rejected" (cert problem - run cert_intercept) from
# "endpoint unreachable" (network/DNS/captive portal - skip cert_intercept,
# don't pollute ca-custom.crt with unrelated bytes).
_io_curl_probe_insecure() { curl -ksS "$1" >/dev/null 2>&1; } # tls-probe-ok: -k is load-bearing here
# Pinned variant: probes TLS using `openssl s_client -CAfile <bundle>` so the
# only trust source is the explicit Mozilla bundle. The implementation lives
# in .assets/lib/cert_probe.sh (single source of truth - also called by
# _check_cert_bundle in nx_doctor.sh). $1 = url, $2 = Mozilla bundle path
# (e.g. ~/.nix-profile/etc/ssl/certs/ca-bundle.crt).
#
# cert_probe.sh is sourced lazily on first call rather than at file top so
# io.sh stays self-contained for tests that just need the structured-log
# helpers (info / ok / warn / err) without dragging in cert_probe.sh.
_io_curl_probe_pinned() {
  if ! type _cert_probe_pinned >/dev/null 2>&1; then
    # SCRIPT_ROOT is set by nix/setup.sh; in tests, BASH_SOURCE-relative
    # path covers the case where io.sh is sourced directly.
    local _cp_path
    if [ -n "${SCRIPT_ROOT:-}" ] && [ -f "$SCRIPT_ROOT/.assets/lib/cert_probe.sh" ]; then
      _cp_path="$SCRIPT_ROOT/.assets/lib/cert_probe.sh"
    else
      _cp_path="$(cd "$(dirname "${BASH_SOURCE[0]}")/../../.assets/lib" 2>/dev/null && pwd)/cert_probe.sh"
    fi
    # shellcheck source=../../.assets/lib/cert_probe.sh
    [ -f "$_cp_path" ] && . "$_cp_path"
  fi
  _cert_probe_pinned "$1" "$2"
}

# Install nix via the Determinate Systems installer. Wraps the full
# curl|sh pipeline so tests can override the entire invocation.
_io_install_nix() {
  _io_run curl --proto '=https' --tlsv1.2 -sSf -L https://install.determinate.systems/nix |
    sh -s -- "$@"
}

# _io_pwsh_nop lives in .assets/lib/helpers.sh -- shared with setup_common.sh,
# which runs out-of-process from nix/setup.sh and so cannot see io.sh's symbols.
# helpers.sh is sourced right after io.sh in nix/setup.sh, so the function is
# available by the time any phase invokes pwsh.

# Marker prefix written by _io_step (in helpers.sh). _io_run recognizes it
# in captured stderr and surfaces the LAST one on failure as "failed at step".
# Kept as a sentinel constant rather than referencing helpers.sh's _IO_STEP_PREFIX
# so io.sh has no source dependency on helpers.sh.
_IO_RUN_STEP_PREFIX="__IO_STEP__::"

# Run a command with try/catch semantics: stdout streams to terminal normally.
# stderr is captured; on failure it is shown on the terminal and logged. If
# the captured stderr contains _io_step markers, the last one is surfaced
# as "failed at step: <label>" before the cleaned error output (markers
# stripped). Markers are silently discarded on success.
_io_run() {
  local _err_file _rc=0
  _err_file="$(mktemp)"
  "$@" 2>"$_err_file" || _rc=$?
  if [[ $_rc -ne 0 && -s "$_err_file" ]]; then
    local _last_step _stripped_err
    _last_step="$(grep "^$_IO_RUN_STEP_PREFIX" "$_err_file" 2>/dev/null | tail -1)"
    _last_step="${_last_step#$_IO_RUN_STEP_PREFIX}"
    if [[ -n "$_last_step" ]]; then
      printf '\e[31;1mfailed at step: %s\e[0m\n' "$_last_step" >&2
    fi
    _stripped_err="$(grep -v "^$_IO_RUN_STEP_PREFIX" "$_err_file" 2>/dev/null || true)"
    [[ -n "$_stripped_err" ]] && printf '%s\n' "$_stripped_err" >&2
    if [[ -n "${_SETUP_LOG_FILE:-}" ]]; then
      local _ts
      _ts="$(date +'%Y-%m-%d %H:%M:%S')"
      printf '%s|ERROR|%s:%s|<%s>%s: failed at step "%s": %s\n' \
        "$_ts" "${BASH_SOURCE[1]##*/}" "${BASH_LINENO[0]}" \
        "${_ir_phase:-main}" "${FUNCNAME[1]:-main}" \
        "${_last_step:-<unlabeled>}" \
        "$(printf '%s' "$_stripped_err" | tr '\n' ' ')" >>"$_SETUP_LOG_FILE"
    fi
  fi
  rm -f "$_err_file"
  return $_rc
}
