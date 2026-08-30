#!/usr/bin/env bats
# Unit tests for the nixpkgs-revision ladder shared by `nx upgrade` and the
# nix_profile setup phase (.assets/lib/nx_rev.sh).
bats_require_minimum_version 1.5.0

REV_LIB="$(cd "$(dirname "$BATS_TEST_FILENAME")/../.." && pwd)/.assets/lib/nx_rev.sh"

setup() {
  TEST_DIR="$(mktemp -d)"
  ENV_DIR="$TEST_DIR/nix-env"
  mkdir -p "$ENV_DIR"
  # shellcheck source=../../.assets/lib/nx_rev.sh
  source "$REV_LIB"

  # A PATH carrying exactly the tools nx_rev.sh shells out to, minus jq, so the
  # jq-free branch can be exercised without breaking sed/grep/head themselves.
  NOJQ_BIN="$TEST_DIR/nojq-bin"
  mkdir -p "$NOJQ_BIN"
  local _t _p
  for _t in sed head grep cat; do
    _p="$(command -v "$_t")" && ln -sf "$_p" "$NOJQ_BIN/$_t"
  done
}

teardown() {
  rm -rf "$TEST_DIR"
}

_write_rev_file() {
  cat >"$ENV_DIR/nixpkgs_rev.json" <<EOF
{
  "rev": "$1",
  "lastModified": $2
}
EOF
}

_write_lock() {
  cat >"$ENV_DIR/flake.lock" <<EOF
{"nodes":{"nixpkgs":{"locked":{"lastModified":$1,"rev":"locked000"}}}}
EOF
}

# -- ladder precedence --------------------------------------------------------

@test "pin beats the validated rev" {
  echo "pinnedrev" >"$ENV_DIR/pinned_rev"
  _write_rev_file validatedrev 2000000000
  run _nx_rev_resolve "$ENV_DIR" false
  [[ "$output" == "pinned pinnedrev" ]]
}

@test "pin beats --latest" {
  echo "pinnedrev" >"$ENV_DIR/pinned_rev"
  run _nx_rev_resolve "$ENV_DIR" true
  [[ "$output" == "pinned pinnedrev" ]]
}

@test "--latest beats the validated rev" {
  _write_rev_file validatedrev 2000000000
  run _nx_rev_resolve "$ENV_DIR" true
  [[ "$output" == "latest" ]]
}

@test "validated rev is the default" {
  _write_rev_file validatedrev 2000000000
  run _nx_rev_resolve "$ENV_DIR" false
  [[ "$output" == "validated validatedrev" ]]
}

@test "no rev file resolves to none, never to HEAD" {
  run _nx_rev_resolve "$ENV_DIR" false
  [[ "$output" == "none" ]]
}

@test "an empty pin file is ignored rather than treated as a pin" {
  : >"$ENV_DIR/pinned_rev"
  _write_rev_file validatedrev 2000000000
  run _nx_rev_resolve "$ENV_DIR" false
  [[ "$output" == "validated validatedrev" ]]
}

# -- field extraction ---------------------------------------------------------

@test "rev and lastModified are read without jq" {
  _write_rev_file abcdef123 1787964612
  PATH="$NOJQ_BIN" run _nx_rev_json_field "$ENV_DIR/nixpkgs_rev.json" rev
  [[ "$output" == "abcdef123" ]]
  PATH="$NOJQ_BIN" run _nx_rev_json_field "$ENV_DIR/nixpkgs_rev.json" lastModified
  [[ "$output" == "1787964612" ]]
}

@test "a missing rev file yields an empty field rather than an error" {
  run _nx_rev_json_field "$ENV_DIR/nixpkgs_rev.json" rev
  [ "$status" -eq 0 ]
  [[ "$output" == "" ]]
}

# -- downgrade guard ----------------------------------------------------------

@test "an older candidate is a downgrade" {
  _write_lock 2000000000
  run _nx_rev_is_downgrade "$ENV_DIR" 1000000000
  [ "$status" -eq 0 ]
}

@test "a newer candidate is not a downgrade" {
  _write_lock 1000000000
  run _nx_rev_is_downgrade "$ENV_DIR" 2000000000
  [ "$status" -eq 1 ]
}

@test "an identical timestamp counts as a downgrade (nothing to do)" {
  _write_lock 1500000000
  run _nx_rev_is_downgrade "$ENV_DIR" 1500000000
  [ "$status" -eq 0 ]
}

@test "an unknown locked epoch never blocks the upgrade" {
  run _nx_rev_is_downgrade "$ENV_DIR" 1000000000
  [ "$status" -eq 1 ]
}

@test "a non-numeric candidate never blocks the upgrade" {
  _write_lock 2000000000
  run _nx_rev_is_downgrade "$ENV_DIR" "not-a-number"
  [ "$status" -eq 1 ]
}

# -- jq-free locked-epoch fallback -------------------------------------------

@test "locked epoch is read from a single-input lock without jq" {
  _write_lock 1787964612
  PATH="$NOJQ_BIN" run _nx_rev_locked_epoch "$ENV_DIR"
  [[ "$output" == "1787964612" ]]
}

@test "the jq-free fallback refuses to guess when the lock has two inputs" {
  cat >"$ENV_DIR/flake.lock" <<'EOF'
{"nodes":{
  "nixpkgs":{"locked":{"lastModified":2000000000,"rev":"a"}},
  "other":{"locked":{"lastModified":1000000000,"rev":"b"}}
}}
EOF
  # Two `lastModified` values and no jq: a sed scan cannot tell which node is
  # nixpkgs, so the fallback must return nothing rather than a wrong guess.
  PATH="$NOJQ_BIN" run _nx_rev_locked_epoch "$ENV_DIR"
  [[ "$output" == "" ]]
}
