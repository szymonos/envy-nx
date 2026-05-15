#!/usr/bin/env bash
# Post-install oh-my-posh theme configuration (cross-platform, Nix variant)
# The theme is always at a fixed path (~/.config/nix-env/omp/theme.omp.json).
: '
# reconfigure with the existing theme
nix/configure/omp.sh
# set a specific theme
nix/configure/omp.sh base
nix/configure/omp.sh nerd
'
# Shell rc files point to this path once; theme changes just replace the file.
set -eo pipefail

omp_theme="${1:-}"

info() { printf "\e[96m%s\e[0m\n" "$*"; }
ok() { printf "\e[32m%s\e[0m\n" "$*"; }
warn() { printf "\e[33m%s\e[0m\n" "$*" >&2; }

if ! command -v oh-my-posh &>/dev/null; then
  exit 0
fi

# macOS ships /bin/bash 3.2 (Apple's stance on GPLv3); oh-my-posh's bash init
# uses assoc-array syntax that 3.2 rejects, so the prompt would error on every
# bash session start. The renderer in .assets/lib/nx_profile.sh gates the eval
# on BASH_VERSINFO[0] >= 4, so bash sessions stay clean. Surface this once at
# install time so the user knows why their bash prompt looks plain. Probe
# /bin/bash directly (not $BASH_VERSINFO of this script) because by the time
# omp.sh runs, $PATH may already point at a nix-installed bash 5.x.
if [[ "$(uname -s)" == "Darwin" ]] && [[ -x /bin/bash ]]; then
  sys_bash_major="$(/bin/bash -c 'echo ${BASH_VERSINFO[0]}' 2>/dev/null || echo 0)"
  if [[ "$sys_bash_major" -lt 4 ]]; then
    warn "macOS /bin/bash is ${sys_bash_major}.x - oh-my-posh skipped in bash sessions."
    warn "  zsh and pwsh prompts work normally. To enable the prompt in bash too,"
    warn "  install a newer bash (e.g. 'brew install bash' or 'nix profile install nixpkgs#bash')"
    warn "  and start a fresh bash session."
  fi
fi

SCRIPT_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"

# -- Fixed theme path --------------------------------------------------------
OMP_CFG_DIR="$HOME/.config/nix-env/omp"
OMP_THEME="$OMP_CFG_DIR/theme.omp.json"
mkdir -p "$OMP_CFG_DIR"

# -- Install/update theme file -----------------------------------------------
if [[ -n "$omp_theme" ]]; then
  info "setting oh-my-posh theme to '$omp_theme'..."
  # 1. check repo's custom themes first
  # 2. fall back to nix store built-in themes
  theme_src=""
  if [[ -f "$SCRIPT_ROOT/.assets/config/omp_cfg/${omp_theme}.omp.json" ]]; then
    theme_src="$SCRIPT_ROOT/.assets/config/omp_cfg/${omp_theme}.omp.json"
  else
    omp_bin="$(command -v oh-my-posh)"
    omp_store_path="$(dirname "$(dirname "$(readlink -f "$omp_bin")")")"
    nix_theme_dir="$omp_store_path/share/oh-my-posh/themes"
    if [[ -f "$nix_theme_dir/${omp_theme}.omp.json" ]]; then
      theme_src="$nix_theme_dir/${omp_theme}.omp.json"
    fi
  fi
  if [[ -z "$theme_src" ]]; then
    warn "theme '$omp_theme' not found in repo or nix store"
    exit 1
  fi
  cp -f "$theme_src" "$OMP_THEME"
  ok "installed theme '$omp_theme' to $OMP_THEME"
elif [[ ! -f "$OMP_THEME" ]]; then
  # no theme specified and no existing theme - install default (base)
  if [[ -f "$SCRIPT_ROOT/.assets/config/omp_cfg/base.omp.json" ]]; then
    cp -f "$SCRIPT_ROOT/.assets/config/omp_cfg/base.omp.json" "$OMP_THEME"
    ok "installed default theme (base) to $OMP_THEME"
  fi
fi
