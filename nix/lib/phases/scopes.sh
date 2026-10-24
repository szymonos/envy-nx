# phase: scopes
# Load existing scopes, merge with CLI flags, resolve deps, write config.nix.
# Distinct from .assets/lib/scopes.sh (the shared scope-set library).
# shellcheck disable=SC2154  # CONFIG_NIX, any_scope, remove_scopes, omp_theme,
#   starship_theme, allow_unfree, platform - set by bootstrap/platform phases
#
# Reads:  CONFIG_NIX, any_scope, remove_scopes, omp_theme, starship_theme,
#         allow_unfree, SCRIPT_ROOT, unattended, platform, ENV_DIR,
#         overlay_entries, _cli_scope_set
# Writes: _scope_set, _scope_sorted, NIX_ENV_SCOPES, allow_unfree,
#         is_init, _ir_error, remove_scopes, $ENV_DIR/overlay_scopes

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
  elif [[ "$any_scope" == "false" && ${#remove_scopes[@]} -eq 0 && -z "${OVERLAY_DIR:-}" ]]; then
    # skipped with an overlay: it describes the environment, and an image's own
    # docker or conda must not add scopes it did not ask for
    info "no scope flags provided and no config.nix found - detecting from system..."
    command -v oh-my-posh &>/dev/null && scope_add oh_my_posh || true
    command -v docker &>/dev/null && scope_add docker || true
    { [[ -x "$HOME/.local/bin/uv" ]] || [[ -x "$HOME/.nix-profile/bin/uv" ]]; } && scope_add python || true
    command -v conda &>/dev/null && scope_add conda || true
  fi
}

# Overlays are the target state for what they provide (decision 0013). Their
# scopes, and the standard scopes their `# scopes:` headers name, are enabled on
# every run and cannot be removed around the overlay. A scope an overlay stops
# providing is dropped; a header scope also gets its remove step, once.
# $ENV_DIR/overlay_scopes keeps the last run's entries for that comparison and
# for nx, which reads it to refuse the same removals.
phase_scopes_apply_overlay() {
  local _state="$ENV_DIR/overlay_scopes"
  local _o _s _f _hit _kept=() _r _saved _resolved
  for _r in "${remove_scopes[@]}"; do
    # an org scope file is refused by its name with or without the local_
    # prefix; parse_args has already turned the name's - into _
    _hit=""
    while read -r _o _s _f; do
      [ "$_o" = org ] && [ "${_s//-/_}" = "local_${_r#local_}" ] && _hit="$_o $_f" && break
    done <<<"${overlay_entries:-}"
    if [ -n "$_hit" ] || _hit="$(_overlay_lookup "$_r")"; then
      if [ "${_hit%% *}" = org ]; then
        warn "$_r is controlled by the organization overlay (${_hit#* }) - not removed"
      else
        warn "$_r is named in the # scopes: header of ${_hit#* } - remove it there"
      fi
    else
      _kept+=("$_r")
    fi
  done
  remove_scopes=("${_kept[@]}")

  while read -r _o _s _f; do
    [ -n "$_s" ] || continue
    if [ "$_o" = org ] && [[ " ${_cli_scope_set:-} " == *" $_s "* ]]; then
      info "$_s is provided by the organization overlay ($_f)"
    fi
    scope_add "$_s"
  done <<<"${overlay_entries:-}"

  for _s in $_scope_set; do
    [[ "$_s" == local_* ]] || continue
    _overlay_lookup "$_s" >/dev/null || scope_del "$_s"
  done

  [ -f "$_state" ] || return 0
  local _dropped=" "
  while read -r _o _s _f; do
    [[ -n "$_s" && "$_s" != local_* ]] || continue
    _overlay_lookup "$_s" >/dev/null && continue
    [[ " ${_cli_scope_set:-} " == *" $_s "* ]] && continue
    scope_has "$_s" || continue
    [[ " ${remove_scopes[*]} " == *" $_s "* || "$_dropped" == *" $_s "* ]] && continue
    _dropped+="$_s "
  done <"$_state"
  # A dropped scope that the scopes staying still depend on comes straight back,
  # so its remove step would only delete state the scope still uses.
  _saved="$_scope_set"
  for _s in $_dropped "${remove_scopes[@]}"; do scope_del "$_s"; done
  resolve_scope_deps
  _resolved="$_scope_set"
  _scope_set="$_saved"
  for _s in $_dropped; do
    [[ " $_resolved " == *" $_s "* ]] && continue
    info "$_s is no longer named by an overlay - removing it"
    remove_scopes+=("$_s")
  done
}

# Saved only once config.nix is written, so a run that exits before then (an
# invalid --remove name) repeats the once-only header removals next time.
phase_scopes_save_overlay_state() {
  local _state="$ENV_DIR/overlay_scopes"
  [ -n "${overlay_entries:-}" ] || [ -f "$_state" ] || return 0
  local _tmp
  _tmp="$(mktemp "$_state.XXXXXX")"
  printf '%s' "${overlay_entries:-}" >"$_tmp"
  if [ -f "$_state" ] && cmp -s "$_tmp" "$_state"; then
    rm -f "$_tmp"
  else
    mv -f "$_tmp" "$_state"
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
        gcloud)
          # shellcheck disable=SC2154  # unattended set by phase_bootstrap_parse_args
          _io_run "$SCRIPT_ROOT/nix/configure/gcloud_remove.sh" "${unattended:-false}" ||
            warn "gcloud removal cleanup failed"
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
  # The engine an overlay names replaces the user's other one, flag or not.
  # When both overlays name a different engine, the org overlay's wins.
  local _omp _star _engine=""
  _omp="$(_overlay_lookup oh_my_posh)" || _omp=""
  _star="$(_overlay_lookup starship)" || _star=""
  if [ -n "$_omp" ] && { [ -z "$_star" ] || { [ "${_omp%% *}" = org ] && [ "${_star%% *}" = local ]; }; }; then
    _engine=oh_my_posh
  elif [ -n "$_star" ] && { [ -z "$_omp" ] || { [ "${_star%% *}" = org ] && [ "${_omp%% *}" = local ]; }; }; then
    _engine=starship
  elif [ -n "$_omp" ]; then
    warn "overlays name both prompt engines (${_omp#* }, ${_star#* }) - keeping oh_my_posh"
    _engine=oh_my_posh
  fi
  if [[ -n "$omp_theme" && "$_engine" = starship ]]; then
    warn "starship is provided by an overlay (${_star#* }) - --omp-theme ignored"
    omp_theme=""
  elif [[ -n "$starship_theme" && "$_engine" = oh_my_posh ]]; then
    warn "oh_my_posh is provided by an overlay (${_omp#* }) - --starship-theme ignored"
    starship_theme=""
  fi
  if [[ -n "$omp_theme" ]]; then
    scope_del starship
  elif [[ -n "$starship_theme" ]]; then
    scope_del oh_my_posh
  elif [ "$_engine" = oh_my_posh ]; then
    scope_has starship && info "starship dropped - an overlay provides oh_my_posh (${_omp#* })"
    scope_del starship
  elif [ "$_engine" = starship ]; then
    scope_has oh_my_posh && info "oh_my_posh dropped - an overlay provides starship (${_star#* })"
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
