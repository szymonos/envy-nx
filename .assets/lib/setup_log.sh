# Setup log writer.
# Creates ~/.config/dev-env/setup.log for structured markers and error details.
# Terminal output is NOT redirected - subprocess output appears normally.
# Structured messages (info/warn/ok/err) append plain-text entries to the log.
# Compatible with bash 3.2+ (macOS).
#
# Usage:
#   source .assets/lib/setup_log.sh
#   setup_log_start    # create/rotate log file
#   setup_log_close    # stop appending to log

_SETUP_LOG_FILE=""

setup_log_start() {
  local log_dir="${DEV_ENV_DIR:-$HOME/.config/dev-env}"
  _SETUP_LOG_FILE="$log_dir/setup.log"
  mkdir -p "$log_dir"
  # rotate: keep one previous run
  [ -f "$_SETUP_LOG_FILE" ] && mv -f "$_SETUP_LOG_FILE" "${_SETUP_LOG_FILE}.1"
  : > "$_SETUP_LOG_FILE"
}

setup_log_close() {
  [ -n "$_SETUP_LOG_FILE" ] || return 0
  _SETUP_LOG_FILE=""
}
