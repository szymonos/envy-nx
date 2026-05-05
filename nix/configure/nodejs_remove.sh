#!/usr/bin/env bash
# Cleanup hook fired when `nix/setup.sh --remove nodejs` drops the nodejs scope.
# Removes ~/.local/share/fnm (where fnm stores node-versions and aliases).
# Prompts by default; skips the prompt under --unattended.
# fnm shell init (the `# :fnm` block in ~/.bashrc / ~/.zshrc / pwsh profile)
# is gated on the binary existing, so it self-strips on the next
# `nx profile regenerate` once nix removes fnm from ~/.nix-profile/bin.
: '
nix/configure/nodejs_remove.sh
nix/configure/nodejs_remove.sh true   # unattended
'
set -eo pipefail

unattended="${1:-false}"
FNM_DIR="$HOME/.local/share/fnm"

info() { printf "\e[96m%s\e[0m\n" "$*"; }
ok() { printf "\e[32m%s\e[0m\n" "$*"; }
warn() { printf "\e[33m%s\e[0m\n" "$*" >&2; }

# nothing to clean up
[ -d "$FNM_DIR" ] || exit 0

# enumerate installed node versions (so the user sees what they'd lose)
versions=()
if [ -d "$FNM_DIR/node-versions" ]; then
  for d in "$FNM_DIR/node-versions"/*; do
    [ -d "$d" ] || continue
    versions+=("$(basename "$d")")
  done
fi

info "fnm installation found at $FNM_DIR"
if [ "${#versions[@]}" -gt 0 ]; then
  warn "  ${#versions[@]} Node.js version(s) and any globally installed npm packages will be permanently lost: ${versions[*]}"
fi

if [ "$unattended" != "true" ]; then
  # `[ -t 0 ]` short-circuits when stdin isn't a terminal (CI, prek hooks,
  # cron, `bash $0 </dev/null`, etc.). Without this guard the read below
  # would block forever in those contexts: `</dev/tty` opens the SESSION's
  # controlling terminal, ignoring stdin redirects, so a "headless"
  # invocation with `</dev/null` doesn't actually prevent the prompt.
  # See ARCHITECTURE.md §7.9.
  if [ ! -t 0 ]; then
    info "Non-interactive shell. Skipped: $FNM_DIR retained. Remove manually with: rm -rf $FNM_DIR"
    exit 0
  fi
  printf "Remove %s and all installed Node.js versions? [y/N] " "$FNM_DIR"
  reply=""
  read -r reply </dev/tty || reply="" # tty-ok
  case "$reply" in
  [yY]*) ;;
  *)
    info "Skipped: $FNM_DIR retained. Remove manually with: rm -rf $FNM_DIR"
    exit 0
    ;;
  esac
fi

rm -rf "$FNM_DIR"
ok "removed $FNM_DIR"
