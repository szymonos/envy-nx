#!/usr/bin/env bash
# Configure GitHub CLI authentication and SSH key (cross-platform)
: '
nix/configure/gh.sh
# skip all interactive steps (unattended mode)
nix/configure/gh.sh true
'
set -eo pipefail

unattended="${1:-false}"

info() { printf "\e[96m%s\e[0m\n" "$*"; }
ok() { printf "\e[32m%s\e[0m\n" "$*"; }
warn() { printf "\e[33m%s\e[0m\n" "$*" >&2; }

if ! command -v gh &>/dev/null; then
  warn "gh CLI not found - skipping GitHub authentication setup."
  exit 0
fi

# authenticate (request admin:public_key upfront for SSH key registration)
info "setting up GitHub authentication..."
authed="true"
if gh auth status -h github.com &>/dev/null; then
  ok "already authenticated to GitHub"
elif gh auth token -h github.com &>/dev/null; then
  ok "GitHub device already authorized"
elif [[ "$unattended" == "true" ]]; then
  # not pre-authenticated and non-interactive: skip the auth-dependent steps, but
  # still generate the local SSH key + known_hosts below (other flows depend on it)
  info "skipping GitHub authentication setup (unattended, not pre-authenticated)."
  authed="false"
else
  gh auth login --scopes admin:public_key
fi

# register gh as git credential helper (idempotent; needs auth)
if [[ "$authed" == "true" ]]; then
  gh auth setup-git
fi

# SSH key - generated locally regardless of registration; other flows assume it
# may exist (setup_ssh.sh, check_distro.sh, WSL Sync-WslSshKeys).
SSH_KEY="$HOME/.ssh/id_ed25519"
if [[ ! -f "$SSH_KEY" ]]; then
  info "generating SSH key..."
  mkdir -p "$HOME/.ssh"
  ssh-keygen -t ed25519 -f "$SSH_KEY" -N "" -q
fi

# empty when the .pub is missing; guards below keep `grep -F ""` from matching every key
pub_key_fp=$(awk '{print $2}' "$SSH_KEY.pub" 2>/dev/null || true)
if [[ "$authed" != "true" ]]; then
  info "SSH key generated; skipped GitHub registration (not authenticated)."
elif [[ "$unattended" == "true" ]]; then
  # pre-authenticated unattended run: report only, never register
  if [[ -n "$pub_key_fp" ]] && gh ssh-key list 2>/dev/null | grep -qF "$pub_key_fp"; then
    ok "SSH key already registered on GitHub"
  else
    info "SSH key not registered with GitHub (unattended)."
    info "  register manually: gh ssh-key add $SSH_KEY.pub"
    info "  SSO orgs must also authorize the key for SSO."
  fi
elif [[ -n "${GITHUB_TOKEN:-}" ]]; then
  # external token (CI, containers) - can't control its scopes
  info "skipping SSH key registration (using external GITHUB_TOKEN)."
elif [[ -z "$pub_key_fp" ]]; then
  warn "SSH key not registered: $SSH_KEY.pub is missing."
  warn "  fix: ssh-keygen -y -f $SSH_KEY >$SSH_KEY.pub && gh ssh-key add $SSH_KEY.pub"
else
  host_label="${USER}@$(uname -n)"
  if [[ -n "${NX_SSH_KEY_FP:-}" && "$NX_SSH_KEY_FP" == "$pub_key_fp" ]]; then
    ok "SSH key already registered on GitHub (matched by fingerprint)"
  elif ! gh ssh-key list 2>/dev/null | grep -qF "$pub_key_fp"; then
    info "adding SSH key to GitHub..."
    key_added="false"
    # gh exits 0 on a duplicate key, so a lookup that missed it (e.g. a failed
    # list call) must not be mistaken for a new key that still needs SSO authorization
    add_key() {
      local out
      out=$(gh ssh-key add "$SSH_KEY.pub" --title "$host_label $(date +%Y-%m-%d)" 2>&1) || {
        printf '%s\n' "$out" >&2
        return 1
      }
      if [[ "$out" == *"already exists"* ]]; then
        ok "SSH key already registered on GitHub"
      else
        printf '%s\n' "$out"
        key_added="true"
      fi
    }
    if ! add_key; then
      # existing token may lack admin:public_key scope. The refresh is an
      # interactive device-code flow, so it needs a tty.
      if [[ -t 0 ]]; then
        warn "SSH key add failed; upgrading token scope..."
        if gh auth refresh -h github.com -s admin:public_key; then
          add_key || warn "could not add SSH key after refresh"
        else
          warn "could not refresh admin:public_key scope"
        fi
      else
        warn "SSH key not registered: token lacks admin:public_key scope."
        warn "  fix: gh auth refresh -h github.com -s admin:public_key && gh ssh-key add $SSH_KEY.pub"
      fi
    fi
    # SSO orgs reject a new key until it is authorized, which only the web UI can do
    if [[ "$key_added" == "true" && -t 0 ]]; then
      ok "SSH key added to GitHub: $host_label"
      info "If your organization uses SSO, authorize the key at https://github.com/settings/keys"
      info "  (Configure SSO -> Authorize next to the new key)."
      read -rp "press Enter to continue " _ || true
    fi
  else
    ok "SSH key already registered on GitHub"
  fi
fi

# add github.com to known_hosts for SSH git operations (always)
if ! grep -qw 'github.com' "$HOME/.ssh/known_hosts" 2>/dev/null; then
  info "adding GitHub fingerprint to known_hosts..."
  ssh-keyscan github.com >>"$HOME/.ssh/known_hosts" 2>/dev/null
fi
