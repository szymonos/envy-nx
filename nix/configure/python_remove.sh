#!/usr/bin/env bash
# Cleanup hook fired when `nix/setup.sh --remove python` drops the python scope.
# Removes the user-global state uv writes outside the nix profile:
#   - $UV_CACHE_DIR        (default ~/.cache/uv) - wheel cache, hashes, downloads
#   - $UV_TOOL_DIR         (default ~/.local/share/uv/tools) - uvx-installed CLIs
#   - $UV_PYTHON_INSTALL_DIR (default ~/.local/share/uv/python) - managed Pythons
# Project-local virtualenvs (~/<project>/.venv/) are user code and are NOT touched.
# uv shell init (UV_SYSTEM_CERTS export + completions in the # :uv block) is
# gated on the binary existing, so it self-strips on the next
# `nx profile regenerate` once nix removes uv from ~/.nix-profile/bin.
# Prompts by default; skips the prompt under --unattended.
: '
nix/configure/python_remove.sh
nix/configure/python_remove.sh true   # unattended
'
set -eo pipefail

unattended="${1:-false}"
UV_CACHE="${UV_CACHE_DIR:-$HOME/.cache/uv}"
UV_TOOLS="${UV_TOOL_DIR:-$HOME/.local/share/uv/tools}"
UV_PYTHONS="${UV_PYTHON_INSTALL_DIR:-$HOME/.local/share/uv/python}"

info() { printf "\e[96m%s\e[0m\n" "$*"; }
ok() { printf "\e[32m%s\e[0m\n" "$*"; }
warn() { printf "\e[33m%s\e[0m\n" "$*" >&2; }

# Build the list of dirs that actually exist - if none do, exit clean (no-op
# for users who never ran uv after installing the python scope).
present_dirs=()
[ -d "$UV_CACHE" ] && present_dirs+=("$UV_CACHE")
[ -d "$UV_TOOLS" ] && present_dirs+=("$UV_TOOLS")
[ -d "$UV_PYTHONS" ] && present_dirs+=("$UV_PYTHONS")
[ "${#present_dirs[@]}" -eq 0 ] && exit 0

# Enumerate user-visible state so the user sees what they'd lose.
pythons=()
if [ -d "$UV_PYTHONS" ]; then
  for d in "$UV_PYTHONS"/*; do
    [ -d "$d" ] || continue
    pythons+=("$(basename "$d")")
  done
fi
tools=()
if [ -d "$UV_TOOLS" ]; then
  for d in "$UV_TOOLS"/*; do
    [ -d "$d" ] || continue
    tools+=("$(basename "$d")")
  done
fi

info "uv-managed state found:"
for d in "${present_dirs[@]}"; do
  info "  $d"
done
if [ "${#pythons[@]}" -gt 0 ]; then
  warn "  ${#pythons[@]} managed Python version(s) will be permanently lost: ${pythons[*]}"
fi
if [ "${#tools[@]}" -gt 0 ]; then
  warn "  ${#tools[@]} uv-installed tool(s) will be permanently lost: ${tools[*]}"
  warn "  Their symlinks under ~/.local/bin/ will become dangling."
fi

if [ "$unattended" != "true" ]; then
  # `[ -t 0 ]` short-circuits when stdin isn't a terminal (CI, prek hooks,
  # cron, `bash $0 </dev/null`, etc.). Without this guard the read below
  # would block forever in those contexts: `</dev/tty` opens the SESSION's
  # controlling terminal, ignoring stdin redirects, so a "headless"
  # invocation with `</dev/null` doesn't actually prevent the prompt.
  # See ARCHITECTURE.md §7.9.
  if [ ! -t 0 ]; then
    info "Non-interactive shell. Skipped: uv state retained. Remove manually with: rm -rf ${present_dirs[*]}"
    exit 0
  fi
  printf "Remove uv cache, tools, and managed Pythons listed above? [y/N] "
  reply=""
  read -r reply </dev/tty || reply="" # tty-ok
  case "$reply" in
  [yY]*) ;;
  *)
    info "Skipped: uv state retained. Remove manually with: rm -rf ${present_dirs[*]}"
    exit 0
    ;;
  esac
fi

for d in "${present_dirs[@]}"; do
  rm -rf "$d"
  ok "removed $d"
done
if [ "${#tools[@]}" -gt 0 ]; then
  info "Reminder: uv tool symlinks under ~/.local/bin/ may now be broken."
  info "  Reinstall with: uv tool install <name>"
fi
