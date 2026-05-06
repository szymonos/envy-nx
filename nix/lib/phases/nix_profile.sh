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
      {
        _ir_error="nix profile add failed"
        err "$_ir_error"
        exit 1
      }
  fi
  _io_nix profile upgrade nix-env ||
    {
      _ir_error="nix profile upgrade failed"
      err "$_ir_error"
      exit 1
    }
  ok "nix profile updated in ${SECONDS}s"
}

phase_nix_profile_mitm_probe() {
  # shellcheck source=../../../.assets/lib/certs.sh
  source "$SCRIPT_ROOT/.assets/lib/certs.sh"

  # ca-bundle.crt is also built early in phase_bootstrap_ensure_certs so
  # it exists before any nix/git network call inherits NIX_SSL_CERT_FILE
  # from the user's managed env block. Calling it again here is idempotent
  # (Linux: ln -sf overwrite; macOS: Keychain dump via mktemp+mv) and
  # keeps phase_nix_profile_mitm_probe self-contained for unit testing.
  local ca_bundle="$HOME/.config/certs/ca-bundle.crt"
  local custom_certs="$HOME/.config/certs/ca-custom.crt"
  build_ca_bundle

  # Probe-first on all platforms: intercept certs only when nix tools
  # can't verify TLS on their own (MITM proxy / corporate CA). Gate on
  # ca-custom.crt (the cause), not ca-bundle.crt (the derivative).
  if [[ ! -f "$custom_certs" ]]; then
    # The only portable MITM signal is `openssl s_client -CAfile
    # <Mozilla-only bundle>`: -CAfile overrides system trust store and
    # inherited SSL_CERT_FILE / NIX_SSL_CERT_FILE on every platform.
    # Nix's cacert package ships a Mozilla-only bundle at a known path -
    # use it. (curl --cacert was previously tried but is silently ignored
    # by macOS system curl when built against Secure Transport, and is
    # additive-with-SSL_CERT_FILE on Debian's curl/OpenSSL.)
    #
    # `cacert` and `openssl` are both in base.nix (always installed), so
    # if nix is set up at all the openssl-pinned branch is what runs. The
    # `_io_curl_probe` fallback only fires when nix isn't available - on
    # Linux it trusts /etc/ssl/certs/ and will silently miss MITM, but
    # that's the best we can do without a known-good Mozilla bundle.
    local _probe_failed=false _mozilla_bundle="" _candidate
    for _candidate in \
      "$HOME/.nix-profile/etc/ssl/certs/ca-bundle.crt" \
      "$HOME/.nix-profile/etc/ssl/certs/ca-certificates.crt"; do
      if [[ -f "$_candidate" ]]; then
        _mozilla_bundle="$_candidate"
        break
      fi
    done
    if [[ -n "$_mozilla_bundle" ]] && command -v openssl >/dev/null 2>&1; then
      _io_curl_probe_pinned "$NIX_ENV_TLS_PROBE_URL" "$_mozilla_bundle" || _probe_failed=true
    else
      _io_curl_probe "$NIX_ENV_TLS_PROBE_URL" || _probe_failed=true
    fi
    if [[ "$_probe_failed" == "true" ]] && command -v openssl &>/dev/null; then
      # Distinguish cert failure (MITM/corporate CA) from network failure
      # (DNS down, captive portal, transient outage). The bypass probe
      # disables verification entirely (-k), so no cacert is needed -
      # any working curl will do.
      local _bypass_ok=false
      _io_curl_probe_insecure "$NIX_ENV_TLS_PROBE_URL" && _bypass_ok=true
      if [[ "$_bypass_ok" == "true" ]]; then
        info "corporate TLS proxy detected on $NIX_ENV_TLS_PROBE_URL - importing its certificates into ~/.config/certs/ca-custom.crt so nix-built tools can connect (this is expected on corporate networks)"
        # shellcheck source=../../../.assets/config/shell_cfg/functions.sh
        source "$SCRIPT_ROOT/.assets/config/shell_cfg/functions.sh"
        cert_intercept
        # Rebuild ca-bundle.crt to merge the freshly intercepted ca-custom.crt.
        # No-op on Linux (bundle is a symlink to system store); required on
        # macOS where the bundle is Keychain dump + custom append.
        build_ca_bundle
      else
        warn "TLS probe to $NIX_ENV_TLS_PROBE_URL failed for non-cert reason (DNS/network/captive portal) - skipping cert interception"
      fi
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
