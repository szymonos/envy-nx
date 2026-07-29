#!/usr/bin/env bash
# Configure GitHub CLI authentication and SSH key (cross-platform)
: '
nix/configure/gh.sh
# skip all interactive steps (unattended mode)
nix/configure/gh.sh true
'
set -eo pipefail

unattended="${1:-false}"
# SSH-key registration with GitHub is opt-in: it needs the admin:public_key token
# scope, and a narrow pre-existing token otherwise triggers an interactive
# device-code refresh mid-install. Enable with `--register-ssh-key` or
# NX_REGISTER_SSH_KEY=1. SSO orgs must also authorize the key for SSO separately.
register_ssh_key="${NX_REGISTER_SSH_KEY:-false}"
case "$register_ssh_key" in
1 | true | yes) register_ssh_key="true" ;;
*) register_ssh_key="false" ;;
esac

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
elif [[ "$register_ssh_key" == "true" ]]; then
  # request admin:public_key upfront only when we will register an SSH key
  gh auth login --scopes admin:public_key
else
  gh auth login
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

if [[ "$authed" != "true" ]]; then
  info "SSH key generated; skipped GitHub registration (not authenticated)."
elif [[ "$register_ssh_key" != "true" ]]; then
  info "SSH key not registered with GitHub (opt in with --register-ssh-key)."
  info "  register manually: gh ssh-key add $SSH_KEY.pub"
  info "  SSO orgs must also authorize the key for SSO."
elif [[ -n "${GITHUB_TOKEN:-}" ]]; then
  # external token (CI, containers) - can't control its scopes
  info "skipping SSH key registration (using external GITHUB_TOKEN)."
else
  host_label="${USER}@$(uname -n)"
  pub_key_fp=$(awk '{print $2}' "$SSH_KEY.pub")
  if [[ -n "${NX_SSH_KEY_FP:-}" && "$NX_SSH_KEY_FP" == "$pub_key_fp" ]]; then
    ok "SSH key already registered on GitHub (matched by fingerprint)"
  elif ! gh ssh-key list 2>/dev/null | grep -q "$pub_key_fp"; then
    info "adding SSH key to GitHub..."
    if ! gh ssh-key add "$SSH_KEY.pub" --title "$host_label $(date +%Y-%m-%d)"; then
      # existing token may lack admin:public_key scope. The refresh is an
      # interactive device-code flow, so only attempt it interactively - never
      # under --unattended or without a tty (would hang CI / automated runs).
      if [[ "$unattended" != "true" && -t 0 ]]; then
        warn "SSH key add failed; upgrading token scope..."
        if gh auth refresh -h github.com -s admin:public_key; then
          gh ssh-key add "$SSH_KEY.pub" --title "$host_label $(date +%Y-%m-%d)" || warn "could not add SSH key after refresh"
        else
          warn "could not refresh admin:public_key scope"
        fi
      else
        warn "SSH key not registered: token lacks admin:public_key scope."
        warn "  fix: gh auth refresh -h github.com -s admin:public_key && gh ssh-key add $SSH_KEY.pub"
      fi
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
