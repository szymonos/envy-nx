#!/usr/bin/env bats
# Unit tests for .assets/lib/install_record.sh - jq fallback path.
# shellcheck disable=SC2034
bats_require_minimum_version 1.5.0

setup() {
  export _IR_ENTRY_POINT="nix"
  export _IR_SCRIPT_ROOT="$BATS_TEST_DIRNAME/../.."
  export _IR_SCOPES="shell python"
  export _IR_MODE="install"
  export _IR_PLATFORM="Linux"
  export _IR_ALLOW_UNFREE="false"
  # shellcheck source=../../.assets/lib/install_record.sh
  source "$BATS_TEST_DIRNAME/../../.assets/lib/install_record.sh"
  # override DEV_ENV_DIR after sourcing (install_record.sh sets it to ~/.config/dev-env)
  export DEV_ENV_DIR="$(mktemp -d)"
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

# -- repo_path and repo_url fields -------------------------------------------

@test "write_install_record with jq includes repo_path and repo_url" {
  if ! command -v jq &>/dev/null; then
    skip "jq not available"
  fi
  export _IR_REPO_PATH="/home/user/envy-nx"
  export _IR_REPO_URL="https://github.com/szymonos/envy-nx.git"
  write_install_record "success" "complete"
  [[ -f "$DEV_ENV_DIR/install.json" ]]
  jq -e '.repo_path == "/home/user/envy-nx"' "$DEV_ENV_DIR/install.json"
  jq -e '.repo_url == "https://github.com/szymonos/envy-nx.git"' "$DEV_ENV_DIR/install.json"
}

@test "write_install_record without jq includes repo_path and repo_url" {
  local bin_dir="$BATS_TEST_TMPDIR/bin_nojq3"
  _make_nojq_path "$bin_dir"
  local ORIG_PATH="$PATH"
  export _IR_REPO_PATH="/tmp/my-repo"
  export _IR_REPO_URL="https://github.com/example/repo.git"
  PATH="$bin_dir"
  hash -r
  write_install_record "success" "bootstrap"
  PATH="$ORIG_PATH"
  hash -r
  [[ -f "$DEV_ENV_DIR/install.json" ]]
  grep -q '"repo_path": "/tmp/my-repo"' "$DEV_ENV_DIR/install.json"
  grep -q '"repo_url": "https://github.com/example/repo.git"' "$DEV_ENV_DIR/install.json"
}

@test "write_install_record with empty repo fields writes empty strings" {
  if ! command -v jq &>/dev/null; then
    skip "jq not available"
  fi
  unset _IR_REPO_PATH
  unset _IR_REPO_URL
  write_install_record "success" "complete"
  [[ -f "$DEV_ENV_DIR/install.json" ]]
  jq -e '.repo_path == ""' "$DEV_ENV_DIR/install.json"
  jq -e '.repo_url == ""' "$DEV_ENV_DIR/install.json"
}

# -- bash_version provenance -------------------------------------------------

@test "write_install_record with jq includes bash_version (major.minor)" {
  if ! command -v jq &>/dev/null; then
    skip "jq not available"
  fi
  write_install_record "success" "complete"
  jq -e '.bash_version | test("^[0-9]+\\.[0-9]+$")' "$DEV_ENV_DIR/install.json"
  # And it should match the actually-running bash's BASH_VERSINFO.
  local expected="${BASH_VERSINFO[0]}.${BASH_VERSINFO[1]}"
  jq -e --arg v "$expected" '.bash_version == $v' "$DEV_ENV_DIR/install.json"
}

@test "write_install_record without jq includes bash_version" {
  local bin_dir="$BATS_TEST_TMPDIR/bin_nojq_bash"
  _make_nojq_path "$bin_dir"
  local ORIG_PATH="$PATH"
  PATH="$bin_dir"
  write_install_record "success" "bootstrap"
  PATH="$ORIG_PATH"
  grep -qE '"bash_version": "[0-9]+\.[0-9]+"' "$DEV_ENV_DIR/install.json"
}

# -- _ir_flush mid-run write path --------------------------------------------

@test "_ir_flush defaults status to in_progress and writes current _ir_phase" {
  if ! command -v jq &>/dev/null; then
    skip "jq not available"
  fi
  _ir_phase="resolving_scopes"
  _ir_flush
  [[ -f "$DEV_ENV_DIR/install.json" ]]
  jq -e '.status == "in_progress"' "$DEV_ENV_DIR/install.json"
  jq -e '.phase == "resolving_scopes"' "$DEV_ENV_DIR/install.json"
}

@test "_ir_flush honors explicit status argument" {
  if ! command -v jq &>/dev/null; then
    skip "jq not available"
  fi
  _ir_phase="bootstrap"
  _ir_flush "in_progress" ""
  jq -e '.status == "in_progress"' "$DEV_ENV_DIR/install.json"
}

@test "_ir_flush is a no-op when _ir_skip=true" {
  _ir_skip=true
  _ir_phase="bootstrap"
  _ir_flush
  [ ! -f "$DEV_ENV_DIR/install.json" ]
}

@test "_ir_flush reuses installed_at across multiple calls (stable timestamp)" {
  if ! command -v jq &>/dev/null; then
    skip "jq not available"
  fi
  unset _IR_INSTALLED_AT
  _ir_phase="bootstrap"
  _ir_flush
  local first
  first="$(jq -r '.installed_at' "$DEV_ENV_DIR/install.json")"
  # Force enough wall-clock to elapse that a regenerated timestamp would
  # differ at second resolution. 1.1s is >= the ISO-8601 second tick so
  # any code path that calls `date` again will produce a new value.
  sleep 1.1
  _ir_phase="profiles"
  _ir_flush
  local second
  second="$(jq -r '.installed_at' "$DEV_ENV_DIR/install.json")"
  [ "$first" = "$second" ]
}

@test "_ir_flush followed by write_install_record (final) preserves installed_at" {
  if ! command -v jq &>/dev/null; then
    skip "jq not available"
  fi
  unset _IR_INSTALLED_AT
  _ir_phase="bootstrap"
  _ir_flush
  local mid
  mid="$(jq -r '.installed_at' "$DEV_ENV_DIR/install.json")"
  sleep 1.1
  write_install_record "success" "complete"
  local final
  final="$(jq -r '.installed_at' "$DEV_ENV_DIR/install.json")"
  [ "$mid" = "$final" ]
  jq -e '.status == "success"' "$DEV_ENV_DIR/install.json"
  jq -e '.phase == "complete"' "$DEV_ENV_DIR/install.json"
}
