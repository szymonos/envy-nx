#!/usr/bin/env bats
# Integration tests for nx profile subcommand and legacy cleanup during regenerate
bats_require_minimum_version 1.5.0

REPO_ROOT="$(cd "$(dirname "$BATS_TEST_FILENAME")/../.." && pwd)"
NX_SCRIPT="$REPO_ROOT/.assets/lib/nx.sh"

setup() {
  TEST_DIR="$(mktemp -d)"
  export HOME="$TEST_DIR"

  mkdir -p "$TEST_DIR/bin" "$TEST_DIR/.config/bash"
  printf '#!/bin/sh\nexit 0\n' >"$TEST_DIR/bin/nix"
  chmod +x "$TEST_DIR/bin/nix"
  export PATH="$TEST_DIR/bin:$PATH"

  # shellcheck source=../../.assets/lib/profile_block.sh
  source "$REPO_ROOT/.assets/lib/profile_block.sh"

  # shellcheck source=../../.assets/lib/nx.sh
  source "$NX_SCRIPT"
  nx() { nx_main "$@"; }
}

teardown() {
  rm -rf "$TEST_DIR"
}

# ---------------------------------------------------------------------------
# helpers
# ---------------------------------------------------------------------------
_write_legacy_bashrc() {
  cat >"$HOME/.bashrc" <<'RC'
# existing user content
alias ll='ls -la'

# Nix
export PATH="$HOME/.nix-profile/bin:$PATH"

# nix aliases
. "$HOME/.config/bash/aliases_nix.sh"

# git aliases
. "$HOME/.config/bash/aliases_git.sh"

# fzf integration
[ -x "$HOME/.nix-profile/bin/fzf" ] && eval "$(fzf --bash)"

# NODE_EXTRA_CA_CERTS handled elsewhere
RC
}

_write_clean_bashrc_with_block() {
  cat >"$HOME/.bashrc" <<'RC'
# user content above
alias ll='ls -la'

# >>> managed env >>>
if [ -d "$HOME/.local/bin" ]; then
  export PATH="$HOME/.local/bin:$PATH"
fi
# <<< managed env <<<

# >>> nix-env managed >>>
export PATH="$HOME/.nix-profile/bin:$PATH"
. "$HOME/.config/bash/aliases_nix.sh"
# <<< nix-env managed <<<

# user content below
alias gs='git status'
RC
}

# ---------------------------------------------------------------------------
# nx profile doctor
# ---------------------------------------------------------------------------

@test "profile doctor warns when no managed block" {
  printf '# just some content\n' >"$HOME/.bashrc"
  run nx profile doctor
  [ "$status" -ne 0 ]
  [[ "$output" =~ "no 'managed env' block" ]]
}

@test "profile doctor passes when managed block present" {
  _write_clean_bashrc_with_block
  run nx profile doctor
  [ "$status" -eq 0 ]
  [[ "$output" =~ "healthy" ]]
}

@test "profile doctor fails on duplicate managed blocks" {
  local marker="nix-env managed"
  cat >"$HOME/.bashrc" <<RC
# >>> $marker >>>
export A=1
# <<< $marker <<<
# >>> $marker >>>
export A=1
# <<< $marker <<<
RC
  run nx profile doctor
  [ "$status" -ne 0 ]
  [[ "$output" =~ "duplicate" ]]
}

# ---------------------------------------------------------------------------
# nx profile regenerate - legacy cleanup
# ---------------------------------------------------------------------------

@test "profile regenerate removes known legacy markers" {
  _write_legacy_bashrc
  run nx profile regenerate
  [ "$status" -eq 0 ]
  # legacy markers should be gone from outside managed blocks
  local outside
  outside="$(awk '/^# >>> .* >>>$/{s=1;next} s&&/^# <<< .* <<<$/{s=0;next} !s{print}' "$HOME/.bashrc")"
  run grep -cF 'aliases_nix' <<< "$outside"
  [ "$output" -eq 0 ]
  run grep -cF 'NODE_EXTRA_CA_CERTS' <<< "$outside"
  [ "$output" -eq 0 ]
}

@test "profile regenerate preserves user content outside legacy lines" {
  _write_legacy_bashrc
  nx profile regenerate
  grep -q "alias ll='ls -la'" "$HOME/.bashrc"
}

@test "profile regenerate creates backup when legacy markers found" {
  _write_legacy_bashrc
  nx profile regenerate
  local backups
  backups="$(find "$HOME" -name '.bashrc.nixenv-backup-*' 2>/dev/null | wc -l)"
  [ "$backups" -ge 1 ]
}

@test "profile regenerate skips backup on clean profile" {
  _write_clean_bashrc_with_block
  nx profile regenerate
  local backups
  backups="$(find "$HOME" -name '.bashrc.nixenv-backup-*' 2>/dev/null | wc -l)"
  [ "$backups" -eq 0 ]
}

# ---------------------------------------------------------------------------
# nx profile uninstall
# ---------------------------------------------------------------------------

@test "profile uninstall removes managed blocks from bashrc" {
  _write_clean_bashrc_with_block
  run nx profile uninstall
  [ "$status" -eq 0 ]
  run grep -cF "# >>> nix-env managed >>>" "$HOME/.bashrc"
  [ "$output" -eq 0 ]
  run grep -cF "# >>> managed env >>>" "$HOME/.bashrc"
  [ "$output" -eq 0 ]
}

@test "profile uninstall preserves content outside the block" {
  _write_clean_bashrc_with_block
  nx profile uninstall
  grep -q "alias ll='ls -la'" "$HOME/.bashrc"
  grep -q "alias gs='git status'" "$HOME/.bashrc"
}

@test "profile uninstall is a no-op on rc without managed block" {
  printf 'just user content\n' >"$HOME/.bashrc"
  run nx profile uninstall
  [ "$status" -eq 0 ]
  grep -q "just user content" "$HOME/.bashrc"
}

@test "profile doctor fails after uninstall" {
  _write_clean_bashrc_with_block
  nx profile uninstall
  run nx profile doctor
  [ "$status" -ne 0 ]
}
