# phase: platform
# OS detection, overlay directory discovery, hook runner.
#
# Reads:  ENV_DIR, NIX_ENV_OVERLAY_DIR (env), overlay_dir_arg, VALID_SCOPES
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

# Prints "<origin> <file>" of the first overlay entry providing scope $1.
_overlay_lookup() {
  local _o _s _f
  while read -r _o _s _f; do
    [ "$_s" = "$1" ] && printf '%s %s\n' "$_o" "$_f" && return 0
  done <<<"${overlay_entries:-}"
  return 1
}

# Collects every overlay directory: the org overlay first, then $ENV_DIR/local
# (the personal one), as a colon-separated
# OVERLAY_DIR. Each scope file is synced as local_<name>.nix and recorded in
# overlay_entries as "<origin> <scope> <file>" lines, with one more line per
# standard scope its header names. On a name clash the org file wins.
phase_platform_discover_overlay() {
  OVERLAY_DIR=""
  overlay_entries=""
  # The org overlay comes from --overlay-dir, then NIX_ENV_OVERLAY_DIR, then the
  # path the last run saved in $ENV_DIR/overlay_dir, so a shell that does not
  # export the variable still sees it. Only `nx overlay unset` forgets it.
  local _org="" _src=""
  if [ -n "${overlay_dir_arg:-}" ]; then
    _org="$overlay_dir_arg" _src="--overlay-dir"
  elif [ -n "${NIX_ENV_OVERLAY_DIR:-}" ]; then
    _org="$NIX_ENV_OVERLAY_DIR" _src="NIX_ENV_OVERLAY_DIR"
  elif [ -f "$ENV_DIR/overlay_dir" ]; then
    _org="$(head -n 1 "$ENV_DIR/overlay_dir")" _src="$ENV_DIR/overlay_dir"
    if [ -z "$_org" ]; then
      _ir_error="$ENV_DIR/overlay_dir is empty"
      err "$_ir_error - run nx overlay set <path>, or nx overlay unset to stop using an organization overlay"
      exit 1
    fi
  fi
  if [ -n "$_org" ]; then
    # OVERLAY_DIR joins folders with `:`, and the saved file holds one line
    case "$_org" in
    *:* | *"
"*)
      _ir_error="organization overlay path cannot contain ':' or a newline: $_org"
      err "$_ir_error"
      exit 1
      ;;
    esac
    # A missing or unreadable folder (a mount not there yet, a permission change)
    # would read as "every org scope deleted" and run their remove steps, so stop
    # before touching anything.
    if [ ! -d "$_org" ] || [ ! -r "$_org" ] || [ ! -x "$_org" ] ||
      { { [ -e "$_org/scopes" ] || [ -L "$_org/scopes" ]; } &&
        { [ ! -d "$_org/scopes" ] || [ ! -r "$_org/scopes" ] || [ ! -x "$_org/scopes" ]; }; }; then
      _ir_error="organization overlay $_org (from $_src) is not a readable directory"
      err "$_ir_error - fix the path or its permissions, or run nx overlay unset to stop using it"
      exit 1
    fi
    _org="$(cd "$_org" && pwd)"
    # physical paths, so a symlink to the config folder is caught too
    if [ "$(cd "$_org" && pwd -P)" = "$(cd "$ENV_DIR" && pwd -P)" ]; then
      _ir_error="organization overlay $_org (from $_src) is the Envy-NX config folder itself"
      err "$_ir_error - point it at the overlay folder"
      exit 1
    fi
    if [ "$(head -n 1 "$ENV_DIR/overlay_dir" 2>/dev/null)" != "$_org" ]; then
      local _tmp
      _tmp="$(mktemp "$ENV_DIR/overlay_dir.XXXXXX")"
      printf '%s\n' "$_org" >"$_tmp" && mv -f "$_tmp" "$ENV_DIR/overlay_dir"
    fi
    OVERLAY_DIR="$_org"
  fi
  if [ -d "$ENV_DIR/local" ] && [ "$ENV_DIR/local" != "$_org" ]; then
    OVERLAY_DIR="${OVERLAY_DIR:+$OVERLAY_DIR:}$ENV_DIR/local"
  fi
  export OVERLAY_DIR
  local _dir _origin _nix _name _prev _s
  while IFS= read -r _dir; do
    [ -n "$_dir" ] || continue
    _origin=local
    [ "$_dir" = "$_org" ] && _origin=org
    info "overlay directory: $_dir"
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
      if _prev="$(_overlay_lookup "$_name")"; then
        warn "  $_nix ignored - the organization overlay provides ${_name#local_} (${_prev#* })"
        continue
      fi
      cp "$_nix" "$ENV_DIR/scopes/$_name.nix"
      overlay_entries+="$_origin $_name $_nix"$'\n'
      # the header's scopes and everything they depend on, so a dependency is
      # protected and removed the same way as a scope the header names
      local _hdr _saved
      _hdr="$(_overlay_header_scopes "$_nix" | tr '\n' ' ')"
      if [ -n "$_hdr" ]; then
        _saved="$_scope_set"
        _scope_set=" $_hdr"
        omp_theme="" resolve_scope_deps
        for _s in $_scope_set; do
          overlay_entries+="$_origin $_s $_nix"$'\n'
        done
        _scope_set="$_saved"
      fi
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

# Overlay post-setup hooks, org overlay first. PATH carries the nix profile,
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
  # the list comes in on fd 3 so a hook reading stdin cannot eat the next entry
  while IFS= read -r _dir <&3; do
    [ -n "$_dir" ] && [ -d "$_dir/hooks/post-setup.d" ] || continue
    for _hook in "$_dir/hooks/post-setup.d"/*.sh; do
      [ -f "$_hook" ] || continue
      info "running overlay hook: $_hook"
      ENV_DIR="$ENV_DIR" PATH="$_path" bash "$_hook" 3<&- || warn "overlay hook failed: $_hook"
    done
  done 3< <(printf '%s\n' "${OVERLAY_DIR:-}" | tr ':' '\n')
}
