# phase: scopes
# Load existing scopes, merge with CLI flags, resolve deps, write config.nix.
# Distinct from .assets/lib/scopes.sh (the shared scope-set library).
# shellcheck disable=SC2154  # CONFIG_NIX, any_scope, remove_scopes, omp_theme,
#   starship_theme, allow_unfree, platform - set by bootstrap/platform phases
#
# Reads:  CONFIG_NIX, any_scope, remove_scopes, omp_theme, starship_theme,
#         allow_unfree
# Writes: _scope_set, _scope_sorted, NIX_ENV_SCOPES, allow_unfree,
#         _ir_phase, _ir_error

phase_scopes_load_existing() {
  if [[ -f "$CONFIG_NIX" ]]; then
    if [[ "$any_scope" == "false" && ${#remove_scopes[@]} -eq 0 ]]; then
      info "no scope flags provided - loading scopes from config.nix..."
    else
      info "loading existing scopes from config.nix and merging with CLI flags..."
    fi
    local nix_eval_output nix_eval_rc
    nix_eval_output="$(NIX_ENV_CFG_PATH="$CONFIG_NIX" _io_nix_eval '
      let cfg = import (builtins.toPath (builtins.getEnv "NIX_ENV_CFG_PATH"));
      in builtins.concatStringsSep "\n" cfg.scopes
    ' 2>&1)"
    nix_eval_rc=$?
    if [[ $nix_eval_rc -eq 0 ]]; then
      local sc
      while IFS= read -r sc; do
        [[ -n "$sc" ]] && scope_add "$sc"
      done <<<"$nix_eval_output"
    else
      warn "failed to read config.nix: $nix_eval_output"
      if [[ ${#remove_scopes[@]} -gt 0 ]]; then
        _ir_error="cannot --remove scopes when config.nix is unreadable"
        err "$_ir_error"
        exit 1
      fi
    fi
    # preserve existing allowUnfree unless explicitly set via CLI
    if [[ "$allow_unfree" == "false" ]]; then
      local unfree_val
      unfree_val="$(NIX_ENV_CFG_PATH="$CONFIG_NIX" _io_nix_eval '
        let cfg = import (builtins.toPath (builtins.getEnv "NIX_ENV_CFG_PATH"));
        in if cfg ? allowUnfree then (if cfg.allowUnfree then "true" else "false") else "false"
      ' 2>&1)" || true
      if [[ "$unfree_val" == "true" ]]; then allow_unfree="true"; fi
    fi
  elif [[ "$any_scope" == "false" && ${#remove_scopes[@]} -eq 0 ]]; then
    info "no scope flags provided and no config.nix found - detecting from system..."
    command -v oh-my-posh &>/dev/null && scope_add oh_my_posh || true
    command -v docker &>/dev/null && scope_add docker || true
    { [[ -x "$HOME/.local/bin/uv" ]] || [[ -x "$HOME/.nix-profile/bin/uv" ]]; } && scope_add python || true
    command -v conda &>/dev/null && scope_add conda || true
  fi
}

phase_scopes_apply_removes() {
  if [[ ${#remove_scopes[@]} -gt 0 ]]; then
    validate_scopes "${remove_scopes[@]}" || exit 2
    local sc
    for sc in "${remove_scopes[@]}"; do
      if scope_has "$sc"; then
        scope_del "$sc"
        ok "removed scope: $sc"
        # per-scope cleanup hooks for empty-scope state on disk.
        # docker/distrobox are system installs (need root) - left to the user.
        case "$sc" in
        conda)
          # shellcheck disable=SC2154  # unattended set by phase_bootstrap_parse_args
          _io_run "$SCRIPT_ROOT/nix/configure/conda_remove.sh" "${unattended:-false}" ||
            warn "conda removal cleanup failed"
          ;;
        nodejs)
          # shellcheck disable=SC2154  # unattended set by phase_bootstrap_parse_args
          _io_run "$SCRIPT_ROOT/nix/configure/nodejs_remove.sh" "${unattended:-false}" ||
            warn "nodejs removal cleanup failed"
          ;;
        python)
          # shellcheck disable=SC2154  # unattended set by phase_bootstrap_parse_args
          _io_run "$SCRIPT_ROOT/nix/configure/python_remove.sh" "${unattended:-false}" ||
            warn "python removal cleanup failed"
          ;;
        esac
      else
        warn "scope '$sc' is not currently configured - skipping"
      fi
    done
  fi
}

phase_scopes_enforce_prompt_exclusivity() {
  if [[ -n "$omp_theme" && -n "$starship_theme" ]]; then
    _ir_error="cannot use both --omp-theme and --starship-theme"
    err "$_ir_error"
    exit 2
  fi
  if [[ -n "$omp_theme" ]]; then
    scope_del starship
  elif [[ -n "$starship_theme" ]]; then
    scope_del oh_my_posh
  fi
}

phase_scopes_resolve_and_sort() {
  resolve_scope_deps
  sort_scopes
  NIX_ENV_SCOPES="${_scope_sorted[*]:-}"
  export NIX_ENV_SCOPES

  printf "\n\e[95;1m>> Dev Environment Setup via Nix (%s)\e[0m" "$platform"
  # shellcheck disable=SC2154  # _scope_sorted is populated by sort_scopes
  if ((${#_scope_sorted[@]} > 0)); then
    printf " : \e[3;90m%s\e[0m" "${_scope_sorted[*]}"
  fi
  printf "\n\n"
}

has_system_cmd() {
  local cmd_path
  cmd_path="$(command -v "$1" 2>/dev/null)" || return 1
  [[ "$cmd_path" != /nix/* && "$cmd_path" != */.nix-profile/* ]]
}

phase_scopes_detect_init() {
  is_init=false
  if ! has_system_cmd jq || ! has_system_cmd curl; then
    is_init=true
  fi
}

# On Linux, handle system-prefer scopes:
#   - zsh: nix scope only provides plugins, not the binary. Remove if zsh is missing.
# On macOS there is no system package manager, so nix is the correct provider.
phase_scopes_skip_system_prefer() {
  [[ "$(uname -s)" == "Darwin" ]] && return 0
  local changed=false
  if scope_has zsh; then
    if has_system_cmd zsh; then
      scope_del zsh
      info "zsh found system-wide - skipping nix scope"
      changed=true
    elif ! command -v zsh &>/dev/null; then
      scope_del zsh
      warn "zsh not found - install it system-wide first (e.g. sudo apt install zsh)"
      changed=true
    fi
  fi
  if [[ "$changed" == "true" ]]; then
    sort_scopes
    NIX_ENV_SCOPES="${_scope_sorted[*]:-}"
    export NIX_ENV_SCOPES
  fi
}

phase_scopes_write_config() {
  local nix_scopes=""
  local sc
  for sc in "${_scope_sorted[@]}"; do
    nix_scopes+="    \"$sc\""$'\n'
  done

  # Write to a temp first; only rename if content actually differs from the
  # current file. Preserves mtime on no-op runs so the path:flake's
  # lastModified stays stable.
  local _tmp
  _tmp="$(mktemp "${CONFIG_NIX}.XXXXXX")" || {
    err "could not create temp file for config.nix"
    return 1
  }
  cat >"$_tmp" <<EOF
# Generated by setup.sh -- do not edit manually.
# Re-run setup.sh with scope flags to change, or edit and run:
#   nix profile upgrade nix-env
{
  isInit = $is_init;
  allowUnfree = $allow_unfree;

  scopes = [
$nix_scopes  ];
}
EOF

  if [ -f "$CONFIG_NIX" ] && cmp -s "$_tmp" "$CONFIG_NIX"; then
    rm -f "$_tmp"
    info "config.nix unchanged (${#_scope_sorted[@]} scopes)"
    return 0
  fi
  mv -f "$_tmp" "$CONFIG_NIX"
  info "generated config.nix with ${#_scope_sorted[@]} scopes"
}
