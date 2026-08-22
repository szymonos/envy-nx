#!/usr/bin/env bats
# Unit tests for nix/uninstall.sh --dry-run behavior.
# shellcheck disable=SC2034  # DRY_RUN is read by _rm helper extracted from uninstall.sh
bats_require_minimum_version 1.5.0

setup() {
  TEST_HOME="$(mktemp -d)"

  # extract helpers from uninstall.sh without running arg parsing or main
  eval "$(sed -n '/^# -- Helpers/,/^# -- Parse args/{ /^# -- Parse args/d; p; }' \
    "$BATS_TEST_DIRNAME/../../nix/uninstall.sh")"
}

teardown() {
  rm -rf "$TEST_HOME"
}

@test "dry-run: _rm does not delete files" {
  local target="$TEST_HOME/keep_me.txt"
  echo "data" >"$target"
  DRY_RUN="true"
  _rm "$target"
  [[ -f "$target" ]]
}

@test "dry-run: _rm prints would-remove for existing file" {
  local target="$TEST_HOME/existing.txt"
  echo "data" >"$target"
  DRY_RUN="true"
  run _rm "$target"
  [[ "$output" == *"would remove"* ]]
  [[ "$output" == *"$target"* ]]
}

@test "dry-run: _rm prints would-remove for directory" {
  local target="$TEST_HOME/subdir"
  mkdir -p "$target"
  DRY_RUN="true"
  run _rm "$target"
  [[ "$output" == *"would remove"* ]]
}

@test "dry-run: _rm prints would-remove for symlink" {
  local real="$TEST_HOME/real.txt"
  local link="$TEST_HOME/link.txt"
  echo "data" >"$real"
  ln -s "$real" "$link"
  DRY_RUN="true"
  run _rm "$link"
  [[ "$output" == *"would remove"* ]]
  [[ -L "$link" ]]
}

@test "dry-run: _rm is silent for non-existent target" {
  DRY_RUN="true"
  run _rm "$TEST_HOME/does_not_exist"
  [[ -z "$output" ]]
}

@test "real mode: _rm deletes file" {
  local target="$TEST_HOME/delete_me.txt"
  echo "data" >"$target"
  DRY_RUN="false"
  _rm "$target"
  [[ ! -f "$target" ]]
}

@test "real mode: _rm deletes directory" {
  local target="$TEST_HOME/delete_dir"
  mkdir -p "$target"
  DRY_RUN="false"
  _rm "$target"
  [[ ! -d "$target" ]]
}

# ---------------------------------------------------------------------------
# phase 1 end-to-end (--env-only, against a throwaway HOME)
#
# The _rm tests above cover the helper in isolation; these run the real script
# so the phase-1 steps that decide *what* to delete are exercised too.
# ---------------------------------------------------------------------------

# `nix` is stubbed to a no-op: step 1h shells out to `nix profile remove
# nix-env` whenever nix resolves on PATH. The throwaway HOME already keeps it
# away from the developer's real profile, but a stub makes that unconditional
# rather than dependent on how nix resolves its profile directory.
_run_phase1() {
  mkdir -p "$TEST_HOME/bin"
  printf '#!/bin/sh\nexit 0\n' >"$TEST_HOME/bin/nix"
  chmod +x "$TEST_HOME/bin/nix"
  env HOME="$TEST_HOME" PATH="$TEST_HOME/bin:$PATH" \
    bash "$BATS_TEST_DIRNAME/../../nix/uninstall.sh" "$@"
}

_seed_caches() {
  mkdir -p "$TEST_HOME/.cache/oh-my-posh" "$TEST_HOME/.cache/powershell"
  touch "$TEST_HOME/.cache/oh-my-posh/init.bash.sh" \
    "$TEST_HOME/.cache/powershell/ModuleAnalysisCache-abc" \
    "$TEST_HOME/.cache/powershell/StartupProfileData-xyz"
}

@test "phase 1 removes shell caches that embed /nix/store paths" {
  # oh-my-posh keys its init cache on (config, shell) only, so a stale entry
  # keeps pointing at a store path phase 2 deletes; the pwsh caches break
  # PSResourceGet the same way.
  _seed_caches
  run _run_phase1 --env-only
  [ "$status" -eq 0 ]
  [ ! -e "$TEST_HOME/.cache/oh-my-posh" ]
  [ ! -e "$TEST_HOME/.cache/powershell/ModuleAnalysisCache-abc" ]
  [ ! -e "$TEST_HOME/.cache/powershell/StartupProfileData-xyz" ]
}

@test "phase 1 dry-run leaves the shell caches in place" {
  _seed_caches
  run _run_phase1 --dry-run --env-only
  [ "$status" -eq 0 ]
  [ -e "$TEST_HOME/.cache/oh-my-posh" ]
  [ -e "$TEST_HOME/.cache/powershell/ModuleAnalysisCache-abc" ]
}

@test "phase 1 removes the managed block from .bashrc" {
  printf '# mine\n# >>> nix:managed >>>\nexport A=1\n# <<< nix:managed <<<\n' \
    >"$TEST_HOME/.bashrc"
  run _run_phase1 --env-only
  [ "$status" -eq 0 ]
  run grep -c 'nix:managed' "$TEST_HOME/.bashrc"
  [ "$output" -eq 0 ]
  grep -q '# mine' "$TEST_HOME/.bashrc"
}

@test "phase 1 drops a .bash_profile that held only the macOS login shim" {
  printf '# >>> nix:bash_profile >>>\n. "$HOME/.bashrc"\n# <<< nix:bash_profile <<<\n' \
    >"$TEST_HOME/.bash_profile"
  run _run_phase1 --env-only
  [ "$status" -eq 0 ]
  [ ! -e "$TEST_HOME/.bash_profile" ]
}

@test "phase 1 keeps an empty .bash_profile it never wrote" {
  # An empty ~/.bash_profile is deliberate on macOS: bash reads the first of
  # .bash_profile/.bash_login/.profile, so an empty one suppresses .profile.
  # Deleting it because it happens to be empty would change login behavior.
  : >"$TEST_HOME/.bash_profile"
  run _run_phase1 --env-only
  [ "$status" -eq 0 ]
  [ -f "$TEST_HOME/.bash_profile" ]
}

@test "phase 1 keeps a .bash_profile that has user content of its own" {
  printf 'export MINE=1\n# >>> nix:bash_profile >>>\n. "$HOME/.bashrc"\n# <<< nix:bash_profile <<<\n' \
    >"$TEST_HOME/.bash_profile"
  run _run_phase1 --env-only
  [ "$status" -eq 0 ]
  [ -f "$TEST_HOME/.bash_profile" ]
  grep -q 'export MINE=1' "$TEST_HOME/.bash_profile"
  run grep -c 'nix:bash_profile' "$TEST_HOME/.bash_profile"
  [ "$output" -eq 0 ]
}

@test "phase 1 dry-run leaves .bash_profile untouched" {
  printf '# >>> nix:bash_profile >>>\n. "$HOME/.bashrc"\n# <<< nix:bash_profile <<<\n' \
    >"$TEST_HOME/.bash_profile"
  run _run_phase1 --dry-run --env-only
  [ "$status" -eq 0 ]
  grep -q 'nix:bash_profile' "$TEST_HOME/.bash_profile"
}
