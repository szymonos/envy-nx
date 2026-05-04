# Shared CA bundle builder for nix-installed tools.
# Compatible with bash 3.2 and zsh (sourced by nix and legacy setup paths).
#
# Usage:
#   source .assets/lib/certs.sh
#   build_ca_bundle  # always (re)builds ca-bundle.crt
#
# Requires: ok() helper defined by caller (printf green line).

# Default TLS probe URL for MITM detection and cert interception.
: "${NIX_ENV_TLS_PROBE_URL:=https://www.google.com}"

# build_ca_bundle
# Always (re)creates ~/.config/certs/ca-bundle.crt as the full trust store
# for nix-installed tools. Independent of MITM detection: ca-bundle.crt is
# the "everything nix tools should trust" file; ca-custom.crt is the
# "extra certs for tools that already trust the system store" file (used by
# NODE_EXTRA_CA_CERTS). Decoupling them means a missing ca-custom.crt no
# longer skips bundle creation, and an existing bundle no longer hides a
# stale state from later steps.
#
# Linux: symlinks to system CA bundle (already includes custom certs after
#        update-ca-certificates). `ln -sf` is idempotent.
# macOS: exports trusted certificates from macOS Keychains (system roots +
#        admin-installed corporate/proxy certs) and appends ca-custom.crt
#        when present. Atomic via mktemp + mv.
build_ca_bundle() {
  local cert_dir="$HOME/.config/certs"
  local custom_certs="$cert_dir/ca-custom.crt"
  local bundle_link="$cert_dir/ca-bundle.crt"

  mkdir -p "$cert_dir"
  case "$(uname -s)" in
  Linux)
    local sys_bundle
    for sys_bundle in \
      /etc/ssl/certs/ca-certificates.crt \
      /etc/pki/tls/certs/ca-bundle.crt; do
      if [ -f "$sys_bundle" ]; then
        ln -sf "$sys_bundle" "$bundle_link"
        ok "  ca-bundle.crt -> $sys_bundle"
        return 0
      fi
    done
    ;;
  Darwin)
    local bundle_tmp _src_msg
    bundle_tmp="$(mktemp)"
    security find-certificate -a -p /System/Library/Keychains/SystemRootCertificates.keychain >"$bundle_tmp" 2>/dev/null
    security find-certificate -a -p /Library/Keychains/System.keychain >>"$bundle_tmp" 2>/dev/null
    _src_msg="macOS Keychain"
    if [ -f "$custom_certs" ]; then
      cat "$custom_certs" >>"$bundle_tmp"
      _src_msg="$_src_msg + ca-custom.crt"
    fi
    if [ -s "$bundle_tmp" ]; then
      # Replace any prior file or stale symlink atomically.
      [ -L "$bundle_link" ] && rm -f "$bundle_link"
      mv -f "$bundle_tmp" "$bundle_link"
      ok "  ca-bundle.crt rebuilt from $_src_msg"
    else
      rm -f "$bundle_tmp"
    fi
    ;;
  esac
}
