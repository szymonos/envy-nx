#!/usr/bin/env bats
# Unit tests for nix/configure/playwright.sh - which CLI version it installs,
# and that macOS downloads its own Chromium.
bats_require_minimum_version 1.5.0

setup() {
  TEST_DIR="$(mktemp -d)"
  export HOME="$TEST_DIR"
  SCRIPT="$(cd "$BATS_TEST_DIRNAME/../.." && pwd)/nix/configure/playwright.sh"
  export CALLS="$TEST_DIR/calls"

  STUB_BIN="$TEST_DIR/bin"
  TOOL_BIN="$TEST_DIR/tools"
  mkdir -p "$STUB_BIN" "$TOOL_BIN"
  export TOOL_BIN
  cat >"$STUB_BIN/uv" <<'STUB'
#!/usr/bin/env bash
[ "$*" = "tool dir --bin" ] && { printf '%s\n' "$TOOL_BIN"; exit 0; }
printf 'uv %s\n' "$*" >>"$CALLS"
STUB
  cat >"$TOOL_BIN/playwright" <<'STUB'
#!/usr/bin/env bash
printf 'playwright %s\n' "$*" >>"$CALLS"
STUB
  chmod +x "$STUB_BIN/uv" "$TOOL_BIN/playwright"
  export PATH="$STUB_BIN:$PATH"
}

teardown() {
  rm -rf "$TEST_DIR"
}

_uname() {
  printf '#!/usr/bin/env bash\necho %s\n' "$1" >"$STUB_BIN/uname"
  chmod +x "$STUB_BIN/uname"
}

@test "linux: pins the CLI to the nix browsers' version" {
  _uname Linux
  mkdir -p "$HOME/.nix-profile/share"
  printf '1.61.0\n' >"$HOME/.nix-profile/share/playwright-browsers.version"
  run bash "$SCRIPT"
  [ "$status" -eq 0 ]
  grep -qx 'uv tool install --quiet --upgrade playwright==1.61.0' "$CALLS"
  ! grep -q '^playwright install' "$CALLS"
}

@test "macos: installs the latest CLI and downloads Chromium" {
  _uname Darwin
  run bash "$SCRIPT"
  [ "$status" -eq 0 ]
  grep -qx 'uv tool install --quiet --upgrade playwright' "$CALLS"
  grep -qx 'playwright install chromium' "$CALLS"
}
