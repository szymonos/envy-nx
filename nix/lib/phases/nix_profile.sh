# phase: nix-profile
# Flake update, nix profile upgrade, MITM proxy certificate detection.
# shellcheck disable=SC2154  # ENV_DIR, upgrade_packages, SCRIPT_ROOT - set by bootstrap phase
#
# Reads:  ENV_DIR, upgrade_packages, SCRIPT_ROOT
# Writes: PINNED_REV, _ir_error

should_update_flake() {
  local upgrade_flag="${1:-false}"
  [[ "$upgrade_flag" == "true" ]] && return 0
  return 1
}

phase_nix_profile_load_pinned_rev() {
  PINNED_REV=""
  if [[ -f "$ENV_DIR/pinned_rev" ]]; then
    PINNED_REV="$(tr -d '[:space:]' <"$ENV_DIR/pinned_rev")"
  fi
}

phase_nix_profile_print_mode() {
  if [[ ! -f "$ENV_DIR/flake.lock" ]]; then
    info "first run - resolving nixpkgs and installing..."
  elif should_update_flake "$upgrade_packages"; then
    if [[ -n "$PINNED_REV" ]]; then
      info "pinning nixpkgs to $PINNED_REV..."
    else
      info "upgrading all packages to latest (nix flake update + profile upgrade)..."
    fi
  else
    info "applying nix configuration (use --upgrade to pull latest packages)..."
  fi
}

phase_nix_profile_update_flake() {
  SECONDS=0
  if should_update_flake "$upgrade_packages"; then
    if [[ -n "$PINNED_REV" ]]; then
      _io_nix flake lock --override-input nixpkgs "github:nixos/nixpkgs/$PINNED_REV" --flake "$ENV_DIR" 2>/dev/null ||
        warn "flake lock failed - using existing lock"
    else
      _io_nix flake update --flake "$ENV_DIR" 2>/dev/null ||
        warn "flake update failed (network issue?) - using existing lock"
    fi
  fi
}

phase_nix_profile_apply() {
  if ! _io_nix profile list --json 2>/dev/null | grep -q 'nix-env'; then
    _io_nix profile add "path:$ENV_DIR" 2>&1 ||
      { _ir_error="nix profile add failed"; err "$_ir_error"; exit 1; }
  fi
  _io_nix profile upgrade nix-env ||
    { _ir_error="nix profile upgrade failed"; err "$_ir_error"; exit 1; }
  ok "nix profile updated in ${SECONDS}s"
}

phase_nix_profile_mitm_probe() {
  # shellcheck source=../../../.assets/lib/certs.sh
  source "$SCRIPT_ROOT/.assets/lib/certs.sh"

  # Probe-first on all platforms: only build a CA bundle when nix tools
  # can't verify TLS on their own (MITM proxy / corporate CA). Without
  # interception, tools use their own optimized cert paths (e.g. rustls
  # bundled roots in uv).
  local ca_bundle="$HOME/.config/certs/ca-bundle.crt"
  if [[ ! -f "$ca_bundle" ]]; then
    # Use nix curl - system curl on macOS uses Keychain and passes behind
    # MITM proxies that nix tools (isolated OpenSSL) would reject.
    local _probe_failed=false
    if [[ -x "$HOME/.nix-profile/bin/curl" ]]; then
      "$HOME/.nix-profile/bin/curl" -sS "$NIX_ENV_TLS_PROBE_URL" >/dev/null 2>&1 || _probe_failed=true
    else
      _io_curl_probe "$NIX_ENV_TLS_PROBE_URL" || _probe_failed=true
    fi
    if [[ "$_probe_failed" == "true" ]] && command -v openssl &>/dev/null; then
      warn "SSL verification failed - MITM proxy detected, intercepting certificates..."
      # shellcheck source=../../../.assets/config/shell_cfg/functions.sh
      source "$SCRIPT_ROOT/.assets/config/shell_cfg/functions.sh"
      cert_intercept
      build_ca_bundle
    fi
  fi

  # Configure env vars and git for all nix-built tools
  if [[ -f "$ca_bundle" ]]; then
    export NIX_SSL_CERT_FILE="$ca_bundle"
    export SSL_CERT_FILE="$ca_bundle"
    _io_run git config --global http.sslCAInfo "$ca_bundle"
    ok "configured CA bundle for nix tools ($ca_bundle)"
  fi
}
