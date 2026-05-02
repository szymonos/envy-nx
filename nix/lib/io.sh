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
_io_nix() { nix "$@"; }
_io_nix_eval() { nix eval --impure --raw --expr "$1"; }
_io_curl_probe() { curl -sS "$1" >/dev/null 2>&1; }
# Insecure variant: bypasses cert validation (-k). Used by the MITM probe to
# distinguish "TLS cert rejected" (cert problem - run cert_intercept) from
# "endpoint unreachable" (network/DNS/captive portal - skip cert_intercept,
# don't pollute ca-custom.crt with unrelated bytes).
_io_curl_probe_insecure() { curl -ksS "$1" >/dev/null 2>&1; }

# Invoke pwsh -nop via the nix wrapper, clearing LD_LIBRARY_PATH inside pwsh.
# Must use the nix bin/pwsh wrapper (not share/powershell/pwsh) because the
# wrapper sets LD_LIBRARY_PATH for .NET dependencies (libicu, openssl, etc.).
# When run from a pwsh parent, PATH may resolve to the unwrapped inner binary
# which lacks these library paths and aborts at startup.
# The $env:LD_LIBRARY_PATH = $null inside pwsh prevents .NET from leaking
# nix store library paths into child processes.
# Usage: _io_pwsh_nop script.ps1 [-Param]  or  _io_pwsh_nop -c 'command'
_io_pwsh_nop() {
  local _pwsh="$HOME/.nix-profile/bin/pwsh"
  if [[ "${1:-}" == "-c" ]]; then
    shift
    "$_pwsh" -nop -c '$env:LD_LIBRARY_PATH = $null; '"$1"
  else
    local _cmd
    printf -v _cmd '$env:LD_LIBRARY_PATH = $null; & "%s"' "$1"
    shift
    [[ $# -gt 0 ]] && _cmd+=" $*"
    "$_pwsh" -nop -c "$_cmd"
  fi
}

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
