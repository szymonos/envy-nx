#!/usr/bin/env bats
# Unit tests for nix/configure/gh.sh - SSH key status and registration.
bats_require_minimum_version 1.5.0

setup() {
  TEST_DIR="$(mktemp -d)"
  export HOME="$TEST_DIR"
  unset GITHUB_TOKEN NX_SSH_KEY_FP
  SCRIPT="$(cd "$BATS_TEST_DIRNAME/../.." && pwd)/nix/configure/gh.sh"

  mkdir -p "$HOME/.ssh"
  # base64 keys contain `+` and `/`; the match must be a fixed string
  printf 'ssh-ed25519 AAAA+key/Zz test\n' >"$HOME/.ssh/id_ed25519.pub"
  : >"$HOME/.ssh/id_ed25519"
  printf 'github.com ssh-ed25519 AAAA\n' >"$HOME/.ssh/known_hosts"

  STUB_BIN="$TEST_DIR/bin"
  mkdir -p "$STUB_BIN"
  # `gh ssh-key list` prints $GH_KEYS; everything else succeeds. Calls are logged.
  export GH_LOG="$TEST_DIR/gh.log"
  cat >"$STUB_BIN/gh" <<'STUB'
#!/usr/bin/env bash
printf '%s\n' "$*" >>"$GH_LOG"
[ "$1 $2" = "ssh-key list" ] && { [ -n "$GH_LIST_FAIL" ] && exit 1; printf '%s\n' "$GH_KEYS"; }
exit 0
STUB
  chmod +x "$STUB_BIN/gh"
  export PATH="$STUB_BIN:$PATH"
}

teardown() {
  rm -rf "$TEST_DIR"
}

@test "registered key is reported as registered" {
  export GH_KEYS=$'laptop\tssh-ed25519 AAAA+key/Zz\t2026-01-01'
  run bash "$SCRIPT" true
  [ "$status" -eq 0 ]
  [[ "$output" == *"SSH key already registered on GitHub"* ]]
  [[ "$output" != *"not registered"* ]]
}

@test "unattended run reports an unregistered key and never adds it" {
  export GH_KEYS=$'laptop\tssh-ed25519 BBBBother\t2026-01-01'
  run bash "$SCRIPT" true
  [ "$status" -eq 0 ]
  [[ "$output" == *"not registered with GitHub (unattended)"* ]]
  ! grep -q '^ssh-key add' "$GH_LOG"
}

@test "key list failure (missing scope) falls back to the hint" {
  export GH_LIST_FAIL=1
  run bash "$SCRIPT" true
  [ "$status" -eq 0 ]
  [[ "$output" == *"not registered with GitHub (unattended)"* ]]
}

@test "missing .pub does not abort and is not reported as registered" {
  rm "$HOME/.ssh/id_ed25519.pub"
  export GH_KEYS=$'laptop\tssh-ed25519 AAAA+key/Zz\t2026-01-01'
  run bash "$SCRIPT" true
  [ "$status" -eq 0 ]
  [[ "$output" == *"not registered with GitHub (unattended)"* ]]
  [[ "$output" != *"already registered"* ]]
}

@test "interactive run with missing .pub warns instead of matching every key" {
  rm "$HOME/.ssh/id_ed25519.pub"
  export GH_KEYS=$'laptop\tssh-ed25519 AAAA+key/Zz\t2026-01-01'
  run bash "$SCRIPT" false
  [ "$status" -eq 0 ]
  [[ "$output" == *".pub is missing"* ]]
  [[ "$output" != *"already registered"* ]]
}

@test "interactive run registers an unregistered key" {
  export GH_KEYS=$'laptop\tssh-ed25519 BBBBother\t2026-01-01'
  run bash "$SCRIPT" false </dev/null
  [ "$status" -eq 0 ]
  grep -q '^ssh-key add' "$GH_LOG"
}

@test "interactive run skips an already registered key" {
  export GH_KEYS=$'laptop\tssh-ed25519 AAAA+key/Zz\t2026-01-01'
  run bash "$SCRIPT" false </dev/null
  [ "$status" -eq 0 ]
  [[ "$output" == *"SSH key already registered on GitHub"* ]]
  ! grep -q '^ssh-key add' "$GH_LOG"
}
