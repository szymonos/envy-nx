#!/usr/bin/env bats
# Tests for _io_pwsh_nop wrapper (in .assets/lib/helpers.sh).
# Verifies that the wrapper prefers the nix bin/pwsh wrapper, clears
# LD_LIBRARY_PATH inside the nix-pwsh session, and falls back to system
# pwsh (no LD_LIBRARY_PATH dance) when nix-pwsh is not installed.
# shellcheck disable=SC2034
bats_require_minimum_version 1.5.0

setup_file() {
  export REPO_ROOT="$BATS_TEST_DIRNAME/../.."
}

setup() {
  TEST_HOME="$(mktemp -d)"
  HOME="$TEST_HOME"
  # shellcheck source=../../.assets/lib/helpers.sh
  source "$REPO_ROOT/.assets/lib/helpers.sh"
}

teardown() {
  rm -rf "$TEST_HOME"
}

# =============================================================================
# nix-pwsh path resolution
# =============================================================================

@test "_io_pwsh_nop: uses nix-profile bin/pwsh wrapper path" {
  mkdir -p "$TEST_HOME/.nix-profile/bin"
  cat >"$TEST_HOME/.nix-profile/bin/pwsh" <<'STUB'
#!/usr/bin/env bash
echo "CALLED: $0 $*" >>"$(dirname "$0")/../../pwsh_calls.log"
STUB
  chmod +x "$TEST_HOME/.nix-profile/bin/pwsh"

  _io_pwsh_nop -c 'Write-Host test' 2>/dev/null || true

  [[ -f "$TEST_HOME/pwsh_calls.log" ]]
  grep -q "$TEST_HOME/.nix-profile/bin/pwsh" "$TEST_HOME/pwsh_calls.log"
}

@test "_io_pwsh_nop: prefers nix-profile pwsh over PATH-resolvable pwsh" {
  mkdir -p "$TEST_HOME/.nix-profile/bin"

  # put a fake pwsh on PATH that would be found first
  local fake_dir="$BATS_TEST_TMPDIR/fake_bin"
  mkdir -p "$fake_dir"
  cat >"$fake_dir/pwsh" <<'STUB'
#!/usr/bin/env bash
echo "WRONG_PWSH" >"$BATS_TEST_TMPDIR/wrong_pwsh_called"
STUB
  chmod +x "$fake_dir/pwsh"

  cat >"$TEST_HOME/.nix-profile/bin/pwsh" <<'STUB'
#!/usr/bin/env bash
echo "RIGHT_PWSH" >"$BATS_TEST_TMPDIR/right_pwsh_called"
STUB
  chmod +x "$TEST_HOME/.nix-profile/bin/pwsh"

  PATH="$fake_dir:$PATH"
  _io_pwsh_nop -c 'test' 2>/dev/null || true

  [[ -f "$BATS_TEST_TMPDIR/right_pwsh_called" ]]
  [[ ! -f "$BATS_TEST_TMPDIR/wrong_pwsh_called" ]]
}

# =============================================================================
# LD_LIBRARY_PATH clearing inside nix-pwsh
# =============================================================================

@test "_io_pwsh_nop: -c mode prepends LD_LIBRARY_PATH clear (nix-pwsh)" {
  mkdir -p "$TEST_HOME/.nix-profile/bin"
  cat >"$TEST_HOME/.nix-profile/bin/pwsh" <<'STUB'
#!/usr/bin/env bash
for arg in "$@"; do
  [[ "$arg" == "-c" ]] && continue
  [[ "$arg" == "-nop" ]] && continue
  echo "$arg"
done
STUB
  chmod +x "$TEST_HOME/.nix-profile/bin/pwsh"

  local output
  output="$(_io_pwsh_nop -c 'Write-Host hello')"

  [[ "$output" == *'$env:LD_LIBRARY_PATH = $null'* ]]
  [[ "$output" == *'Write-Host hello'* ]]
}

@test "_io_pwsh_nop: script mode prepends LD_LIBRARY_PATH clear (nix-pwsh)" {
  mkdir -p "$TEST_HOME/.nix-profile/bin"
  cat >"$TEST_HOME/.nix-profile/bin/pwsh" <<'STUB'
#!/usr/bin/env bash
for arg in "$@"; do
  [[ "$arg" == "-c" ]] && continue
  [[ "$arg" == "-nop" ]] && continue
  echo "$arg"
done
STUB
  chmod +x "$TEST_HOME/.nix-profile/bin/pwsh"

  local output
  output="$(_io_pwsh_nop /some/script.ps1 -Param)"

  [[ "$output" == *'$env:LD_LIBRARY_PATH = $null'* ]]
  [[ "$output" == *'/some/script.ps1'* ]]
  [[ "$output" == *'-Param'* ]]
}

# =============================================================================
# System-pwsh fallback (no nix-profile pwsh installed)
# =============================================================================

@test "_io_pwsh_nop: falls back to system pwsh when nix-profile pwsh missing" {
  # No ~/.nix-profile/bin/pwsh. Stage a fake "system" pwsh on PATH.
  local fake_dir="$BATS_TEST_TMPDIR/system_bin"
  mkdir -p "$fake_dir"
  cat >"$fake_dir/pwsh" <<'STUB'
#!/usr/bin/env bash
echo "CALLED: $0" >>"$BATS_TEST_TMPDIR/system_pwsh.log"
STUB
  chmod +x "$fake_dir/pwsh"

  PATH="$fake_dir:$PATH"
  _io_pwsh_nop -c 'test' 2>/dev/null || true

  [[ -f "$BATS_TEST_TMPDIR/system_pwsh.log" ]]
  grep -q "$fake_dir/pwsh" "$BATS_TEST_TMPDIR/system_pwsh.log"
}

@test "_io_pwsh_nop: system-pwsh fallback omits LD_LIBRARY_PATH prefix" {
  local fake_dir="$BATS_TEST_TMPDIR/system_bin"
  mkdir -p "$fake_dir"
  cat >"$fake_dir/pwsh" <<'STUB'
#!/usr/bin/env bash
for arg in "$@"; do
  [[ "$arg" == "-c" ]] && continue
  [[ "$arg" == "-nop" ]] && continue
  echo "$arg"
done
STUB
  chmod +x "$fake_dir/pwsh"

  PATH="$fake_dir:$PATH"
  local output
  output="$(_io_pwsh_nop -c 'Write-Host hello')"

  [[ "$output" != *'LD_LIBRARY_PATH'* ]]
  [[ "$output" == *'Write-Host hello'* ]]
}

@test "_io_pwsh_nop: returns 1 with clear error when no pwsh anywhere" {
  # No nix-profile pwsh and an empty bin dir on PATH so command -v finds nothing.
  # We keep the rest of PATH empty (not unset) so teardown's `rm` can still
  # resolve via bash's command hash from setup.
  local empty_dir="$BATS_TEST_TMPDIR/empty_bin"
  mkdir -p "$empty_dir"
  local saved_path="$PATH"
  PATH="$empty_dir"
  run _io_pwsh_nop -c 'test'
  PATH="$saved_path"

  [[ "$status" -ne 0 ]]
  [[ "$output" == *"pwsh not found"* ]]
}

# =============================================================================
# setup_common.sh sources helpers.sh and gets _io_pwsh_nop
# =============================================================================

@test "setup_common.sh: sources helpers.sh and exposes _io_pwsh_nop" {
  # Verify the source line is present and resolves to a real file.
  grep -q 'source "\$SCRIPT_ROOT/.assets/lib/helpers.sh"' "$REPO_ROOT/.assets/setup/setup_common.sh"
  [[ -f "$REPO_ROOT/.assets/lib/helpers.sh" ]]
  # And that helpers.sh actually defines the wrapper.
  grep -Eq '^_io_pwsh_nop\(\)' "$REPO_ROOT/.assets/lib/helpers.sh"
}

# =============================================================================
# PATH cleanup in nix/setup.sh (regression coverage for share/powershell strip)
# =============================================================================

@test "setup.sh: strips share/powershell from PATH" {
  local original_path="/usr/bin:/nix/store/abc-powershell-7.6.0/share/powershell:/home/user/.nix-profile/bin:/usr/local/bin"
  local cleaned
  cleaned="$(printf '%s' "$original_path" | tr ':' '\n' | grep -v '/share/powershell$' | tr '\n' ':')"
  cleaned="${cleaned%:}"

  [[ "$cleaned" != *"share/powershell"* ]]
  [[ "$cleaned" == *"/usr/bin"* ]]
  [[ "$cleaned" == *".nix-profile/bin"* ]]
  [[ "$cleaned" == *"/usr/local/bin"* ]]
}

@test "setup.sh: PATH unchanged when no share/powershell present" {
  local original_path="/usr/bin:/home/user/.nix-profile/bin:/usr/local/bin"
  local cleaned
  cleaned="$(printf '%s' "$original_path" | tr ':' '\n' | grep -v '/share/powershell$' | tr '\n' ':')"
  cleaned="${cleaned%:}"

  [[ "$cleaned" == "$original_path" ]]
}
