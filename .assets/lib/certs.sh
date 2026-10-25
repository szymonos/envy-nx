# Shared CA bundle builder for nix-installed tools.
# Compatible with bash 3.2 and zsh (sourced by nix and legacy setup paths).
#
# Functions:
#   build_ca_bundle              -- (re)build ~/.config/certs/ca-bundle.crt
#   merge_local_certs <src_dir>  -- append <src_dir>/*.crt to ca-custom.crt
#                                   (serial-based dedup; no-op when src absent)
#   cert_intercept [uri ...]     -- intercept MITM proxy certs from TLS chain
#                                   into ca-custom.crt (serial-aware dedup);
#                                   re-export from functions.sh for the
#                                   user-shell alias.
#
# Requires: openssl. Provides a fallback ok() / warn() if the caller didn't
# (so the file is also user-shell sourceable, not just setup-phase).

# Fallback log helpers - defined ONLY when the caller didn't already supply
# them (the setup phases define richer ones in nix/lib/io.sh and helpers.sh).
# Lets certs.sh be sourced from the user shell (where these aren't defined)
# without dragging in io.sh's full structured-log machinery.
type ok >/dev/null 2>&1 || ok() { printf '\e[32m%s\e[0m\n' "$*"; }
type warn >/dev/null 2>&1 || warn() { printf '\e[33m%s\e[0m\n' "$*" >&2; }

# Default TLS probe URL for MITM detection and cert interception.
: "${NIX_ENV_TLS_PROBE_URL:=https://www.google.com}"

# Emit the standard `# issuer=`/`# subject=`/`# serial=`/`# SHA1 Fingerprint=`
# header block for a single PEM cert read from stdin - the one bundle marker
# format for merge_local_certs, cert_intercept and fixcertpy (functions.sh).
#
# RFC2253 nameopt + sed strip backslash escapes so DN strings render
# readably.
_emit_cert_header() {
  openssl x509 -noout -issuer -subject -serial -fingerprint -nameopt RFC2253 2>/dev/null |
    sed -e 's/\\//g' -e 's/^/# /'
}

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
    # Probe Debian-style first (more common on dev systems and the layout
    # apt-installed ca-certificates ships); fall back to Fedora-style. On
    # dual-layout systems (some EL distros that install ca-certificates for
    # compatibility) both files contain the same system trust, so the
    # precedence is a tie-break, not a correctness choice.
    for sys_bundle in \
      /etc/ssl/certs/ca-certificates.crt \
      /etc/pki/tls/certs/ca-bundle.crt \
      /etc/ssl/ca-bundle.pem; do
      if [ -s "$sys_bundle" ]; then
        ln -sf "$sys_bundle" "$bundle_link"
        ok "  ca-bundle.crt -> $sys_bundle"
        return 0
      fi
    done
    warn "  no system CA bundle found - ca-bundle.crt not created"
    ;;
  Darwin)
    local bundle_tmp bundle_err _src_msg _kc_rc=0
    bundle_tmp="$(mktemp)"
    bundle_err="$(mktemp)"
    # A locked, corrupt, or sandbox-restricted Keychain fails the export; one
    # failed export of two must not replace a complete bundle with a partial
    # one. An empty keychain exits 0.
    security find-certificate -a -p /System/Library/Keychains/SystemRootCertificates.keychain >"$bundle_tmp" 2>>"$bundle_err" || _kc_rc=1
    security find-certificate -a -p /Library/Keychains/System.keychain >>"$bundle_tmp" 2>>"$bundle_err" || _kc_rc=1
    _src_msg="macOS Keychain"
    if [ -f "$custom_certs" ]; then
      cat "$custom_certs" >>"$bundle_tmp"
      _src_msg="$_src_msg + ca-custom.crt"
    fi
    if [ $_kc_rc -eq 0 ] && [ -s "$bundle_tmp" ]; then
      # Replace any prior file or stale symlink atomically.
      [ -L "$bundle_link" ] && rm -f "$bundle_link"
      command mv -f "$bundle_tmp" "$bundle_link"
      ok "  ca-bundle.crt rebuilt from $_src_msg"
    else
      printf '\e[31;1mca-bundle.crt rebuild from Keychain failed, previous bundle kept:\e[0m\n' >&2
      sed 's/^/  /' "$bundle_err" >&2
      rm -f "$bundle_tmp"
    fi
    rm -f "$bundle_err"
    ;;
  esac
}

# Append every cert under <src_dir>/*.crt to ~/.config/certs/ca-custom.crt,
# skipping any cert whose serial is already in the bundle. cert_intercept and
# the WSL pre-step (wsl_certs_add.ps1, via this function) dedup the same way,
# so a cert added by any path is recognized by every other path.
#
# No-op when <src_dir> is empty/missing or openssl is unavailable.
# Idempotent: re-running once everything is merged is silent.

# Extract the space-delimited serial list (" s1 s2 ") already present in a PEM
# bundle, for cross-run dedup. PEM-walk (not `openssl storeutl -text`): storeutl
# emits `<decimal> (0x<lowercase-hex>)`, which can't substring-match the
# uppercase-hex format `openssl x509 -serial` produces (the format used by every
# other path here and the WSL fork's ConvertTo-PEM headers). Walking PEM blocks
# normalizes the format end-to-end so dedup works.
_cert_bundle_serials() {
  local _bundle="$1" _serials=" " _current="" line _ser
  if [ -f "$_bundle" ]; then
    while IFS= read -r line; do
      if [[ "$line" == "-----BEGIN CERTIFICATE-----" ]]; then
        _current="$line"
      elif [[ "$line" == "-----END CERTIFICATE-----" ]]; then
        _current+=$'\n'"$line"
        _ser=$(openssl x509 -noout -serial <<<"$_current" 2>/dev/null | cut -d= -f2)
        [ -n "$_ser" ] && _serials+="$_ser "
        _current=""
      elif [[ -n "$_current" ]]; then
        _current+=$'\n'"$line"
      fi
    done <"$_bundle"
  fi
  printf '%s' "$_serials"
}

merge_local_certs() {
  local src_dir="${1:-}"
  [ -n "$src_dir" ] || return 0
  [ -d "$src_dir" ] || return 0
  type openssl >/dev/null 2>&1 || {
    # Loud RED + bold marker because one yellow line scrolls past during a
    # multi-minute setup. A user with .crt files in <src_dir> who hits this
    # ends up with a partial bundle (system store only on macOS; system
    # symlink on Linux) and no signal that their local certs were ignored.
    # A non-zero exit would be intrusive (callers run under set -e); the
    # color promotion + count of skipped certs gives a visible breadcrumb
    # without breaking idempotency.
    local _cert_count
    _cert_count=$(find "$src_dir" -maxdepth 1 -type f -name '*.crt' 2>/dev/null | wc -l | tr -d ' ')
    printf '\e[31;1mopenssl unavailable; %s local cert(s) in %s were SKIPPED.\e[0m\n' \
      "${_cert_count:-?}" "${src_dir/#$HOME/~}" >&2
    printf '\e[31m  Install openssl (it ships with the cert tooling) and re-run.\e[0m\n' >&2
    return 0
  }

  local cert_bundle="$HOME/.config/certs/ca-custom.crt"
  mkdir -p "$HOME/.config/certs"

  # serials already in the bundle (space-delimited, for cross-run dedup)
  local _existing_serials
  _existing_serials="$(_cert_bundle_serials "$cert_bundle")"

  local added=0 skipped=0 src_cert serial header pem line certs
  # find instead of glob: empty dir doesn't error, and zsh nomatch can't bite.
  while IFS= read -r src_cert; do
    [ -n "$src_cert" ] || continue
    # a .crt can hold a whole chain, and `openssl x509` reads only the first
    # cert; the pkcs7 round-trip emits every cert as LF-terminated PEM
    certs=$(openssl crl2pkcs7 -nocrl -certfile "$src_cert" 2>/dev/null |
      openssl pkcs7 -print_certs 2>/dev/null) || certs=""
    # crl2pkcs7 reads PEM only; `openssl x509` still takes a DER cert
    [[ "$certs" == *"-----BEGIN CERTIFICATE-----"* ]] ||
      certs=$(openssl x509 -in "$src_cert" 2>/dev/null) || certs=""
    if [[ "$certs" != *"-----BEGIN CERTIFICATE-----"* ]]; then
      printf '\e[33mskipping unreadable cert: %s\e[0m\n' "$src_cert" >&2
      continue
    fi
    pem=""
    while IFS= read -r line; do
      case "$line" in
      "-----BEGIN CERTIFICATE-----") pem="$line" ;;
      "-----END CERTIFICATE-----")
        pem+=$'\n'"$line"
        serial=$(openssl x509 -noout -serial <<<"$pem" 2>/dev/null | cut -d= -f2) || serial=""
        if [ -z "$serial" ]; then
          printf '\e[33mskipping unreadable cert in %s\e[0m\n' "$src_cert" >&2
        elif [[ " $_existing_serials " == *" $serial "* ]]; then
          skipped=$((skipped + 1))
        else
          header=$(_emit_cert_header <<<"$pem")
          printf '%s\n%s\n' "$header" "$pem" >>"$cert_bundle"
          _existing_serials+="$serial "
          added=$((added + 1))
          printf ' \e[32m+ %s\e[0m\n' "$(openssl x509 -noout -subject -nameopt RFC2253 <<<"$pem" 2>/dev/null | sed 's/\\//g')" >&2
        fi
        pem=""
        ;;
      *) [ -z "$pem" ] || pem+=$'\n'"$line" ;;
      esac
    done <<<"$certs"
  done < <(find "$src_dir" -maxdepth 1 -type f -name '*.crt' 2>/dev/null | sort)

  if [ $added -gt 0 ]; then
    printf '\e[34mmerged %d local certificate(s) into %s\e[0m\n' "$added" "${cert_bundle/$HOME/~}" >&2
  fi
  if [ $skipped -gt 0 ]; then
    printf '\e[90m(%d already present, skipped)\e[0m\n' "$skipped" >&2
  fi
  return 0
}

# Intercept MITM proxy certificates from the TLS chain of one or more URIs
# and append them to ~/.config/certs/ca-custom.crt with serial-aware dedup.
# The intermediate + root certs (NOT the leaf server cert) are captured.
# functions.sh re-exports it for the user-shell alias.
cert_intercept() {
  # check if openssl is available
  if ! type openssl &>/dev/null; then
    printf '\e[31mopenssl is required but not installed.\e[0m\n' >&2
    return 1
  fi

  local uris=("${@:-${NIX_ENV_TLS_PROBE_URL:-https://www.google.com}}")
  local cert_bundle="$HOME/.config/certs/ca-custom.crt"
  local cert_count=0
  local skip_count=0
  # declared once up front: zsh prints a variable re-declared by a bare `local`
  # on the second loop pass
  local uri line pem chain_pem serial header cert_pem

  # ensure cert directory exists
  mkdir -p "$HOME/.config/certs"

  # serials already in the bundle (space-delimited, for cross-run dedup)
  local _existing_serials
  _existing_serials="$(_cert_bundle_serials "$cert_bundle")"

  for uri in "${uris[@]}"; do
    # accept a URL as well as a bare host, like _cert_probe_pinned does
    uri="${uri#*://}"
    uri="${uri%%/*}"
    printf '\e[36mintercepting certificates from %s...\e[0m\n' "$uri" >&2

    # get full TLS chain
    chain_pem=$(openssl s_client -showcerts -connect "${uri}:443" </dev/null 2>/dev/null) || {
      printf '\e[33mfailed to connect to %s\e[0m\n' "$uri" >&2
      continue
    }

    # parse individual PEM blocks from chain, skip the first (leaf) cert
    local pem_blocks=()
    local current_pem=""
    local cert_index=0
    while IFS= read -r line; do
      if [[ "$line" == "-----BEGIN CERTIFICATE-----" ]]; then
        current_pem="$line"
      elif [[ "$line" == "-----END CERTIFICATE-----" ]]; then
        current_pem+=$'\n'"$line"
        cert_index=$((cert_index + 1))
        # skip the first cert (leaf/server cert)
        if [ $cert_index -gt 1 ]; then
          pem_blocks+=("$current_pem")
        fi
        current_pem=""
      elif [[ -n "$current_pem" ]]; then
        current_pem+=$'\n'"$line"
      fi
    done <<<"$chain_pem"

    # process each intermediate/root cert
    for pem in "${pem_blocks[@]}"; do
      serial=$(openssl x509 -noout -serial -nameopt RFC2253 <<<"$pem" 2>/dev/null | cut -d= -f2)
      [ -n "$serial" ] || continue

      # check for duplicate
      if [[ " $_existing_serials " == *" $serial "* ]]; then
        skip_count=$((skip_count + 1))
        continue
      fi

      # format cert with header comments and append to bundle
      header=$(_emit_cert_header <<<"$pem")
      cert_pem=$(openssl x509 -outform PEM <<<"$pem" 2>/dev/null)

      printf '%s\n%s\n' "$header" "$cert_pem" >>"$cert_bundle"
      _existing_serials+="$serial "
      cert_count=$((cert_count + 1))
      printf ' \e[32m+ %s\e[0m\n' "$(openssl x509 -noout -subject -nameopt RFC2253 <<<"$pem" 2>/dev/null | sed 's/\\//g')" >&2
    done
  done

  # print summary; on macOS ca-bundle.crt embeds ca-custom.crt, so rebuild it
  if [ $cert_count -gt 0 ]; then
    printf '\e[34madded %d certificate(s) to %s\e[0m\n' "$cert_count" "${cert_bundle/$HOME/~}" >&2
    build_ca_bundle
  else
    printf '\e[34mno new certificates to add\e[0m\n' >&2
  fi
  # `cmd && action` pattern leaves the test's exit code as the function's
  # return value when action is skipped. Caller `phase_nix_profile_mitm_probe`
  # runs under `set -e` in nix/setup.sh, so a `[ 0 -gt 0 ]` here would kill
  # the script right after a successful intercept. Use `if/fi` to keep the
  # function exit code at 0.
  if [ $skip_count -gt 0 ]; then
    printf '\e[90m(%d already existing, skipped)\e[0m\n' "$skip_count" >&2
  fi
}
