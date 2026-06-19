# VS Code Server environment setup (~/.vscode-server/server-env-setup).
# Compatible with bash 3.2 and zsh (sourced by nix and legacy setup paths).
#
# Usage:
#   source .assets/lib/vscode.sh
#   setup_vscode_certs       # writes NODE_EXTRA_CA_CERTS to server-env-setup
#   setup_vscode_server_env  # writes nix PATH entries to server-env-setup
#
# Requires: ok() helper defined by caller (printf green line).

# setup_vscode_certs
# Writes NODE_EXTRA_CA_CERTS to ~/.vscode-server/server-env-setup so that
# VS Code Server (remote-SSH, WSL) picks up custom CA certs without needing
# a login shell. Creates the directory and file if they don't exist yet.
# Idempotent: updates the value if already present, appends otherwise.
setup_vscode_certs() {
  local cert_dir="$HOME/.config/certs"
  local custom_certs="$cert_dir/ca-custom.crt"
  local env_file="$HOME/.vscode-server/server-env-setup"

  [ -f "$custom_certs" ] || return 0

  mkdir -p "$HOME/.vscode-server"

  local export_line="export NODE_EXTRA_CA_CERTS=\"$custom_certs\""
  if [ -f "$env_file" ] && grep -q 'NODE_EXTRA_CA_CERTS' "$env_file" 2>/dev/null; then
    if ! grep -qF "$export_line" "$env_file" 2>/dev/null; then
      local tmp
      tmp="$(mktemp)"
      grep -v 'NODE_EXTRA_CA_CERTS' "$env_file" >"$tmp"
      printf '%s\n' "$export_line" >>"$tmp"
      mv -f "$tmp" "$env_file"
      ok "  updated NODE_EXTRA_CA_CERTS in $env_file"
    fi
  else
    printf '%s\n' "$export_line" >>"$env_file"
    ok "  added NODE_EXTRA_CA_CERTS to $env_file"
  fi
}

# setup_vscode_macos_env
# Configures VS Code desktop on macOS for nix-installed tools:
# 1. Writes ~/.nix-profile/bin to /etc/paths.d/nix (best-effort via sudo -n) so
#    VS Code's shell-resolver picks up Nix tools without a login shell.
# 2. Registers nix-managed ripgrep path so the Todo-Tree extension finds
#    it (the extension does NOT search PATH).
# 3. Registers nix-managed pwsh under the `nix` key *only when no
#    existing entry already points at it* (preserves any user-chosen
#    key name like "pwsh (Nix)" and any custom default-version pick).
# Idempotent: skips parts that are already up to date.
#
# Profile targets: VS Code stores settings per profile, not just at the
# default `User/settings.json`. We write to (a) the default file and (b)
# the most-recently-modified profile under `User/profiles/<id>/`. There
# is no on-disk "currently active profile" - VS Code maps profile to
# window via `globalStorage/storage.json#profileAssociations.workspaces`,
# which the terminal can't observe in real time. The mtime heuristic
# approximates "the one I was just editing" without walking every
# profile (which would just create stale duplicate keys in profiles the
# user hasn't touched in months).
#
# Why awk + targeted line edits instead of jq: VS Code's settings.json
# is JSONC - it can contain `//` line comments and trailing commas that
# jq cannot parse. jq either silently fails (the bug we're fixing) or,
# in the absence of comments, strips them on rewrite (silently rewriting
# a user's annotated config). The awk-based path touches only the lines
# it needs to and preserves everything else.
#
# Why detect pwsh by VALUE rather than KEY: users often register the nix
# pwsh under their own label (`"pwsh (Nix)"`, `"nix-pwsh"`, etc.). Any
# entry whose value resolves to `$HOME/.nix-profile/bin/pwsh` means the
# user is already covered - inserting a second entry would just clutter
# the picker.
#
# Settings Sync caveat: these two keys are absolute paths, and neither
# extension supports `$HOME` / `${userHome}` expansion. Linux and macOS
# paths will fight via Settings Sync. The user is expected to add both
# keys to `settingsSync.ignoredSettings` once per profile - the script
# does not seed that itself (would itself be a synced setting, defeating
# the purpose).
setup_vscode_macos_env() {
  [ "$(uname -s)" = "Darwin" ] || return 0

  local nix_bin="$HOME/.nix-profile/bin"
  [ -d "$nix_bin" ] || return 0

  # -- /etc/paths.d/nix (PATH for all GUI apps, including VS Code) -------------
  local paths_d="/etc/paths.d/nix"
  if [ ! -f "$paths_d" ] || ! grep -qF "$nix_bin" "$paths_d" 2>/dev/null; then
    if command -v sudo >/dev/null 2>&1; then
      if printf '%s\n' "$nix_bin" | sudo -n tee "$paths_d" >/dev/null 2>&1; then
        ok "  wrote $nix_bin to $paths_d (PATH for GUI apps)"
      fi
    fi
  fi

  # -- User settings.json (pwsh + todo-tree ripgrep) ---------------------------
  local code_user_dir="$HOME/Library/Application Support/Code/User"
  [ -d "$code_user_dir" ] || return 0

  local pwsh_bin="$nix_bin/pwsh"
  local rg_bin="$nix_bin/rg"

  # If neither tool is installed, nothing to register.
  [ -x "$pwsh_bin" ] || [ -x "$rg_bin" ] || return 0

  # Collect target settings.json files: the default, plus the
  # most-recently-modified per-profile settings (if any profile exists).
  # `ls -t` is bash-3.2-safe and orders by mtime descending; we read
  # only the first entry to avoid carrying a list.
  local default_settings="$code_user_dir/settings.json"
  local profiles_dir="$code_user_dir/profiles"
  local recent_profile_settings=""
  if [ -d "$profiles_dir" ]; then
    local first_profile
    first_profile="$(ls -t "$profiles_dir" 2>/dev/null | head -n 1)"
    if [ -n "$first_profile" ] && [ -f "$profiles_dir/$first_profile/settings.json" ]; then
      recent_profile_settings="$profiles_dir/$first_profile/settings.json"
    fi
  fi

  local target
  for target in "$default_settings" "$recent_profile_settings"; do
    [ -n "$target" ] || continue
    # Bootstrap as multi-line so the line-based insert below always has
    # a `}` on its own line to anchor to. Skipping this would force the
    # writer to handle single-line `{}` as a special case. Also covers
    # fresh VS Code Profiles that init settings.json as literal `{}`.
    if [ ! -f "$target" ] || [ "$(tr -d '[:space:]' <"$target")" = "{}" ]; then
      printf '{\n}\n' >"$target"
    fi
    _vscode_macos_settings_update "$target" "$pwsh_bin" "$rg_bin"
  done
}

# Internal helper. Edits the given settings.json in place to register the
# nix pwsh (only when no existing entry points at it) and the nix rg path
# (only when the `todo-tree.ripgrep.ripgrep` key is absent). Insert-only -
# the writer never modifies values the user has already set. Bails out
# without touching the file when the structural shape isn't recognized.
#
# Strategy: assume the file is a JSONC object whose final `}` sits on its
# own line. That's how VS Code writes settings.json itself, how our
# bootstrap creates new files, and how every "Format Document" pass
# leaves things - if a user has hand-collapsed the root onto one line,
# we refuse to edit rather than guess. Given that assumption:
#   1. Find the line containing the lone `}` (the root close).
#   2. If the last non-blank line before it doesn't end in `,` or `{`,
#      append a `,` to it so our new keys are valid siblings. JSONC
#      tolerates trailing commas, so we don't have to remove the one we
#      add even if the file later loses our new keys.
#   3. Print the insert block immediately before the close line.
# No JSONC parser, no string-scanning depth tracker, no validation pass.
_vscode_macos_settings_update() {
  local settings_file="$1" pwsh_bin="$2" rg_bin="$3"

  local want_pwsh="" want_rg=""
  [ -x "$pwsh_bin" ] && want_pwsh="$pwsh_bin"
  [ -x "$rg_bin" ] && want_rg="$rg_bin"

  # pwsh: skip if ANY string value in the file matches the nix pwsh path
  # (user already has it registered under some label like "pwsh (Nix)").
  # rg: skip if the exact top-level key is already present (any value).
  local need_pwsh=0 need_rg=0
  [ -n "$want_pwsh" ] && ! grep -qF "\"$want_pwsh\"" "$settings_file" 2>/dev/null && need_pwsh=1
  [ -n "$want_rg" ] && ! grep -qE '^[[:space:]]*"todo-tree\.ripgrep\.ripgrep"[[:space:]]*:' "$settings_file" 2>/dev/null && need_rg=1
  [ "$need_pwsh" -eq 1 ] || [ "$need_rg" -eq 1 ] || return 0

  # Find the last line that is exactly `}` (with optional surrounding
  # whitespace). That's the root close - or we bail.
  local close_line
  close_line="$(awk '/^[[:space:]]*\}[[:space:]]*$/ { ln = NR } END { if (ln) print ln }' "$settings_file")"
  [ -n "$close_line" ] || return 0

  # Find the previous non-blank line. If it doesn't end in `,` or `{`,
  # we need to append a `,` so our insert is a valid sibling.
  local prev_ln need_comma=0
  prev_ln="$(awk -v close_ln="$close_line" 'NR < close_ln && NF { ln = NR } END { if (ln) print ln }' "$settings_file")"
  if [ -n "$prev_ln" ]; then
    local last_char
    last_char="$(sed -n "${prev_ln}p" "$settings_file" | sed -E 's/[[:space:]]+$//' | awk '{ print substr($0, length($0), 1) }')"
    case "$last_char" in
    ',' | '{') ;;
    *) need_comma=1 ;;
    esac
  fi

  # Build the insert block (2-space indent per VS Code convention; no
  # trailing comma on our last key - the close `}` follows directly).
  local insert=""
  if [ "$need_pwsh" -eq 1 ]; then
    insert="$insert  \"powershell.powerShellAdditionalExePaths\": {
    \"nix\": \"$want_pwsh\"
  },
  \"powershell.powerShellDefaultVersion\": \"nix\""
    if [ "$need_rg" -eq 1 ]; then
      insert="$insert,
"
    else
      insert="$insert
"
    fi
  fi
  if [ "$need_rg" -eq 1 ]; then
    insert="$insert  \"todo-tree.ripgrep.ripgrep\": \"$want_rg\"
"
  fi

  # One awk pass: optionally append `,` to prev line, then emit the
  # insert block immediately before the close line. Atomic via mktemp+mv.
  local tmp
  tmp="$(mktemp "$settings_file.XXXXXX")" || return 0
  awk -v close_ln="$close_line" -v prev_ln="$prev_ln" -v need_comma="$need_comma" -v insert="$insert" '
    NR == prev_ln && need_comma == "1" {
      sub(/[[:space:]]+$/, "")
      print $0 ","
      next
    }
    NR == close_ln { printf "%s", insert }
    { print }
  ' "$settings_file" >"$tmp" || {
    rm -f "$tmp"
    return 0
  }

  mv -f "$tmp" "$settings_file"
  # Label by parent dir basename so users running with multiple profiles
  # can tell which file got the new keys ("User" = default, profile-id
  # otherwise).
  local label
  label="$(basename "$(dirname "$settings_file")")"
  [ "$need_pwsh" -eq 1 ] && ok "  added pwsh path to VS Code settings ($label)"
  [ "$need_rg" -eq 1 ] && ok "  added todo-tree.ripgrep.ripgrep to VS Code settings ($label)"
  return 0
}

# setup_vscode_server_env
# Configures VS Code Server for nix-installed tools:
# 1. Adds nix PATH entries to server-env-setup so extensions resolve tools.
# 2. If pwsh is installed, registers it in Machine settings.json so the
#    PowerShell extension finds it without manual configuration.
# Idempotent: skips parts that are already up to date.
setup_vscode_server_env() {
  local nix_bin="$HOME/.nix-profile/bin"

  [ -d "$nix_bin" ] || return 0

  mkdir -p "$HOME/.vscode-server"

  # -- PATH in server-env-setup ------------------------------------------------
  local env_file="$HOME/.vscode-server/server-env-setup"
  local marker="nix-env:path"

  # shellcheck disable=SC2016
  local block
  block="$(printf '%s\n' \
    "# >>> $marker >>>" \
    'case ":$PATH:" in *":$HOME/.nix-profile/bin:"*) ;; *)' \
    '  [ -d "$HOME/.nix-profile/bin" ] && export PATH="$HOME/.nix-profile/bin:$PATH"' \
    'esac' \
    'case ":$PATH:" in *":$HOME/.local/bin:"*) ;; *)' \
    '  [ -d "$HOME/.local/bin" ] && export PATH="$HOME/.local/bin:$PATH"' \
    'esac' \
    "# <<< $marker <<<")"

  if [ -f "$env_file" ] && grep -qF "# >>> $marker >>>" "$env_file" 2>/dev/null; then
    local existing
    existing="$(sed -n "/# >>> $marker >>>/,/# <<< $marker <<</p" "$env_file")"
    if [ "$existing" != "$block" ]; then
      local tmp
      tmp="$(mktemp)"
      sed "/# >>> $marker >>>/,/# <<< $marker <<</d" "$env_file" >"$tmp"
      printf '%s\n' "$block" >>"$tmp"
      mv -f "$tmp" "$env_file"
      ok "  updated $marker in server-env-setup"
    fi
  else
    printf '\n%s\n' "$block" >>"$env_file"
    ok "  added $marker to server-env-setup"
  fi

  # -- pwsh in Machine settings.json ------------------------------------------
  local pwsh_bin="$nix_bin/pwsh"
  [ -x "$pwsh_bin" ] || return 0
  command -v jq >/dev/null 2>&1 || return 0

  local settings_dir="$HOME/.vscode-server/data/Machine"
  local settings_file="$settings_dir/settings.json"
  mkdir -p "$settings_dir"

  local current_path=""
  if [ -f "$settings_file" ]; then
    current_path="$(jq -r '.["powershell.powerShellAdditionalExePaths"]["nix"] // empty' "$settings_file" 2>/dev/null)" || true
  fi

  if [ "$current_path" = "$pwsh_bin" ]; then
    return 0
  fi

  local settings='{}'
  [ -f "$settings_file" ] && settings="$(cat "$settings_file")"
  if ! printf '%s\n' "$settings" |
    jq --arg path "$pwsh_bin" '.["powershell.powerShellAdditionalExePaths"].nix = $path' \
      >"$settings_file.tmp" 2>/dev/null; then
    rm -f "$settings_file.tmp"
    return 0
  fi
  mv -f "$settings_file.tmp" "$settings_file"
  ok "  added pwsh path to VS Code Machine settings"
}
