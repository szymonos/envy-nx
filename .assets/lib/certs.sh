# Shared CA bundle builder for nix-installed tools.
# Compatible with bash 3.2 and zsh (sourced by nix and legacy setup paths).
#
# Functions:
#   build_ca_bundle              -- (re)build ~/.config/certs/ca-bundle.crt
#   merge_local_certs <src_dir>  -- append <src_dir>/*.crt to ca-custom.crt
#                                   (serial-based dedup; no-op when src absent)
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

# Append every cert under <src_dir>/*.crt to ~/.config/certs/ca-custom.crt,
# skipping any cert whose serial already appears in the bundle. Why serial-
# based dedup: cert_intercept and the WSL pre-step (wsl_certs_add.ps1) write
# entries with the same `# serial=` header format and same uppercase-hex
# serials, so a cert added by either path is recognized as already-present
# by every other path on subsequent runs.
#
# No-op when <src_dir> is empty/missing or openssl is unavailable.
# Idempotent: re-running once everything is merged is silent.
merge_local_certs() {
  local src_dir="${1:-}"
  [ -n "$src_dir" ] || return 0
  [ -d "$src_dir" ] || return 0
  type openssl >/dev/null 2>&1 || {
    printf '\e[33mopenssl unavailable; skipping local cert merge.\e[0m\n' >&2
    return 0
  }

  local cert_bundle="$HOME/.config/certs/ca-custom.crt"
  mkdir -p "$HOME/.config/certs"

  # PEM-walk (not `openssl storeutl -text`): storeutl emits
  # `<decimal> (0x<lowercase-hex>)`, which can't substring-match the
  # uppercase-hex format `openssl x509 -serial` produces -- the format used
  # by every other path here (cert_intercept, our per-cert append below,
  # the WSL fork's ConvertTo-PEM headers). Walking PEM blocks normalizes
  # the format end-to-end so cross-run dedup actually works.
  local _existing_serials=" "
  if [ -f "$cert_bundle" ]; then
    local _current=""
    while IFS= read -r line; do
      if [[ "$line" == "-----BEGIN CERTIFICATE-----" ]]; then
        _current="$line"
      elif [[ "$line" == "-----END CERTIFICATE-----" ]]; then
        _current+=$'\n'"$line"
        local _ser
        _ser=$(openssl x509 -noout -serial <<<"$_current" 2>/dev/null | cut -d= -f2)
        [ -n "$_ser" ] && _existing_serials+="$_ser "
        _current=""
      elif [[ -n "$_current" ]]; then
        _current+=$'\n'"$line"
      fi
    done <"$cert_bundle"
  fi

  local added=0 skipped=0 src_cert serial header pem
  # find instead of glob: empty dir doesn't error, and zsh nomatch can't bite.
  while IFS= read -r src_cert; do
    [ -n "$src_cert" ] || continue
    serial=$(openssl x509 -in "$src_cert" -noout -serial -nameopt RFC2253 2>/dev/null | cut -d= -f2)
    if [ -z "$serial" ]; then
      printf '\e[33mskipping unreadable cert: %s\e[0m\n' "$src_cert" >&2
      continue
    fi
    if [[ " $_existing_serials " == *" $serial "* ]]; then
      skipped=$((skipped + 1))
      continue
    fi
    header=$(openssl x509 -in "$src_cert" -noout -issuer -subject -serial -fingerprint -nameopt RFC2253 2>/dev/null | sed 's/\\//g' | xargs -I {} echo "# {}")
    pem=$(openssl x509 -in "$src_cert" -outform PEM 2>/dev/null)
    printf '%s\n%s\n' "$header" "$pem" >>"$cert_bundle"
    _existing_serials+="$serial "
    added=$((added + 1))
    printf ' \e[32m+ %s\e[0m\n' "$(openssl x509 -in "$src_cert" -noout -subject -nameopt RFC2253 2>/dev/null | sed 's/\\//g')" >&2
  done < <(find "$src_dir" -maxdepth 1 -type f -name '*.crt' 2>/dev/null | sort)

  if [ $added -gt 0 ]; then
    printf '\e[34mmerged %d local certificate(s) into %s\e[0m\n' "$added" "${cert_bundle/$HOME/\~}" >&2
  fi
  if [ $skipped -gt 0 ]; then
    printf '\e[90m(%d already present, skipped)\e[0m\n' "$skipped" >&2
  fi
  return 0
}
