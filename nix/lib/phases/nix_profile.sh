# phase: nix-profile
# Flake update, nix profile upgrade, MITM proxy certificate detection.
# shellcheck disable=SC2154  # ENV_DIR, upgrade_packages, SCRIPT_ROOT - set by bootstrap phase
#
# Reads:  ENV_DIR, DEV_ENV_DIR, upgrade_packages, upgrade_latest, SCRIPT_ROOT,
#         NIX_ENV_TLS_PROBE_URL
# Writes: NX_REV_MODE, NX_REV_SHA, _ir_error, NIX_SSL_CERT_FILE, SSL_CERT_FILE

should_update_flake() {
  local upgrade_flag="${1:-false}"
  [[ "$upgrade_flag" == "true" ]] && return 0
  return 1
}

# Resolve which nixpkgs revision this run should lock, using the same ladder as
# `nx upgrade` (.assets/lib/nx_rev.sh). Both entry points must agree - if they
# don't, which nixpkgs a user ends up on depends on whether they typed
# `nx upgrade` or re-ran setup.sh.
phase_nix_profile_load_rev() {
  # shellcheck source=../../../.assets/lib/nx_rev.sh
  source "$SCRIPT_ROOT/.assets/lib/nx_rev.sh"
  local _resolved
  _resolved="$(_nx_rev_resolve "$ENV_DIR" "${upgrade_latest:-false}")"
  NX_REV_MODE="${_resolved%% *}"
  NX_REV_SHA=""
  case "$_resolved" in *" "*) NX_REV_SHA="${_resolved#* }" ;; esac
}

phase_nix_profile_print_mode() {
  if [[ ! -f "$ENV_DIR/flake.lock" ]]; then
    info "first run - resolving nixpkgs and installing..."
  elif should_update_flake "$upgrade_packages"; then
    case "$NX_REV_MODE" in
    pinned) info "pinning nixpkgs to $NX_REV_SHA..." ;;
    validated) info "upgrading to the validated nixpkgs ${NX_REV_SHA:0:12}..." ;;
    latest) info "upgrading to nixpkgs-unstable HEAD - not validated by CI..." ;;
    *) info "no validated revision on disk - keeping the current lock..." ;;
    esac
  else
    info "applying nix configuration (use --upgrade to pull latest packages)..."
  fi
}

phase_nix_profile_update_flake() {
  # Also runs when there is no lock yet, not only on --upgrade: left to itself
  # `nix profile add` resolves nixpkgs-unstable HEAD and writes a lock naming a
  # revision no CI has ever built. Locking the validated rev first is what
  # makes a *first* install gated, not just an upgrade.
  local _first_run=false
  [[ -f "$ENV_DIR/flake.lock" ]] || _first_run=true
  if should_update_flake "$upgrade_packages" || { [[ "$_first_run" == "true" ]] && [[ -n "$NX_REV_SHA" ]]; }; then
    # Refuse to move backwards on an existing install. Mirrors the same guard
    # in _nx_pkg_upgrade: a user who moved ahead with --latest must not be
    # dragged back whenever the CI bump is lagging behind them.
    if [[ "$_first_run" == "false" && "$NX_REV_MODE" == "validated" ]]; then
      local _cand_epoch
      _cand_epoch="$(_nx_rev_json_field "$ENV_DIR/nixpkgs_rev.json" lastModified)"
      if _nx_rev_is_downgrade "$ENV_DIR" "$_cand_epoch"; then
        info "already at or ahead of the validated revision - keeping the current lock"
        return 0
      fi
    fi
    # nix writes progress (the live progress bar and per-path "copying path"
    # lines) to stderr; let it through so the user sees what's happening
    # during the network-bound flake update.
    #
    # Give nix a GitHub token so it can fetch nixpkgs metadata without hitting
    # the unauthenticated API rate limit (60 req/h). GITHUB_TOKEN is preferred
    # (covers CI / headless environments); a `gh auth token` fallback covers
    # interactive sessions where the env var is unset. `-h github.com` scopes the
    # fallback to github.com so a GitHub Enterprise `gh` config can't hand back a
    # GHE-host token that we would then mis-wire to github.com (matches the
    # host-scoped auth in nix/configure/gh.sh).
    local _gh_token="${GITHUB_TOKEN:-}"
    if [[ -z "$_gh_token" ]] && command -v gh >/dev/null 2>&1; then
      _gh_token="$(gh auth token -h github.com 2>/dev/null)" || _gh_token=""
    fi
    # Pass the token via NIX_CONFIG (env), NOT --extra-access-tokens on the
    # command line: argv is world-readable (ps, /proc/<pid>/cmdline), so a CLI
    # token can leak into process listings and echoed logs. Passing the token via
    # NIX_CONFIG mirrors what the CI workflow already does
    # (.github/workflows/test_linux.yml); here we use the `extra-access-tokens`
    # key (which *appends*) rather than CI's `access-tokens` (which replaces) so
    # an inherited NIX_CONFIG is preserved rather than clobbered. Scoped to a
    # subshell so the token does not persist into later phases' environment.
    local _nl=$'\n'
    (
      if [[ -n "$_gh_token" ]]; then
        export NIX_CONFIG="${NIX_CONFIG:+$NIX_CONFIG$_nl}extra-access-tokens = github.com=$_gh_token"
      fi
      case "$NX_REV_MODE" in
      pinned | validated)
        _io_nix flake lock --override-input nixpkgs "github:nixos/nixpkgs/$NX_REV_SHA" "$ENV_DIR" ||
          warn "flake lock failed - using existing lock"
        ;;
      latest)
        _io_nix flake update --flake "$ENV_DIR" ||
          warn "flake update failed (network issue?) - using existing lock"
        ;;
      *)
        warn "no validated nixpkgs revision found - keeping the current lock"
        ;;
      esac
    )
  fi
}

phase_nix_profile_apply() {
  SECONDS=0
  # narHash is the flake's content hash (stable across mtime bumps). Stored
  # OUTSIDE ENV_DIR (~/.config/dev-env/, alongside install.json) so writing
  # it doesn't itself advance the path:flake's lastModified.
  local _narhash _last_narhash _cookie="$DEV_ENV_DIR/last-applied-narhash"
  _narhash="$(_io_nix flake metadata "$ENV_DIR" --json 2>/dev/null | jq -r '.locked.narHash // empty' 2>/dev/null)" || _narhash=""
  _last_narhash="$(cat "$_cookie" 2>/dev/null || true)"

  if ! _io_nix profile list --json 2>/dev/null | grep -q 'nix-env'; then
    _io_nix profile add "path:$ENV_DIR" 2>&1 ||
      {
        _ir_error="nix profile add failed"
        err "$_ir_error"
        exit 1
      }
  fi

  # Skip the upgrade only when we have positive evidence it would be a
  # no-op (narHash matches the last applied AND user didn't pass --upgrade).
  # If narHash is unavailable (jq missing, flake metadata failed) we fall
  # through to running the upgrade as before -- graceful degradation.
  if [[ -n "$_narhash" && "$_narhash" = "$_last_narhash" && "${upgrade_packages:-false}" != "true" ]]; then
    ok "nix profile already in sync (narHash unchanged) - skipped upgrade"
  else
    _io_nix profile upgrade nix-env ||
      {
        _ir_error="nix profile upgrade failed"
        err "$_ir_error"
        exit 1
      }
  fi

  if [[ -n "$_narhash" ]]; then
    mkdir -p "$DEV_ENV_DIR"
    printf '%s\n' "$_narhash" >"$_cookie"
  fi
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
        # cert_intercept now lives in .assets/lib/certs.sh (sourced above on
        # line 92), so we no longer need to drag in functions.sh wholesale -
        # which previously polluted setup environment with sysinfo() globals
        # and aliases. Idempotent re-source-of-certs.sh is unneeded; the
        # function is already in scope.
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
