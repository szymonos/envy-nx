#!/usr/bin/env bats
# Unit tests for merge_local_certs and build_ca_bundle (in .assets/lib/certs.sh).
# Verifies append-on-new + serial-based dedup against ca-custom.crt.
# shellcheck disable=SC2034
bats_require_minimum_version 1.5.0

setup_file() {
  export REPO_ROOT="$BATS_TEST_DIRNAME/../.."
}

setup() {
  if ! command -v openssl >/dev/null 2>&1; then
    skip "openssl required to generate test certs"
  fi
  TEST_HOME="$(mktemp -d)"
  HOME="$TEST_HOME"
  CERT_SRC="$BATS_TEST_TMPDIR/local_certs"
  mkdir -p "$CERT_SRC"
  # Need a stub `ok` so build_ca_bundle (sourced alongside) doesn't NPE,
  # though merge_local_certs itself doesn't call ok().
  ok() { :; }

  # shellcheck source=../../.assets/lib/certs.sh
  source "$REPO_ROOT/.assets/lib/certs.sh"
}

teardown() {
  rm -rf "$TEST_HOME"
}

# -- helpers -------------------------------------------------------------------

# Generate a self-signed EC test cert at the given path with CN=$2.
_gen_cert() {
  local path="$1" cn="$2"
  local key="$BATS_TEST_TMPDIR/.gen.key"
  openssl ecparam -name prime256v1 -genkey -noout -out "$key" 2>/dev/null
  openssl req -x509 -new -key "$key" -days 1 -subj "/CN=$cn" -out "$path" 2>/dev/null
  rm -f "$key"
}

# =============================================================================
# guard branches
# =============================================================================

@test "merge_local_certs: no-op when src dir argument is empty" {
  run merge_local_certs ""
  [[ "$status" -eq 0 ]]
  [[ ! -e "$TEST_HOME/.config/certs/ca-custom.crt" ]]
}

@test "merge_local_certs: no-op when src dir does not exist" {
  run merge_local_certs "$BATS_TEST_TMPDIR/nope"
  [[ "$status" -eq 0 ]]
  [[ ! -e "$TEST_HOME/.config/certs/ca-custom.crt" ]]
}

@test "merge_local_certs: no-op when src dir exists but is empty" {
  run merge_local_certs "$CERT_SRC"
  [[ "$status" -eq 0 ]]
  # ca-custom.crt should remain absent (or empty if mkdir touched the dir)
  if [[ -e "$TEST_HOME/.config/certs/ca-custom.crt" ]]; then
    [[ ! -s "$TEST_HOME/.config/certs/ca-custom.crt" ]]
  fi
}

# =============================================================================
# append + dedup
# =============================================================================

@test "merge_local_certs: creates ca-custom.crt and appends both new certs" {
  _gen_cert "$CERT_SRC/cert1.crt" "test-cert-1"
  _gen_cert "$CERT_SRC/cert2.crt" "test-cert-2"

  run merge_local_certs "$CERT_SRC"
  [[ "$status" -eq 0 ]]

  local bundle="$TEST_HOME/.config/certs/ca-custom.crt"
  [[ -f "$bundle" ]]
  # Two -----BEGIN CERTIFICATE----- markers expected.
  local count
  count=$(grep -c -- '-----BEGIN CERTIFICATE-----' "$bundle")
  [[ "$count" -eq 2 ]]
  grep -q 'CN=test-cert-1' "$bundle"
  grep -q 'CN=test-cert-2' "$bundle"
}

@test "merge_local_certs: skips certs whose serial already in bundle (dedup)" {
  _gen_cert "$CERT_SRC/cert1.crt" "test-cert-1"
  _gen_cert "$CERT_SRC/cert2.crt" "test-cert-2"

  # First merge -> writes both.
  merge_local_certs "$CERT_SRC" 2>/dev/null
  local bundle="$TEST_HOME/.config/certs/ca-custom.crt"
  local size_first
  size_first=$(wc -c <"$bundle")

  # Second merge -> both serials already present, must be a no-op.
  merge_local_certs "$CERT_SRC" 2>/dev/null
  local size_second
  size_second=$(wc -c <"$bundle")
  [[ "$size_first" -eq "$size_second" ]]

  # Still exactly two cert blocks.
  local count
  count=$(grep -c -- '-----BEGIN CERTIFICATE-----' "$bundle")
  [[ "$count" -eq 2 ]]
}

@test "merge_local_certs: appends only the new cert when bundle has one already" {
  _gen_cert "$CERT_SRC/cert1.crt" "test-cert-1"
  merge_local_certs "$CERT_SRC" 2>/dev/null

  # Add a second cert and re-run.
  _gen_cert "$CERT_SRC/cert2.crt" "test-cert-2"
  merge_local_certs "$CERT_SRC" 2>/dev/null

  local bundle="$TEST_HOME/.config/certs/ca-custom.crt"
  local count
  count=$(grep -c -- '-----BEGIN CERTIFICATE-----' "$bundle")
  [[ "$count" -eq 2 ]]
  # And cert1 is still there. Extra `CN=` hits inside the PEM body depend on
  # the openssl version, so only "at least one" is portable.
  local cn1
  cn1=$(grep -c 'CN=test-cert-1' "$bundle")
  [[ "$cn1" -ge 1 ]]
}

# =============================================================================
# error paths
# =============================================================================

@test "merge_local_certs: skips unreadable .crt file with a warning" {
  # Stage a valid cert and a junk file.
  _gen_cert "$CERT_SRC/good.crt" "good-cert"
  printf 'not a cert\n' >"$CERT_SRC/junk.crt"

  run merge_local_certs "$CERT_SRC"
  [[ "$status" -eq 0 ]]
  [[ "$output" == *"skipping unreadable cert"* ]] || [[ "$output" == *"junk.crt"* ]]

  local bundle="$TEST_HOME/.config/certs/ca-custom.crt"
  local count
  count=$(grep -c -- '-----BEGIN CERTIFICATE-----' "$bundle")
  [[ "$count" -eq 1 ]]
  grep -q 'CN=good-cert' "$bundle"
}

@test "merge_local_certs: imports every cert of a chain file, CRLF included" {
  _gen_cert "$BATS_TEST_TMPDIR/a.crt" "chain-a"
  _gen_cert "$BATS_TEST_TMPDIR/b.crt" "chain-b"
  cat "$BATS_TEST_TMPDIR/a.crt" "$BATS_TEST_TMPDIR/b.crt" | sed 's/$/\r/' >"$CERT_SRC/chain.crt"

  merge_local_certs "$CERT_SRC" 2>/dev/null
  local bundle="$TEST_HOME/.config/certs/ca-custom.crt"
  [[ "$(grep -c -- '-----BEGIN CERTIFICATE-----' "$bundle")" -eq 2 ]]
  grep -q 'CN=chain-b' "$bundle"
}

@test "merge_local_certs: imports a DER-encoded cert" {
  _gen_cert "$BATS_TEST_TMPDIR/der.pem" "der-cert"
  openssl x509 -in "$BATS_TEST_TMPDIR/der.pem" -outform DER -out "$CERT_SRC/der.crt"

  merge_local_certs "$CERT_SRC" 2>/dev/null
  grep -q 'CN=der-cert' "$TEST_HOME/.config/certs/ca-custom.crt"
}

@test "merge_local_certs: unreadable cert and an apostrophe in a DN survive set -eo pipefail" {
  printf 'not a cert\n' >"$CERT_SRC/junk.crt"
  _gen_cert "$CERT_SRC/quote.crt" "O'Reilly CA"

  run bash -c 'set -eo pipefail; HOME="$1"; source "$2/.assets/lib/certs.sh"; merge_local_certs "$3"' \
    _ "$TEST_HOME" "$REPO_ROOT" "$CERT_SRC"
  [[ "$status" -eq 0 ]]
  [[ "$output" == *"skipping unreadable cert"* ]]
  grep -q "# subject=CN=O'Reilly CA" "$TEST_HOME/.config/certs/ca-custom.crt"
}

# =============================================================================
# build_ca_bundle (Darwin branch; the Linux branch probes fixed /etc paths)
# =============================================================================

@test "build_ca_bundle: Darwin bundle is Keychain + ca-custom.crt, same bytes on rerun" {
  _gen_cert "$BATS_TEST_TMPDIR/sys.crt" "sys-root"
  _gen_cert "$CERT_SRC/custom.crt" "custom-cert"
  merge_local_certs "$CERT_SRC" 2>/dev/null
  uname() { echo Darwin; }
  security() {
    [[ "$4" == *SystemRoot* ]] && cat "$BATS_TEST_TMPDIR/sys.crt"
    return 0
  }

  build_ca_bundle
  local bundle="$TEST_HOME/.config/certs/ca-bundle.crt"
  [[ ! -L "$bundle" ]]
  grep -q 'CN=custom-cert' "$bundle"
  [[ "$(grep -c -- '-----BEGIN CERTIFICATE-----' "$bundle")" -eq 2 ]]
  local first
  first="$(cat "$bundle")"
  build_ca_bundle
  [[ "$(cat "$bundle")" == "$first" ]]
}

@test "build_ca_bundle: empty Keychain export keeps the prior bundle and reports why" {
  mkdir -p "$TEST_HOME/.config/certs"
  printf 'prior\n' >"$TEST_HOME/.config/certs/ca-bundle.crt"
  uname() { echo Darwin; }
  security() {
    echo "keychain locked" >&2
    return 1
  }

  run build_ca_bundle
  [[ "$status" -eq 0 ]]
  [[ "$output" == *"previous bundle kept"* ]]
  [[ "$output" == *"keychain locked"* ]]
  [[ "$(cat "$TEST_HOME/.config/certs/ca-bundle.crt")" == "prior" ]]
}

@test "build_ca_bundle: one failed Keychain export keeps the prior bundle" {
  _gen_cert "$BATS_TEST_TMPDIR/sys.crt" "sys-root"
  mkdir -p "$TEST_HOME/.config/certs"
  printf 'prior\n' >"$TEST_HOME/.config/certs/ca-bundle.crt"
  uname() { echo Darwin; }
  security() {
    [[ "$4" == *SystemRoot* ]] && {
      cat "$BATS_TEST_TMPDIR/sys.crt"
      return 0
    }
    echo "System.keychain unreadable" >&2
    return 1
  }

  run build_ca_bundle
  [[ "$status" -eq 0 ]]
  [[ "$output" == *"System.keychain unreadable"* ]]
  [[ "$(cat "$TEST_HOME/.config/certs/ca-bundle.crt")" == "prior" ]]
}
