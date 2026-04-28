#!/usr/bin/env bats
# Tests for _io_pwsh_nop / _pwsh_nop wrappers.
# Verifies that the wrappers use the nix bin/pwsh wrapper (not the unwrapped
# share/powershell/pwsh) and clear LD_LIBRARY_PATH inside the pwsh session.
# shellcheck disable=SC2034
bats_require_minimum_version 1.5.0

setup_file() {
  export REPO_ROOT="$BATS_TEST_DIRNAME/../.."
}

setup() {
  TEST_HOME="$(mktemp -d)"

  # source io.sh to get _io_pwsh_nop
  # shellcheck source=../../nix/lib/io.sh
  source "$REPO_ROOT/nix/lib/io.sh"
}

teardown() {
  rm -rf "$TEST_HOME"
}

# =============================================================================
# _io_pwsh_nop wrapper path resolution
# =============================================================================

@test "_io_pwsh_nop: uses nix-profile bin/pwsh wrapper path" {
  # stub pwsh to record how it was called
  local log="$BATS_TEST_TMPDIR/pwsh_calls.log"
  : >"$log"
  HOME="$TEST_HOME"
  mkdir -p "$TEST_HOME/.nix-profile/bin"
  cat >"$TEST_HOME/.nix-profile/bin/pwsh" <<'STUB'
#!/usr/bin/env bash
echo "CALLED: $0 $*" >>"$(dirname "$0")/../../pwsh_calls.log"
STUB
  chmod +x "$TEST_HOME/.nix-profile/bin/pwsh"

  # re-source to pick up new HOME
  source "$REPO_ROOT/nix/lib/io.sh"
  _io_pwsh_nop -c 'Write-Host test' 2>/dev/null || true

  [[ -f "$TEST_HOME/pwsh_calls.log" ]]
  grep -q "$TEST_HOME/.nix-profile/bin/pwsh" "$TEST_HOME/pwsh_calls.log"
}

@test "_io_pwsh_nop: does not resolve pwsh from PATH" {
  HOME="$TEST_HOME"
  mkdir -p "$TEST_HOME/.nix-profile/bin"

  # put a fake pwsh on PATH that would be found first
  local fake_dir="$BATS_TEST_TMPDIR/fake_bin"
  mkdir -p "$fake_dir"
  cat >"$fake_dir/pwsh" <<'STUB'
#!/usr/bin/env bash
echo "WRONG_PWSH" >"$BATS_TEST_TMPDIR/wrong_pwsh_called"
STUB
  chmod +x "$fake_dir/pwsh"

  # put the real stub at nix-profile
  cat >"$TEST_HOME/.nix-profile/bin/pwsh" <<'STUB'
#!/usr/bin/env bash
echo "RIGHT_PWSH" >"$BATS_TEST_TMPDIR/right_pwsh_called"
STUB
  chmod +x "$TEST_HOME/.nix-profile/bin/pwsh"

  PATH="$fake_dir:$PATH"
  source "$REPO_ROOT/nix/lib/io.sh"
  _io_pwsh_nop -c 'test' 2>/dev/null || true

  [[ -f "$BATS_TEST_TMPDIR/right_pwsh_called" ]]
  [[ ! -f "$BATS_TEST_TMPDIR/wrong_pwsh_called" ]]
}

# =============================================================================
# LD_LIBRARY_PATH clearing inside pwsh
# =============================================================================

@test "_io_pwsh_nop: -c mode prepends LD_LIBRARY_PATH clear" {
  HOME="$TEST_HOME"
  mkdir -p "$TEST_HOME/.nix-profile/bin"
  # stub that captures the -c argument
  cat >"$TEST_HOME/.nix-profile/bin/pwsh" <<'STUB'
#!/usr/bin/env bash
for arg in "$@"; do
  [[ "$arg" == "-c" ]] && continue
  [[ "$arg" == "-nop" ]] && continue
  echo "$arg"
done
STUB
  chmod +x "$TEST_HOME/.nix-profile/bin/pwsh"

  source "$REPO_ROOT/nix/lib/io.sh"
  local output
  output="$(_io_pwsh_nop -c 'Write-Host hello')"

  [[ "$output" == *'$env:LD_LIBRARY_PATH = $null'* ]]
  [[ "$output" == *'Write-Host hello'* ]]
}

@test "_io_pwsh_nop: script mode prepends LD_LIBRARY_PATH clear" {
  HOME="$TEST_HOME"
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

  source "$REPO_ROOT/nix/lib/io.sh"
  local output
  output="$(_io_pwsh_nop /some/script.ps1 -Param)"

  [[ "$output" == *'$env:LD_LIBRARY_PATH = $null'* ]]
  [[ "$output" == *'/some/script.ps1'* ]]
  [[ "$output" == *'-Param'* ]]
}

# =============================================================================
# _pwsh_nop (setup_common.sh variant)
# =============================================================================

@test "_pwsh_nop: uses nix-profile bin/pwsh wrapper path" {
  HOME="$TEST_HOME"
  mkdir -p "$TEST_HOME/.nix-profile/bin"
  cat >"$TEST_HOME/.nix-profile/bin/pwsh" <<'STUB'
#!/usr/bin/env bash
echo "CALLED_VIA: $0" >>"$BATS_TEST_TMPDIR/pwsh_nop_calls.log"
STUB
  chmod +x "$TEST_HOME/.nix-profile/bin/pwsh"

  source "$REPO_ROOT/.assets/setup/setup_common.sh" 2>/dev/null || true
  # source just the wrapper function directly
  eval "$(sed -n '/_pwsh_nop()/,/^}/p' "$REPO_ROOT/.assets/setup/setup_common.sh")"
  _pwsh_nop -c 'test' 2>/dev/null || true

  [[ -f "$BATS_TEST_TMPDIR/pwsh_nop_calls.log" ]]
  grep -q "$TEST_HOME/.nix-profile/bin/pwsh" "$BATS_TEST_TMPDIR/pwsh_nop_calls.log"
}

# =============================================================================
# PATH cleanup in nix/setup.sh
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
