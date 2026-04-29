#!/usr/bin/env bash
# Cleanup hook fired when `nix/setup.sh --remove conda` drops the conda scope.
# Removes ~/miniforge3 (the install miniforge.sh wrote) and the conda init block
# from shell rc files. Prompts by default; skips the prompt under --unattended.
: '
nix/configure/conda_remove.sh
nix/configure/conda_remove.sh true   # unattended
'
set -eo pipefail

unattended="${1:-false}"
CONDA_DIR="$HOME/miniforge3"

info() { printf "\e[96m%s\e[0m\n" "$*"; }
ok() { printf "\e[32m%s\e[0m\n" "$*"; }
warn() { printf "\e[33m%s\e[0m\n" "$*" >&2; }

# nothing to clean up
[ -d "$CONDA_DIR" ] || exit 0

# enumerate user-created conda environments (so the user sees what they'd lose)
envs=()
if [ -d "$CONDA_DIR/envs" ]; then
  for d in "$CONDA_DIR/envs"/*; do
    [ -d "$d" ] || continue
    envs+=("$(basename "$d")")
  done
fi

info "Conda installation found at $CONDA_DIR"
if [ "${#envs[@]}" -gt 0 ]; then
  warn "  ${#envs[@]} user environment(s) will be permanently lost: ${envs[*]}"
fi

if [ "$unattended" != "true" ]; then
  printf "Remove %s and all conda environments? [y/N] " "$CONDA_DIR"
  reply=""
  read -r reply </dev/tty || reply=""
  case "$reply" in
  [yY]*) ;;
  *)
    info "Skipped: $CONDA_DIR retained. Remove manually with: rm -rf $CONDA_DIR"
    exit 0
    ;;
  esac
fi

# undo `conda init bash zsh` (writes the managed block out of ~/.bashrc / ~/.zshrc)
# guarded with || true since a partially broken install may still report failure
if [ -x "$CONDA_DIR/bin/conda" ]; then
  "$CONDA_DIR/bin/conda" init --reverse bash zsh 2>/dev/null || true
fi

rm -rf "$CONDA_DIR"
ok "removed $CONDA_DIR"
