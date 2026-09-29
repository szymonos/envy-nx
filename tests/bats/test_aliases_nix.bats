#!/usr/bin/env bats
# Unit tests for .assets/config/shell_cfg/aliases_nix.sh - flag-adding aliases
# of existing commands must not reach agent (non-TTY / CLAUDECODE) shells.
bats_require_minimum_version 1.5.0

setup() {
  ALIASES="$BATS_TEST_DIRNAME/../../.assets/config/shell_cfg/aliases_nix.sh"
  export HOME="$BATS_TEST_TMPDIR"
  # Fake nix-profile tools so the tool-guarded aliases would be defined.
  mkdir -p "$HOME/.nix-profile/bin"
  printf '#!/bin/sh\n' >"$HOME/.nix-profile/bin/rg"
  chmod +x "$HOME/.nix-profile/bin/rg"
  unset CLAUDECODE AI_AGENT
  PROBE="source '$ALIASES'; alias cp; alias rg; alias ll"
}

# Run PROBE under a pseudo-terminal; BSD and util-linux `script` differ.
_run_on_tty() {
  command -v script >/dev/null || skip "script(1) not available"
  if [ "$(uname -s)" = Darwin ]; then
    run script -q /dev/null bash -c "$PROBE"
  else
    run script -qec "bash -c \"$PROBE\"" /dev/null
  fi
}

@test "non-TTY shell gets no flag-adding aliases" {
  run bash -c "$PROBE" </dev/null
  [[ "$output" != *"cp -iv"* ]]
  [[ "$output" != *"rg --ignore-case"* ]]
  # New names are not gated.
  [[ "$output" == *"alias ll="* ]]
}

@test "CLAUDECODE=1 on a TTY gets no flag-adding aliases" {
  export CLAUDECODE=1
  _run_on_tty
  [[ "$output" != *"cp -iv"* ]]
  [[ "$output" != *"rg --ignore-case"* ]]
}

@test "human on a TTY gets the flag-adding aliases" {
  _run_on_tty
  [[ "$output" == *"cp -iv"* ]]
  [[ "$output" == *"rg --ignore-case"* ]]
}
