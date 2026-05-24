# phase: post-install
# Common post-install setup and nix garbage collection.
#
# Reads:  SCRIPT_ROOT, _scope_sorted
# Writes: (none)

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
  _io_nix profile wipe-history 2>/dev/null || warn "nix profile wipe-history failed (old generations retained)"
  _io_nix store gc 2>/dev/null || warn "nix store gc failed (stale paths retained)"
  _phase_post_install_clear_stale_caches
}

# Sweep caches that embed absolute /nix/store/<hash>-<pkg>/... paths. After
# the GC above, the previously-active oh-my-posh / pwsh-module store paths
# are deleted, but cached init files still reference them - the next shell
# launch errors at every prompt. Kept in sync with _nx_clear_stale_caches
# in .assets/lib/nx.sh (called by `nx upgrade` / `nx gc`); both paths run
# the same sweep so the cache is cleared whether the user upgrades via
# nix/setup.sh or via `nx upgrade`. See .claude/rules/cross-shell-parity.md.
_phase_post_install_clear_stale_caches() {
  local _cleared=0 _f
  local _pwsh_dir="$HOME/.cache/powershell"
  local _omp_dir="$HOME/.cache/oh-my-posh"
  if [[ -d "$_pwsh_dir" ]]; then
    while IFS= read -r _f; do
      [[ -n "$_f" ]] || continue
      rm -f "$_f" && _cleared=$((_cleared + 1))
    done < <(find "$_pwsh_dir" -maxdepth 1 -type f \( -name 'ModuleAnalysisCache-*' -o -name 'StartupProfileData-*' \) 2>/dev/null)
  fi
  if [[ -d "$_omp_dir" ]]; then
    while IFS= read -r _f; do
      [[ -n "$_f" ]] || continue
      rm -f "$_f" && _cleared=$((_cleared + 1))
    done < <(find "$_omp_dir" -maxdepth 1 -type f \( -name 'init.*.sh' -o -name 'init.*.ps1' \) 2>/dev/null)
  fi
  if [[ "$_cleared" -gt 0 ]]; then
    info "cleared $_cleared stale shell cache file(s) (regenerates on next shell launch)"
  fi
}
