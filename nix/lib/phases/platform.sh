# phase: platform
# OS detection, personal scopes discovery, hook runners.
#
# Reads:  ENV_DIR, VALID_SCOPES, OVERLAY_HOOK_DIRS
# Writes: platform, NIX_ENV_PLATFORM, OVERLAY_DIR, overlay_entries
#
# Note: phase_platform_run_hooks sources hook scripts in the current shell
# context. Hooks may read or modify any phase variable (intentional
# extension point). Hook behavior is not testable via _io_* overrides.
# Overlay hooks (phase_platform_run_overlay_hooks) run as child processes
# instead and get no such access (decision 0013).

phase_platform_detect() {
  local os
  os="$(uname -s)"
  case "$os" in
  Darwin) platform="macOS" ;;
  Linux) platform="Linux" ;;
  *) platform="$os" ;;
  esac
  export NIX_ENV_PLATFORM="$platform"
}

phase_platform_run_hooks() {
  local hook_dir="$1"
  [ -d "$hook_dir" ] || return 0
  local hook
  for hook in "$hook_dir"/*.sh; do
    [ -f "$hook" ] || continue
    info "running hook: $(basename "$hook")"
    # shellcheck source=/dev/null
    source "$hook"
  done
}

# Standard scopes named by an overlay scope file's `# scopes:` header, one per
# line. Unknown names warn and are skipped, so an image built against an older
# release still starts.
_overlay_header_scopes() {
  local _s _v _ok
  # read word by word: an unquoted $(...) would glob-expand a `*` in the header
  while read -r _s; do
    [ -n "$_s" ] || continue
    _ok=false
    for _v in "${VALID_SCOPES[@]}"; do
      [ "$_s" = "$_v" ] && _ok=true && break
    done
    if [ "$_ok" = true ]; then
      printf '%s\n' "$_s"
    else
      warn "  unknown scope '$_s' in the # scopes: header of $1 - ignored"
    fi
  done < <(sed -En 's/^#[[:space:]]*scopes:[[:space:]]*//p' "$1" | head -n 1 | tr '-' '_' | tr -s '[:space:]' '\n')
}

# Records the standard scopes named by the header of scope file $2, and
# everything they depend on, as overlay entries of origin $1, so a dependency is
# protected and removed the same way as a scope the header names.
_overlay_add_header_entries() {
  local _hdr _saved _s
  _hdr="$(_overlay_header_scopes "$2" | tr '\n' ' ')"
  [ -n "$_hdr" ] || return 0
  _saved="$_scope_set"
  _scope_set=" $_hdr"
  omp_theme="" resolve_scope_deps
  for _s in $_scope_set; do
    overlay_entries+="$1 $_s $2"$'\n'
  done
  _scope_set="$_saved"
}

# Prints "<origin> <file>" of the first overlay entry providing scope $1.
_overlay_lookup() {
  local _o _s _f
  while read -r _o _s _f; do
    [ "$_s" = "$1" ] && printf '%s %s\n' "$_o" "$_f" && return 0
  done <<<"${overlay_entries:-}"
  return 1
}

# Personal scopes: each $ENV_DIR/local/scopes/*.nix (`nx scope add`) is synced as
# local_<name>.nix and recorded in overlay_entries as a "local <scope> <file>"
# line, with one more line per standard scope its header names. OVERLAY_DIR
# starts as that folder; the overlays phase puts subscriptions in front of it.
phase_platform_discover_overlay() {
  OVERLAY_DIR=""
  overlay_entries=""
  # CLEANUP: CQ-007 - the organization overlay folder became a subscription
  if [ -n "${NIX_ENV_OVERLAY_DIR:-}" ] || [ -f "$ENV_DIR/overlay_dir" ]; then
    warn "NIX_ENV_OVERLAY_DIR and nx overlay set are gone - move the folder's scopes/ (and shell_cfg/, hooks/) into <folder>/overlays/<name>/ and subscribe: nix/setup.sh --overlay '<folder>#<name>'"
  fi
  [ -d "$ENV_DIR/local" ] && OVERLAY_DIR="$ENV_DIR/local"
  export OVERLAY_DIR
  local _dir _origin=local _nix _name
  while IFS= read -r _dir; do
    [ -n "$_dir" ] || continue
    info "personal scopes: $_dir"
    for _nix in "$_dir/scopes"/*.nix; do
      [ -f "$_nix" ] || continue
      _name="local_$(basename "$_nix" .nix)"
      # the name lands unescaped in a quoted config.nix string
      case "$_name" in
      *[!A-Za-z0-9_-]*)
        warn "  $_nix ignored - scope file names may use only letters, digits, - and _"
        continue
        ;;
      local_local_*)
        warn "  $_nix ignored - scope file names cannot start with local_"
        continue
        ;;
      esac
      cp "$_nix" "$ENV_DIR/scopes/$_name.nix"
      overlay_entries+="$_origin $_name $_nix"$'\n'
      _overlay_add_header_entries "$_origin" "$_nix"
    done
  done < <(printf '%s\n' "$OVERLAY_DIR" | tr ':' '\n')
  local _local_nix
  for _local_nix in "$ENV_DIR/scopes"/local_*.nix; do
    [ -f "$_local_nix" ] || continue
    _name="$(basename "$_local_nix" .nix)"
    if ! _overlay_lookup "$_name" >/dev/null; then
      rm -f "$_local_nix"
      info "  removed orphaned overlay scope: ${_name#local_}"
    fi
  done
  [ -n "$overlay_entries" ] && ok "  synced overlay scopes"
  return 0
}

# Post-setup hooks of overlays read from a local folder (OVERLAY_HOOK_DIRS),
# then of the personal scopes folder. OVERLAY_DIR also lists the copies of
# subscribed overlays, which never hold hooks/. PATH carries the nix profile,
# ~/.local/bin, fnm's default Node and the gcloud tarball install, so a hook can
# call npm, uv or gcloud. Without FNM_DIR, fnm picks its folder itself: an
# existing ~/.fnm, else the XDG data folder, or Application Support on macOS.
# Every candidate goes on PATH; the missing ones cost nothing.
phase_platform_run_overlay_hooks() {
  local _dir _hook
  local _fnm_bin="aliases/default/bin" _path
  if [ -n "${FNM_DIR:-}" ]; then
    _path="$FNM_DIR/$_fnm_bin"
  else
    _path="$HOME/.fnm/$_fnm_bin:${XDG_DATA_HOME:-$HOME/.local/share}/fnm/$_fnm_bin"
    _path="$_path:$HOME/Library/Application Support/fnm/$_fnm_bin"
  fi
  _path="$_path:$HOME/google-cloud-sdk/bin:$HOME/.local/bin:$HOME/.nix-profile/bin:$PATH"
  # The trust-store variables the managed rc block exports (the `# :certs` block
  # of _nx_render_nix_block), so a hook's npm, pip or curl trusts a TLS-inspecting
  # proxy the way an interactive shell does. Setup's own environment has none.
  local _certs="$HOME/.config/certs" _env=()
  [ -f "$_certs/ca-custom.crt" ] && _env+=("NODE_EXTRA_CA_CERTS=$_certs/ca-custom.crt")
  if [ -f "$_certs/ca-bundle.crt" ]; then
    _env+=("REQUESTS_CA_BUNDLE=$_certs/ca-bundle.crt" "SSL_CERT_FILE=$_certs/ca-bundle.crt")
    _env+=("CURL_CA_BUNDLE=$_certs/ca-bundle.crt" "PIP_CERT=$_certs/ca-bundle.crt")
    _env+=("AWS_CA_BUNDLE=$_certs/ca-bundle.crt" "CLOUDSDK_CORE_CUSTOM_CA_CERTS_FILE=$_certs/ca-bundle.crt")
  fi
  # the list comes in on fd 3 so a hook reading stdin cannot eat the next entry
  while IFS= read -r _dir <&3; do
    [ -n "$_dir" ] && [ -d "$_dir/hooks/post-setup.d" ] || continue
    for _hook in "$_dir/hooks/post-setup.d"/*.sh; do
      [ -f "$_hook" ] || continue
      info "running overlay hook: $_hook"
      env ${_env[@]+"${_env[@]}"} ENV_DIR="$ENV_DIR" PATH="$_path" bash "$_hook" 3<&- ||
        warn "overlay hook failed: $_hook"
    done
  done 3< <(printf '%s:%s\n' "${OVERLAY_HOOK_DIRS:-}" "${OVERLAY_DIR:-}" | tr ':' '\n')
}
