# phase: profiles
# Bash, zsh, and PowerShell shell profile setup.
#
# Reads:  CONFIGURE_DIR

phase_profiles_bash() {
  info "setting up bash profile..."
  _io_run "$CONFIGURE_DIR/profiles.sh" || warn "bash profile setup failed"
}

phase_profiles_zsh() {
  if command -v zsh &>/dev/null; then
    info "setting up zsh profile..."
    _io_run "$CONFIGURE_DIR/profiles.zsh" || warn "zsh profile setup failed"
  fi
}

phase_profiles_pwsh() {
  if command -v pwsh &>/dev/null; then
    info "setting up PowerShell profile..."
    _io_run _io_pwsh_nop "$CONFIGURE_DIR/profiles.ps1" || warn "PowerShell profile setup failed"
  fi
}
