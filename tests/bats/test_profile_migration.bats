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

# >>> env:managed >>>
if [ -d "$HOME/.local/bin" ]; then
  export PATH="$HOME/.local/bin:$PATH"
fi
# <<< env:managed <<<

# >>> nix:managed >>>
export PATH="$HOME/.nix-profile/bin:$PATH"
. "$HOME/.config/bash/aliases_nix.sh"
# <<< nix:managed <<<

# user content below
alias gs='git status'
RC
}

# Pre-1.5 marker names; used to test the silent migration in regenerate.
_write_legacy_marker_bashrc() {
  cat >"$HOME/.bashrc" <<'RC'
# pre-existing user content
alias ll='ls -la'

# >>> managed env >>>
if [ -d "$HOME/.local/bin" ]; then
  export PATH="$HOME/.local/bin:$PATH"
fi
# <<< managed env <<<

# >>> nix-env managed >>>
export PATH="$HOME/.nix-profile/bin:$PATH"
# <<< nix-env managed <<<

# trailing user content
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
  [[ "$output" =~ "no 'env:managed' block" ]]
}

@test "profile doctor passes when managed block present" {
  _write_clean_bashrc_with_block
  run nx profile doctor
  [ "$status" -eq 0 ]
  [[ "$output" =~ "healthy" ]]
}

@test "profile doctor passes for users with legacy marker names (silent migration)" {
  # Existing users who upgraded to >=1.5 but haven't run regenerate yet
  # still have the old "nix-env managed" / "managed env" marker names.
  # Doctor must not flag this as broken - migration happens automatically
  # on the next regenerate.
  _write_legacy_marker_bashrc
  run nx profile doctor
  [ "$status" -eq 0 ]
  [[ "$output" =~ "healthy" ]]
}

@test "profile doctor fails on duplicate managed blocks" {
  local marker="nix:managed"
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
# nx profile regenerate
# ---------------------------------------------------------------------------

@test "profile regenerate preserves user content outside managed blocks" {
  _write_legacy_bashrc
  nx profile regenerate
  grep -q "alias ll='ls -la'" "$HOME/.bashrc"
  grep -q 'aliases_nix' "$HOME/.bashrc"
}

@test "profile regenerate skips .local/bin in env block when already in profile" {
  cat >"$HOME/.bashrc" <<'RC'
if ! [[ "$PATH" =~ "$HOME/.local/bin" ]]; then
    PATH="$HOME/.local/bin:$PATH"
fi
export PATH
RC
  nx profile regenerate
  # .local/bin should not appear inside the env:managed block
  local inside
  inside="$(awk '/^# >>> env:managed >>>$/{s=1;next} s&&/^# <<< env:managed <<<$/{s=0;next} s{print}' "$HOME/.bashrc")"
  run grep -cF '.local/bin' <<<"$inside"
  [ "$output" -eq 0 ]
  # original content preserved
  grep -q 'export PATH' "$HOME/.bashrc"
}

@test "profile regenerate includes .local/bin in env block when not in profile" {
  printf '# minimal bashrc\n' >"$HOME/.bashrc"
  nx profile regenerate
  local inside
  inside="$(awk '/^# >>> env:managed >>>$/{s=1;next} s&&/^# <<< env:managed <<<$/{s=0;next} s{print}' "$HOME/.bashrc")"
  run grep -cF '.local/bin' <<<"$inside"
  [ "$output" -ge 1 ]
}

@test "profile regenerate migrates legacy marker names to nix:managed / env:managed" {
  _write_legacy_marker_bashrc
  # sanity: rc starts with legacy markers
  grep -qF '# >>> nix-env managed >>>' "$HOME/.bashrc"
  grep -qF '# >>> managed env >>>' "$HOME/.bashrc"

  nx profile regenerate

  # legacy markers gone
  run grep -cF '# >>> nix-env managed >>>' "$HOME/.bashrc"
  [ "$output" -eq 0 ]
  run grep -cF '# >>> managed env >>>' "$HOME/.bashrc"
  [ "$output" -eq 0 ]

  # new markers present, exactly once each
  run grep -cF '# >>> nix:managed >>>' "$HOME/.bashrc"
  [ "$output" -eq 1 ]
  run grep -cF '# >>> env:managed >>>' "$HOME/.bashrc"
  [ "$output" -eq 1 ]

  # user content outside the blocks survived the migration
  grep -q "alias ll='ls -la'" "$HOME/.bashrc"
  grep -q "alias gs='git status'" "$HOME/.bashrc"
}

# ---------------------------------------------------------------------------
# nx profile uninstall
# ---------------------------------------------------------------------------

@test "profile uninstall removes managed blocks from bashrc" {
  _write_clean_bashrc_with_block
  run nx profile uninstall
  [ "$status" -eq 0 ]
  run grep -cF "# >>> nix:managed >>>" "$HOME/.bashrc"
  [ "$output" -eq 0 ]
  run grep -cF "# >>> env:managed >>>" "$HOME/.bashrc"
  [ "$output" -eq 0 ]
}

@test "profile uninstall also removes legacy-named blocks (transitional users)" {
  _write_legacy_marker_bashrc
  run nx profile uninstall
  [ "$status" -eq 0 ]
  # both legacy markers removed
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
