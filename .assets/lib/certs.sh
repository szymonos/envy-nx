# Shared CA bundle builder for nix-installed tools.
# Compatible with bash 3.2 and zsh (sourced by nix and legacy setup paths).
#
# Usage:
#   source .assets/lib/certs.sh
#   build_ca_bundle  # creates ca-bundle.crt if ca-custom.crt exists
#
# Requires: ok() helper defined by caller (printf green line).

# Default TLS probe URL for MITM detection and cert interception.
: "${NIX_ENV_TLS_PROBE_URL:=https://www.google.com}"

# build_ca_bundle
# Creates ~/.config/certs/ca-bundle.crt as a PEM bundle for nix-installed tools.
# Only called after MITM proxy detection - when ca-custom.crt exists.
# Without interception, tools use their own optimized cert paths.
# Linux: symlinks to system CA bundle (already includes custom certs after
#        update-ca-certificates).
# macOS: exports trusted certificates from macOS Keychains (system roots +
#        admin-installed corporate/proxy certs) and appends intercepted certs.
# Idempotent: skips if ca-bundle.crt already exists.
build_ca_bundle() {
  local cert_dir="$HOME/.config/certs"
  local custom_certs="$cert_dir/ca-custom.crt"
  local bundle_link="$cert_dir/ca-bundle.crt"

  [ ! -e "$bundle_link" ] || return 0
  [ -f "$custom_certs" ] || return 0

  mkdir -p "$cert_dir"
  case "$(uname -s)" in
  Linux)
    for sys_bundle in \
      /etc/ssl/certs/ca-certificates.crt \
      /etc/pki/tls/certs/ca-bundle.crt; do
      if [ -f "$sys_bundle" ]; then
        ln -sf "$sys_bundle" "$bundle_link"
        ok "  symlinked ca-bundle.crt -> $sys_bundle"
        break
      fi
    done
    ;;
  Darwin)
    local bundle_tmp
    bundle_tmp="$(mktemp)"
    security find-certificate -a -p /System/Library/Keychains/SystemRootCertificates.keychain >"$bundle_tmp" 2>/dev/null
    security find-certificate -a -p /Library/Keychains/System.keychain >>"$bundle_tmp" 2>/dev/null
    [ -f "$custom_certs" ] && cat "$custom_certs" >>"$bundle_tmp"
    if [ -s "$bundle_tmp" ]; then
      mv -f "$bundle_tmp" "$bundle_link"
      ok "  created ca-bundle.crt from macOS Keychain + intercepted certs"
    else
      rm -f "$bundle_tmp"
    fi
    ;;
  esac
}
