#!/usr/bin/env bats
# Unit tests for nix/configure/docker.sh
# Covers the Darwin arm: colima.yaml + template editing with the
# `envy-nx:certs` managed block. Linux arm has trivial branching and is
# covered by integration tests in CI.
bats_require_minimum_version 1.5.0

setup() {
  TEST_DIR="$(mktemp -d)"
  export HOME="$TEST_DIR"
  REPO_ROOT="$(cd "$BATS_TEST_DIRNAME/../.." && pwd)"
  SCRIPT="$REPO_ROOT/nix/configure/docker.sh"

  # Stub `command -v colima` (and docker) so the script enters the Darwin path
  # without depending on a real colima install. The script also calls
  # `colima template --print` and `colima status` - both stubbed below via a
  # PATH-prefixed shim dir.
  STUB_BIN="$TEST_DIR/bin"
  mkdir -p "$STUB_BIN"
  cat >"$STUB_BIN/colima" <<EOF
#!/usr/bin/env bash
case "\$1 \$2" in
  "template --print") printf '%s/.colima/_templates/default.yaml\n' "\$HOME" ;;
  "status ") exit 1 ;; # not running
  *) exit 0 ;;
esac
EOF
  chmod +x "$STUB_BIN/colima"
  printf '#!/usr/bin/env bash\nexit 0\n' >"$STUB_BIN/docker"
  chmod +x "$STUB_BIN/docker"
  export PATH="$STUB_BIN:$PATH"

  # docker.sh detects Darwin via `uname -s`. On Linux runners, force the
  # Darwin code path so the test runs identically everywhere.
  UNAME_STUB="$STUB_BIN/uname"
  cat >"$UNAME_STUB" <<'EOF'
#!/usr/bin/env bash
if [ "$1" = "-s" ]; then echo "Darwin"; else /usr/bin/uname "$@"; fi
EOF
  chmod +x "$UNAME_STUB"
}

teardown() {
  rm -rf "$TEST_DIR"
}

# Default colima.yaml scaffolding that ships with `colima start`. Includes the
# two empty top-level keys that conflict with our sentinel block if not stripped.
_seed_default_profile() {
  local target="$1"
  mkdir -p "$(dirname "$target")"
  cat >"$target" <<'EOF'
cpu: 2
disk: 100
provision: null
arch: aarch64
mounts: []
env: {}
EOF
}

@test "darwin: writes template + profile blocks on fresh install" {
  mkdir -p "$HOME/.colima/default"
  _seed_default_profile "$HOME/.colima/default/colima.yaml"

  run bash "$SCRIPT" false
  [ "$status" -eq 0 ]

  # Template gets the block (creates _templates/default.yaml from nothing)
  [ -f "$HOME/.colima/_templates/default.yaml" ]
  grep -qF '>>> envy-nx:certs >>>' "$HOME/.colima/_templates/default.yaml"
  grep -qF 'mountPoint: /mnt/envy-certs' "$HOME/.colima/_templates/default.yaml"

  # Default profile gets the block
  grep -qF '>>> envy-nx:certs >>>' "$HOME/.colima/default/colima.yaml"
  # The empty `mounts: []` and `provision: null` scaffolding lines are stripped
  # so YAML.v3 (Lima's parser) doesn't fail on duplicate top-level keys.
  run ! grep -qE '^mounts:[[:space:]]*\[\][[:space:]]*$' "$HOME/.colima/default/colima.yaml"
  run ! grep -qE '^provision:[[:space:]]*null[[:space:]]*$' "$HOME/.colima/default/colima.yaml"
}

@test "darwin: second run is idempotent (same hash, single block)" {
  mkdir -p "$HOME/.colima/default"
  _seed_default_profile "$HOME/.colima/default/colima.yaml"

  # Hash both runs and compare. Use whichever hasher is available - sha256sum
  # is the coreutils standard on Linux CI; shasum is the BSD-friendly fallback
  # on macOS. Same portability pattern as .assets/tools/build_release.sh.
  local hasher
  if command -v sha256sum >/dev/null 2>&1; then
    hasher='sha256sum'
  else
    hasher='shasum -a 256'
  fi
  bash "$SCRIPT" false
  local before
  before="$($hasher "$HOME/.colima/default/colima.yaml" | awk '{print $1}')"
  bash "$SCRIPT" false
  local after
  after="$($hasher "$HOME/.colima/default/colima.yaml" | awk '{print $1}')"
  [ "$before" = "$after" ]

  # Exactly one managed block (no duplicates from second insert path)
  run grep -cF '>>> envy-nx:certs >>>' "$HOME/.colima/default/colima.yaml"
  [ "$output" = "1" ]
}

@test "darwin: re-run replaces existing block (cert rotation)" {
  mkdir -p "$HOME/.colima/default"
  _seed_default_profile "$HOME/.colima/default/colima.yaml"
  bash "$SCRIPT" false

  # Tamper the block: change mountPoint to simulate an older version.
  sed -i.bak 's|/mnt/envy-certs|/mnt/old-path|' "$HOME/.colima/default/colima.yaml"
  rm -f "$HOME/.colima/default/colima.yaml.bak"
  grep -qF '/mnt/old-path' "$HOME/.colima/default/colima.yaml"

  # Second run restores the current block content.
  bash "$SCRIPT" false
  grep -qF '/mnt/envy-certs' "$HOME/.colima/default/colima.yaml"
  run ! grep -qF '/mnt/old-path' "$HOME/.colima/default/colima.yaml"
  run grep -cF '>>> envy-nx:certs >>>' "$HOME/.colima/default/colima.yaml"
  [ "$output" = "1" ]
}

@test "darwin: skips profile with user-customized mounts" {
  mkdir -p "$HOME/.colima/custom"
  cat >"$HOME/.colima/custom/colima.yaml" <<'EOF'
cpu: 4
mounts:
  - location: ~/my-data
    writable: true
EOF

  run bash "$SCRIPT" false
  [ "$status" -eq 0 ]
  # Warning shown, file unchanged.
  [[ "$output" == *"skipped"* ]]
  [[ "$output" == *"custom mounts"* ]]
  run cat "$HOME/.colima/custom/colima.yaml"
  [[ "$output" == *"~/my-data"* ]]
  run ! grep -qF 'envy-nx:certs' "$HOME/.colima/custom/colima.yaml"
}

@test "darwin: applies to multiple profiles independently" {
  mkdir -p "$HOME/.colima/dev" "$HOME/.colima/staging"
  _seed_default_profile "$HOME/.colima/dev/colima.yaml"
  _seed_default_profile "$HOME/.colima/staging/colima.yaml"

  run bash "$SCRIPT" false
  [ "$status" -eq 0 ]
  grep -qF '>>> envy-nx:certs >>>' "$HOME/.colima/dev/colima.yaml"
  grep -qF '>>> envy-nx:certs >>>' "$HOME/.colima/staging/colima.yaml"
}

@test "darwin: fresh install with no .colima dir writes template only" {
  [ ! -d "$HOME/.colima" ]
  run bash "$SCRIPT" false
  [ "$status" -eq 0 ]
  [ -f "$HOME/.colima/_templates/default.yaml" ]
  grep -qF '>>> envy-nx:certs >>>' "$HOME/.colima/_templates/default.yaml"
  # Hint to run `colima start` is emitted.
  [[ "$output" == *"colima start"* ]]
}

@test "darwin: skips cert provisioning when colima not on PATH" {
  rm -f "$STUB_BIN/colima"
  # Strip the real environment's PATH so a system colima can't fall through.
  # Keep STUB_BIN (for uname) and the minimum needed to run bash/sed/awk/etc.
  PATH="$STUB_BIN:/usr/bin:/bin" run bash "$SCRIPT" false
  [ "$status" -eq 0 ]
  [[ "$output" == *"colima not found"* ]]
  # No template or profile mutations happen.
  [ ! -d "$HOME/.colima/_templates" ]
}
