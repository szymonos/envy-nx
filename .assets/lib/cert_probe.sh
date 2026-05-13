# Mozilla-pinned TLS probe.
# Single source of truth for the openssl-based MITM detection probe used by:
#   - .assets/lib/nx_doctor.sh    (_check_cert_bundle)
#   - nix/lib/io.sh               (_io_curl_probe_pinned)
#
# Compatible with bash 3.2 and zsh.
# No external dependencies beyond openssl (already a hard dep): no helpers.sh,
# no io.sh. Preserves nx_doctor.sh's standalone-after-install constraint
# (ARCHITECTURE.md §5).
#
# Why openssl s_client -CAfile (not curl --cacert):
#   1. macOS: system curl uses Apple's Secure Transport TLS backend, which
#      silently ignores --cacert and always consults the Keychain. The probe
#      always trusts admin-installed MITM certs and skips cert_intercept.
#   2. Debian: curl/OpenSSL is ADDITIVE with --cacert and SSL_CERT_FILE /
#      NIX_SSL_CERT_FILE - both files load into the trust store, so the
#      inherited env vars (set by the managed env block, pointing at a
#      system-store-symlinked bundle that already trusts MITM) silently
#      re-add the proxy cert and defeat the probe.
# `openssl s_client -CAfile` is the same code path on every platform: it
# uses ONLY the file specified and ignores SSL_CERT_FILE / SSL_CERT_DIR.

# _cert_probe_pinned <url> <mozilla_bundle>
# Returns 0 if TLS connection to <url> verifies against <mozilla_bundle>
# alone (no MITM); returns non-zero on cert verification failure or any
# other openssl-side error.
#
# `</dev/null` (not the previous `echo | ... </dev/null`) feeds empty stdin -
# the redundant pipe-then-redirect produced a "write error: Broken pipe"
# line in CI logs from the orphan echo.
_cert_probe_pinned() {
  local _url="$1" _bundle="$2"
  local _host="${_url#https://}"
  _host="${_host#http://}"
  _host="${_host%%/*}"
  openssl s_client -CAfile "$_bundle" -connect "${_host}:443" \
    -servername "$_host" -verify_return_error </dev/null >/dev/null 2>&1
}
