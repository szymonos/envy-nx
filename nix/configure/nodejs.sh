#!/usr/bin/env bash
# Post-install Node.js bootstrap (nix path).
# nix installs fnm; this hook installs the LTS runtime and pins it as default
# so `node` / `npm` work in a fresh shell after `nix/setup.sh --nodejs`.
# Idempotent: skips the LTS download when an `lts-latest` install already exists.
#
# Arg 1: unattended ("true"/"false", default "false") - when "true", skips the
# stale-prefix removal prompt and clears it directly. Forwarded by
# phase_configure_per_scope from the parent --unattended flag.
: '
nix/configure/nodejs.sh
nix/configure/nodejs.sh true   # unattended
'
set -eo pipefail

unattended="${1:-false}"
SCRIPT_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
. "$SCRIPT_ROOT/.assets/lib/helpers.sh"

info() { printf "\e[96m%s\e[0m\n" "$*"; }
ok() { printf "\e[32m%s\e[0m\n" "$*"; }
warn() { printf "\e[33m%s\e[0m\n" "$*" >&2; }

# fnm itself is provided by the nodejs scope in nix; if it isn't on PATH or in
# ~/.nix-profile/bin, the scope didn't install (e.g. nix profile add failed) -
# warn and exit clean so the rest of the configure phase isn't aborted.
if ! command -v fnm >/dev/null 2>&1; then
  if [ -x "$HOME/.nix-profile/bin/fnm" ]; then
    export PATH="$HOME/.nix-profile/bin:$PATH"
  else
    warn "fnm not found - skipping Node.js bootstrap (re-run nix/setup.sh after the nodejs scope installs)"
    exit 0
  fi
fi

# Bootstrap LTS only if not already installed. `fnm install --lts` would itself
# be idempotent, but always re-running it forces a network round-trip on every
# `nx upgrade` even when nothing has changed - so we gate on `fnm list`.
if ! fnm list 2>/dev/null | grep -q 'lts-latest'; then
  _io_step "installing Node.js LTS via fnm"
  info "installing Node.js LTS (first run)..."
  fnm install --lts
fi

# Always set lts-latest as default - cheap, makes the default symlink
# self-heal if a user manually pointed it elsewhere or removed it.
_io_step "setting default Node.js to lts-latest"
fnm default lts-latest

# `fnm install`/`fnm default` don't put npm on PATH for the calling shell.
# Source `fnm env` so the npm CLI is available for the config checks below
# (stale-prefix detection + cafile pinning).
eval "$(fnm env)" 2>/dev/null || true
if command -v npm >/dev/null 2>&1; then
  # Detect a stale `prefix` setting from a previous system-node setup. A common
  # workaround for `npm install -g` EACCES on system-node was `npm config set
  # prefix ~/.npm-global` (or similar). That setting persists in ~/.npmrc and
  # breaks fnm's PATH model: fnm only adds ~/.local/share/fnm/node-versions/<v>
  # /installation/bin to PATH (via the multishells symlink), so a prefix
  # pointing elsewhere lands globals where bash never looks - the user sees
  # `npm install -g <pkg>` succeed but `<pkg>` is not on PATH.
  _existing_prefix="$(npm config get prefix 2>/dev/null || true)"
  case "$_existing_prefix" in
  *.local/share/fnm/* | "" | "null" | "undefined")
    : # fnm-default or unset - nothing to do
    ;;
  *)
    warn "npm prefix is '$_existing_prefix' - looks like a leftover from a previous setup"
    warn "  Globals installed via 'npm install -g <pkg>' would land outside fnm's PATH."
    # Decision: clear it (so fnm's per-version default takes over) or keep it.
    # Unattended -> clear directly. Interactive -> prompt [y/N], default no.
    # Non-tty stdin (CI / headless invocation that didn't pass --unattended) ->
    # skip the prompt and retain, mirroring the conda_remove.sh pattern.
    _clear_prefix=false
    if [ "$unattended" = "true" ]; then
      _clear_prefix=true
    elif [ ! -t 0 ]; then
      info "  Non-interactive shell. Retained: run 'npm config delete prefix' to clear."
    else
      printf "Remove the stale npm prefix and let fnm own globals? [y/N] "
      reply=""
      read -r reply </dev/tty || reply="" # tty-ok
      case "$reply" in
      [yY]*) _clear_prefix=true ;;
      *) info "  Retained: run 'npm config delete prefix' to clear later." ;;
      esac
    fi
    if [ "$_clear_prefix" = "true" ]; then
      _io_step "removing stale npm prefix"
      npm config delete prefix
      ok "removed stale npm prefix (was: $_existing_prefix)"
    fi
    ;;
  esac

  # Belt-and-suspenders: pin npm's cafile in ~/.npmrc so npm trusts the corp/MITM
  # bundle even in shells that don't source ~/.bashrc (CI runners, IDE-spawned
  # subshells, headless `bash -c` invocations). The `# :certs` block in
  # _nx_render_env_block already exports NODE_EXTRA_CA_CERTS for env-aware shells;
  # this complements that by writing into ~/.npmrc (user-level, shared across all
  # fnm node-versions, survives `fnm install` bumps). NODE_EXTRA_CA_CERTS is
  # additive (Mozilla CAs + ca-custom.crt); cafile is replacement, so it has to
  # point at the *complete* bundle (ca-bundle.crt = system CAs + custom).
  # Guarded so a user who explicitly set their own cafile isn't overwritten.
  _ca_bundle="$HOME/.config/certs/ca-bundle.crt"
  if [ -f "$_ca_bundle" ]; then
    _existing_cafile="$(npm config get cafile 2>/dev/null || echo null)"
    if [ "$_existing_cafile" = "null" ] || [ -z "$_existing_cafile" ]; then
      _io_step "pinning npm cafile to $_ca_bundle"
      # Wrap with _io_run so a real failure (read-only ~/.npmrc, npm crash,
      # etc.) is captured in setup.log and surfaced to the user. Same pattern
      # as nix/lib/phases/nix_profile.sh:75. The `|| warn` keeps the script
      # going on a non-fatal failure - npm cafile is the belt-and-suspenders
      # complement to NODE_EXTRA_CA_CERTS, not a hard blocker for nodejs.
      _io_run npm config set cafile "$_ca_bundle" ||
        warn "npm cafile pin failed - corp HTTPS may break in non-env-aware shells"
    fi
  fi
fi

# Report the resolved version. `fnm current` is best-effort because it requires
# the env-var setup the shell init writes - we may be running before that.
_current="$(fnm current 2>/dev/null || echo unknown)"
ok "fnm configured (default: $_current)"
