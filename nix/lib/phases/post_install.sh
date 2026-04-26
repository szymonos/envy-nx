# phase: post-install
# Common post-install setup and nix garbage collection.
#
# Reads:  SCRIPT_ROOT, sorted_scopes

phase_post_install_common() {
  local do_update_modules="$1"
  shift
  info "running common post-install setup..."
  local rc=0
  if [[ "$do_update_modules" == "true" ]]; then
    _io_run "$SCRIPT_ROOT/.assets/setup/setup_common.sh" --update-modules "$@" || rc=$?
  else
    _io_run "$SCRIPT_ROOT/.assets/setup/setup_common.sh" "$@" || rc=$?
  fi
  if [[ $rc -ne 0 ]]; then
    warn "common post-install setup completed with errors"
  fi
}

phase_post_install_gc() {
  info "cleaning up old nix profile generations..."
  _io_nix profile wipe-history 2>/dev/null || true
  _io_nix store gc 2>/dev/null || true
}
