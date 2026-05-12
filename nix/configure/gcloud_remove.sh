#!/usr/bin/env bash
# Cleanup hook fired when `nix/setup.sh --remove gcloud` drops the gcloud scope.
# Removes $HOME/google-cloud-sdk (where the official tarball install lives,
# including any user-installed components like gke-gcloud-auth-plugin).
# User config under ~/.config/gcloud/ (auth tokens, configurations) is NOT
# touched - that's user data, removed manually if desired.
# The :gcloud env block in shell rc files is gated on
# $HOME/google-cloud-sdk/bin existing, so it self-strips on the next
# `nx profile regenerate` once the install dir is gone.
# Prompts by default; skips the prompt under --unattended.
: '
nix/configure/gcloud_remove.sh
nix/configure/gcloud_remove.sh true   # unattended
'
set -eo pipefail

unattended="${1:-false}"
GCLOUD_HOME="$HOME/google-cloud-sdk"

info() { printf "\e[96m%s\e[0m\n" "$*"; }
ok() { printf "\e[32m%s\e[0m\n" "$*"; }
warn() { printf "\e[33m%s\e[0m\n" "$*" >&2; }

# nothing to clean up
[ -d "$GCLOUD_HOME" ] || exit 0

# enumerate user-installed components (best-effort: skip if gcloud is broken)
components=()
if [ -x "$GCLOUD_HOME/bin/gcloud" ]; then
  while IFS= read -r line; do
    [ -n "$line" ] && components+=("$line")
  done < <(CLOUDSDK_CORE_DISABLE_PROMPTS=1 "$GCLOUD_HOME/bin/gcloud" components list \
    --filter='state.name:Installed' --format='value(id)' 2>/dev/null || true)
fi

info "Google Cloud CLI installation found at $GCLOUD_HOME"
if [ "${#components[@]}" -gt 0 ]; then
  warn "  ${#components[@]} component(s) will be removed: ${components[*]}"
fi

if [ "$unattended" != "true" ]; then
  # `[ -t 0 ]` short-circuits when stdin isn't a terminal (CI, prek hooks,
  # cron, `bash $0 </dev/null`, etc.). Without this guard the read below
  # would block forever in those contexts: `</dev/tty` opens the SESSION's
  # controlling terminal, ignoring stdin redirects, so a "headless"
  # invocation with `</dev/null` doesn't actually prevent the prompt.
  # See ARCHITECTURE.md §7.9.
  if [ ! -t 0 ]; then
    info "Non-interactive shell. Skipped: $GCLOUD_HOME retained. Remove manually with: rm -rf $GCLOUD_HOME"
    exit 0
  fi
  printf "Remove %s and all installed components? [y/N] " "$GCLOUD_HOME"
  reply=""
  read -r reply </dev/tty || reply="" # tty-ok
  case "$reply" in
  [yY]*) ;;
  *)
    info "Skipped: $GCLOUD_HOME retained. Remove manually with: rm -rf $GCLOUD_HOME"
    exit 0
    ;;
  esac
fi

rm -rf "$GCLOUD_HOME"
ok "removed $GCLOUD_HOME"
info "Note: ~/.config/gcloud/ (auth tokens, configurations) was not touched."
