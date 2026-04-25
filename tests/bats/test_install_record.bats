#!/usr/bin/env bats
# Unit tests for .assets/lib/install_record.sh - jq fallback path.
# shellcheck disable=SC2034
bats_require_minimum_version 1.5.0

setup() {
  export DEV_ENV_DIR="$(mktemp -d)"
  export _IR_ENTRY_POINT="nix"
  export _IR_SCRIPT_ROOT="$BATS_TEST_DIRNAME/../.."
  export _IR_SCOPES="shell python"
  export _IR_MODE="install"
  export _IR_PLATFORM="Linux"
  export _IR_ALLOW_UNFREE="false"
  # shellcheck source=../../.assets/lib/install_record.sh
  source "$BATS_TEST_DIRNAME/../../.assets/lib/install_record.sh"
}

teardown() {
  PATH="$BATS_TEST_DIRNAME:$PATH"
  rm -rf "$DEV_ENV_DIR"
}

_make_nojq_path() {
  local bin_dir="$1"
  mkdir -p "$bin_dir"
  local cmd real
  for cmd in date id uname git nix python3 grep cat mkdir rm printf sed tr; do
    real="$(builtin command -v "$cmd" 2>/dev/null)" || continue
    ln -sf "$real" "$bin_dir/$cmd"
  done
}

# shellcheck disable=SC2218
@test "write_install_record with jq produces valid JSON" {
  if ! command -v jq &>/dev/null; then
    skip "jq not available"
  fi
  write_install_record "success" "complete"
  [[ -f "$DEV_ENV_DIR/install.json" ]]
  jq -e '.status == "success"' "$DEV_ENV_DIR/install.json"
  jq -e '.phase == "complete"' "$DEV_ENV_DIR/install.json"
  jq -e '.entry_point == "nix"' "$DEV_ENV_DIR/install.json"
  jq -e '.scopes | length > 0' "$DEV_ENV_DIR/install.json"
}

@test "write_install_record without jq produces valid JSON" {
  local bin_dir="$BATS_TEST_TMPDIR/bin_nojq"
  _make_nojq_path "$bin_dir"
  local ORIG_PATH="$PATH"
  PATH="$bin_dir"
  write_install_record "success" "bootstrap"
  PATH="$ORIG_PATH"
  [[ -f "$DEV_ENV_DIR/install.json" ]]
  python3 -m json.tool "$DEV_ENV_DIR/install.json" >/dev/null
  grep -q '"status": "success"' "$DEV_ENV_DIR/install.json"
  grep -q '"phase": "bootstrap"' "$DEV_ENV_DIR/install.json"
  grep -q '"entry_point": "nix"' "$DEV_ENV_DIR/install.json"
  grep -q '"platform": "Linux"' "$DEV_ENV_DIR/install.json"
}

@test "write_install_record fallback omits jq-only fields" {
  local bin_dir="$BATS_TEST_TMPDIR/bin_nojq2"
  _make_nojq_path "$bin_dir"
  local ORIG_PATH="$PATH"
  PATH="$bin_dir"
  hash -r
  write_install_record "failed" "bootstrap" "some error"
  PATH="$ORIG_PATH"
  hash -r
  [[ -f "$DEV_ENV_DIR/install.json" ]]
  run ! grep -q '"scopes":' "$DEV_ENV_DIR/install.json"
  run ! grep -q '"nix_version"' "$DEV_ENV_DIR/install.json"
  run ! grep -q '"allow_unfree"' "$DEV_ENV_DIR/install.json"
}
