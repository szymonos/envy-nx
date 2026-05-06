# Shared helpers for provision, setup, and lifecycle scripts.
#
# Functions:
#   download_file      -- download a file with retry logic
#   gh_login_user      -- log in to GitHub as the specified user using gh CLI
#   install_atomic     -- copy a file via temp-file + same-filesystem rename
#                         so concurrent readers never see a partial file
#   _io_pwsh_nop       -- invoke pwsh -nop with nix vs. system pwsh handling

# *Function to install a file atomically: write to temp + rename.
# Same-filesystem rename(2) is atomic on POSIX, so any process that
# happens to read the destination during the swap sees either the old
# file in full or the new file in full - never a half-written one.
# Mode bits are preserved from the source.
# Usage: install_atomic <src> <dst>
install_atomic() {
  local src="$1" dst="$2"
  if [ -z "$src" ] || [ -z "$dst" ]; then
    printf "\e[31mError: install_atomic requires <src> <dst>.\e[0m\n" >&2
    return 1
  fi
  if [ ! -f "$src" ]; then
    printf "\e[31mError: install_atomic source not found: %s\e[0m\n" "$src" >&2
    return 1
  fi
  local dst_dir
  dst_dir="$(dirname "$dst")"
  mkdir -p "$dst_dir"
  local tmp
  tmp="$(mktemp "${dst}.XXXXXX")" || return 1
  if ! cp -p "$src" "$tmp"; then
    rm -f "$tmp"
    return 1
  fi
  # Skip the rename when dst already has identical content. cp -p + mv -f
  # would otherwise stamp dst with the source's mtime even on a no-op
  # write -- and any mtime bump under ~/.config/nix-env/ advances the
  # path:flake's lastModified, which makes single-user `nix profile
  # upgrade nix-env` re-realize the buildEnv (new generation, ~175 MiB
  # churn through gc) on every setup run.
  if [ -f "$dst" ] && cmp -s "$tmp" "$dst"; then
    rm -f "$tmp"
    return 0
  fi
  mv -f "$tmp" "$dst"
}

# *Function to download file from specified uri
download_file() {
  local uri=''
  local target_dir=''
  # parse named parameters
  while [ $# -gt 0 ]; do
    case "$1" in
    --uri)
      uri="${2:-}"
      shift
      ;;
    --target_dir)
      target_dir="${2:-}"
      shift
      ;;
    esac
    shift
  done

  if [ -z "$uri" ]; then
    printf "\e[31mError: The \e[4muri\e[24m parameter is required.\e[0m\n" >&2
    return 1
  elif ! type curl &>/dev/null; then
    printf "\e[31mError: The \e[4mcurl\e[24m command is required.\e[0m\n" >&2
    return 1
  fi
  # set the target directory to the current directory if not specified
  [ -z "$target_dir" ] && target_dir='.' || true

  # define local variables
  local file_name="$(basename "$uri")"
  local max_retries=8
  local retry_count=0

  while [ $retry_count -le $max_retries ]; do
    # download file
    status_code=$(curl -w '%{http_code}' -#Lko "$target_dir/$file_name" "$uri" 2>/dev/null)

    # check the HTTP status code
    case $status_code in
    200)
      echo "Download successful. Ready to install." >&2
      return 0
      ;;
    404)
      printf "\e[33mRequested file not found at the specified URL or is inaccessible:\n\e[0;4m${uri}\e[0m\n" >&2
      return 1
      ;;
    *)
      ((retry_count++)) || true
      echo "retrying... $retry_count/$max_retries" >&2
      ;;
    esac
  done

  echo "Failed to download file after $max_retries attempts." >&2
  return 1
}

# *Function to log in to GitHub as the specified user using the gh CLI
# Usage: gh_login_user              # logs in the current user
# Usage: gh_login_user -u $user     # logs in the specified user
# Usage: gh_login_user -u $user -k  # logs in the specified user admin:public_key scope
gh_login_user() {
  # check if the gh CLI is installed
  if ! [ -x /usr/bin/gh ]; then
    printf "\e[31mError: The \e[1mgh\e[22m command is required but not installed.\e[0m\n" >&2
    return 1
  fi

  # initialize local variable to the current user
  local user="$(id -un)"
  local token=""
  local retries=0
  local key=false
  # parse named parameters
  OPTIND=1
  while getopts ":u:k" opt; do
    case $opt in
    u)
      user="$OPTARG"
      ;;
    k)
      key=true
      ;;
    \?)
      echo "Invalid option: -$OPTARG" >&2
      exit 1
      ;;
    :)
      echo "Option -$OPTARG requires an argument." >&2
      exit 1
      ;;
    esac
  done
  shift $((OPTIND - 1))

  # check if the user exists
  if ! id -u "$user" &>/dev/null; then
    printf "\e[31mError: The user \e[1m$user\e[22m does not exist.\e[0m\n" >&2
    return 1
  fi

  # *check gh authentication status
  auth_status="$(sudo -u "$user" gh auth status 2>/dev/null)"
  # extract gh username
  gh_user="$(echo "$auth_status" | sed -rn '/Logged in to/ s/.*account ([[:alnum:]._.-]+).*/\1/p')"
  gh_user=${gh_user:-$user}

  if echo "$auth_status" | grep -Fwq '✓'; then
    if [ "$key" = true ]; then
      if echo "$auth_status" | grep -Fwq 'admin:public_key'; then
        printf "\e[32mUser \e[1m$gh_user\e[22m is already authenticated to GitHub.\e[0m\n" >&2
      else
        while [[ $retries -lt 5 ]] && [ -z "$token" ]; do
          sudo -u "$user" gh auth refresh -s admin:public_key >&2
          token="$(sudo -u "$user" gh auth token 2>/dev/null)"
          ((retries++)) || true
        done
      fi
    else
      printf "\e[32mUser \e[1m$gh_user\e[22m is already authenticated to GitHub.\e[0m\n" >&2
    fi
  else
    # try to authenticate the user
    while [[ $retries -lt 3 ]] && [ -z "$token" ]; do
      if [ "$key" = true ]; then
        sudo -u "$user" gh auth login -s admin:public_key >&2
      else
        sudo -u "$user" gh auth login >&2
      fi
      token="$(sudo -u "$user" gh auth token 2>/dev/null)"
      ((retries++)) || true
    done

    if [ -n "$token" ]; then
      auth_status="$(sudo -u "$user" gh auth status)"
    else
      printf "\e[33mFailed to authenticate to GitHub.\e[0m\n" >&2
      echo 'none'
      return 1
    fi
  fi

  # *check gh authentication method
  if echo "$auth_status" | grep -Fwq 'keyring'; then
    echo 'keyring'
  elif echo "$auth_status" | grep -Fwq '.config/gh/hosts.yml'; then
    gh_cfg=$(echo "$auth_status" | sed -n '/Logged in to/ s/.*(\([^)]*\)).*/\1/p')
    cat "$gh_cfg"
  else
    echo 'unknown'
  fi

  return 0
}

# Run a command with a wall-clock timeout, falling back to direct invocation
# when no timeout binary is available. `timeout(1)` ships with GNU coreutils
# (Linux distros, WSL) but is NOT in stock macOS userland; brewed coreutils
# installs it as `gtimeout`. Defensive callers should use this helper so the
# timeout is best-effort - "bound the wait if the OS gives us a way to" -
# rather than a hard requirement that breaks on macOS.
#
# Usage:
#   _with_timeout 5 gh api repos/foo/bar/releases/latest
#
# Returns the wrapped command's exit code, or 124 when the timeout fires
# (matching `timeout(1)`'s convention). When neither timeout binary is
# present, the wrapped command runs unbounded - acceptable for the
# best-effort case; callers that need a hard upper bound must implement
# it themselves.
function _with_timeout() {
  local _wt_seconds="$1"
  shift
  if command -v timeout >/dev/null 2>&1; then
    timeout "$_wt_seconds" "$@"
  elif command -v gtimeout >/dev/null 2>&1; then
    gtimeout "$_wt_seconds" "$@"
  else
    "$@"
  fi
}

# Mark a step within a configure script for structured failure reporting.
# Writes a marker to stderr that _io_run (in nix/lib/io.sh) recognizes and
# surfaces in the failure output - so when configure/conda.sh dies, the user
# sees "failed at step: install miniforge" instead of just conda's raw error
# stream. Markers are silent on success (captured stderr is discarded by
# _io_run when the command succeeds) and stripped from the user-visible
# error output on failure (they're just routing metadata, not user info).
#
# Usage (inside any configure script):
#   _io_step "downloading miniforge installer"
#   curl -fsSL ... | bash
_IO_STEP_PREFIX="__IO_STEP__::"
_io_step() {
  printf '%s%s\n' "$_IO_STEP_PREFIX" "$*" >&2
}

# Invoke pwsh -nop, handling nix-built and system pwsh differences.
#
# Nix-built pwsh's .NET runtime re-injects /nix/store library paths into
# LD_LIBRARY_PATH at startup, which then leaks into child processes (nix
# commands, glibc-mismatched). We must clear it inside the pwsh session
# AND invoke the nix wrapper at ~/.nix-profile/bin/pwsh -- NOT the
# unwrapped share/powershell/pwsh, which lacks libicu/openssl indirection
# and aborts on startup. System-packaged pwsh has neither issue, so the
# LD_LIBRARY_PATH dance is unnecessary.
#
# Resolution order:
#   1. ~/.nix-profile/bin/pwsh exists -> use it, LD_LIBRARY_PATH cleared.
#   2. Otherwise `command -v pwsh` (system install) -> use as-is.
#   3. Neither -> return 1 with a clear error message.
#
# Usage: _io_pwsh_nop script.ps1 [-Param ...]
#        _io_pwsh_nop -c '<inline command>'
_io_pwsh_nop() {
  local _pwsh _prefix=""
  if [[ -x "$HOME/.nix-profile/bin/pwsh" ]]; then
    _pwsh="$HOME/.nix-profile/bin/pwsh"
    _prefix='$env:LD_LIBRARY_PATH = $null; '
  else
    _pwsh="$(command -v pwsh 2>/dev/null)"
    if [[ -z "$_pwsh" ]]; then
      printf "\e[31mError: pwsh not found (no ~/.nix-profile/bin/pwsh and not on PATH).\e[0m\n" >&2
      return 1
    fi
  fi
  if [[ "${1:-}" == "-c" ]]; then
    shift
    "$_pwsh" -nop -c "${_prefix}$1"
  else
    local _cmd
    printf -v _cmd '%s& "%s"' "$_prefix" "$1"
    shift
    [[ $# -gt 0 ]] && _cmd+=" $*"
    "$_pwsh" -nop -c "$_cmd"
  fi
}
