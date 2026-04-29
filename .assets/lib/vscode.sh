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
  printf '%s\n' "$settings" |
    jq --arg path "$pwsh_bin" '.["powershell.powerShellAdditionalExePaths"].nix = $path' \
      >"$settings_file.tmp"
  mv -f "$settings_file.tmp" "$settings_file"
  ok "  added pwsh path to VS Code Machine settings"
}
