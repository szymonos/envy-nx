# phase: configure
# GitHub CLI auth, git config, scope-based post-install configuration.
# shellcheck disable=SC2154  # CONFIGURE_DIR, _scope_sorted, omp_theme,
#   starship_theme - set by bootstrap phase
#
# Reads:  CONFIGURE_DIR, _scope_sorted, omp_theme, starship_theme
# Writes: GITHUB_TOKEN

# gh.sh and git.sh are invoked directly (NOT through _io_run): both emit
# user prompts on stderr (`gh auth login`'s device code line; bash's
# `read -rp`), and _io_run captures stderr to a tempfile that is only
# replayed on failure -- stdin stays wired to the terminal, so the user
# would be left typing blind.
phase_configure_gh() {
  local unattended="${1:-false}"
  info "configuring GitHub CLI..."
  "$CONFIGURE_DIR/gh.sh" "$unattended" || warn "GitHub CLI configuration failed"
  if [[ -z "${GITHUB_TOKEN:-}" ]] && command -v gh &>/dev/null && gh auth token &>/dev/null; then
    GITHUB_TOKEN="$(gh auth token 2>/dev/null)"
    export GITHUB_TOKEN
  fi
}

phase_configure_git() {
  local unattended="${1:-false}"
  if [[ "$unattended" != "true" ]]; then
    info "configuring git identity..."
    "$CONFIGURE_DIR/git.sh" || warn "git configuration failed"
  fi
}

phase_configure_per_scope() {
  local sc
  info "running per-scope configuration..."
  for sc in "${_scope_sorted[@]}"; do
    case $sc in
    docker)
      _io_run "$CONFIGURE_DIR/docker.sh" || warn "docker configuration failed"
      ;;
    conda)
      _io_run "$CONFIGURE_DIR/conda.sh" || warn "conda configuration failed"
      ;;
    nodejs)
      # shellcheck disable=SC2154  # unattended set by phase_bootstrap_parse_args
      _io_run "$CONFIGURE_DIR/nodejs.sh" "${unattended:-false}" ||
        warn "nodejs configuration failed"
      ;;
    az)
      _io_run "$CONFIGURE_DIR/az.sh" || warn "az configuration failed"
      ;;
    oh_my_posh)
      _io_run "$CONFIGURE_DIR/omp.sh" "$omp_theme" || warn "oh-my-posh configuration failed"
      ;;
    starship)
      _io_run "$CONFIGURE_DIR/starship.sh" "$starship_theme" || warn "starship configuration failed"
      ;;
    terraform)
      _io_run "$CONFIGURE_DIR/terraform.sh" || warn "terraform configuration failed"
      ;;
    pwsh)
      mkdir -p "$HOME/.local/bin"
      ln -sf "$HOME/.nix-profile/bin/pwsh" "$HOME/.local/bin/pwsh"
      ;;
    esac
  done
}
