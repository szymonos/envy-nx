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

# Force `uname -s` to report a given kernel so the Darwin-only ~/.bash_profile
# shim can be exercised on Linux CI. Other flags fall through to the real uname.
_stub_uname() {
  # Resolve the real uname before the stub shadows it - the path is not always
  # /usr/bin/uname (Alpine ships /bin/uname and has no /usr/bin at all).
  local real
  rm -f "$TEST_DIR/bin/uname"
  real="$(command -v uname)"
  cat >"$TEST_DIR/bin/uname" <<EOF
#!/bin/sh
[ "\$1" = "-s" ] && { echo '$1'; exit 0; }
exec "$real" "\$@"
EOF
  chmod +x "$TEST_DIR/bin/uname"
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

@test "profile regenerate writes a ~/.bash_profile shim on macOS" {
  # macOS Terminal runs bash as a login shell, which reads ~/.bash_profile and
  # never ~/.bashrc, and macOS ships no default ~/.bash_profile - so without
  # this shim every managed block is rendered but never sourced.
  _stub_uname Darwin
  printf '# user content\n' >"$HOME/.bashrc"
  nx profile regenerate
  [ -f "$HOME/.bash_profile" ]
  grep -q '# >>> nix:bash_profile >>>' "$HOME/.bash_profile"
  grep -q '\.bashrc' "$HOME/.bash_profile"
}

@test "profile regenerate writes no ~/.bash_profile on Linux" {
  # Distros ship a .bash_profile that already sources .bashrc; adding our own
  # would shadow theirs.
  _stub_uname Linux
  printf '# user content\n' >"$HOME/.bashrc"
  nx profile regenerate
  [ ! -f "$HOME/.bash_profile" ]
}

@test "profile regenerate leaves a ~/.bash_profile that already sources .bashrc alone" {
  _stub_uname Darwin
  printf '# user content\n' >"$HOME/.bashrc"
  printf 'source ~/.bashrc\n' >"$HOME/.bash_profile"
  nx profile regenerate
  run grep -c '\.bashrc' "$HOME/.bash_profile"
  [ "$output" -eq 1 ]
  run grep -q 'nix:bash_profile' "$HOME/.bash_profile"
  [ "$status" -ne 0 ]
}

@test "a ~/.bash_profile only mentioning .bashrc in a comment still gets the shim" {
  # The guard must match a sourcing statement, not any mention - otherwise a
  # stray comment silently leaves login bash without the managed blocks.
  _stub_uname Darwin
  printf '# user content\n' >"$HOME/.bashrc"
  printf '# I used to source ~/.bashrc from here\nexport MINE=1\n' >"$HOME/.bash_profile"
  nx profile regenerate
  grep -q '# >>> nix:bash_profile >>>' "$HOME/.bash_profile"
  grep -q 'export MINE=1' "$HOME/.bash_profile"
}

@test "profile regenerate is idempotent for the ~/.bash_profile shim" {
  _stub_uname Darwin
  printf '# user content\n' >"$HOME/.bashrc"
  nx profile regenerate
  nx profile regenerate
  run grep -c '# >>> nix:bash_profile >>>' "$HOME/.bash_profile"
  [ "$output" -eq 1 ]
}

@test "profile regenerate preserves user content outside managed blocks" {
  _write_legacy_bashrc
  nx profile regenerate
  grep -q "alias ll='ls -la'" "$HOME/.bashrc"
  grep -q 'aliases_nix' "$HOME/.bashrc"
}

@test "profile regenerate always includes .local/bin in env block (case-guard handles dedup)" {
  # The :local path section is always emitted; the runtime case-guard
  # `case ":$PATH:" in *":$HOME/.local/bin:"*) ;; *) ...` makes the addition
  # idempotent, so duplicating a user's own .local/bin PATH addition is a
  # no-op at shell-startup time. A previous "skip if .local/bin mentioned
  # anywhere outside managed blocks" heuristic misfired on lines that named
  # .local/bin/<bin> without modifying PATH (uv completion eval, copilot
  # probes), leaving copilot/az unreachable in new shells.
  cat >"$HOME/.bashrc" <<'RC'
if ! [[ "$PATH" =~ "$HOME/.local/bin" ]]; then
    PATH="$HOME/.local/bin:$PATH"
fi
export PATH
RC
  nx profile regenerate
  local inside
  inside="$(awk '/^# >>> env:managed >>>$/{s=1;next} s&&/^# <<< env:managed <<<$/{s=0;next} s{print}' "$HOME/.bashrc")"
  run grep -cF '.local/bin' <<<"$inside"
  [ "$output" -ge 1 ]
  # original user content preserved outside managed blocks
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

@test "profile regenerate emits .local/bin even when uv-completion block (probes ~/.local/bin/uv) exists outside managed blocks" {
  # Regression: setup_profile_user.zsh appends a `# initialize uv autocompletion`
  # block that references $HOME/.local/bin/uv but does NOT modify PATH. A prior
  # bare-substring heuristic interpreted this as "PATH already handled" and
  # rendered an empty env:managed block, breaking copilot CLI on fresh shells.
  cat >"$HOME/.bashrc" <<'RC'
# initialize uv autocompletion
if [ -x "$HOME/.local/bin/uv" ]; then
  export UV_SYSTEM_CERTS=true
  eval "$($HOME/.local/bin/uv generate-shell-completion bash)"
fi
RC
  nx profile regenerate
  local inside
  inside="$(awk '/^# >>> env:managed >>>$/{s=1;next} s&&/^# <<< env:managed <<<$/{s=0;next} s{print}' "$HOME/.bashrc")"
  run grep -cF '.local/bin' <<<"$inside"
  [ "$output" -ge 1 ]
  # user's uv completion block preserved verbatim
  grep -q 'uv generate-shell-completion bash' "$HOME/.bashrc"
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

@test "profile uninstall drops a ~/.bash_profile that held only the shim" {
  _stub_uname Darwin
  printf '# user content\n' >"$HOME/.bashrc"
  nx profile regenerate
  [ -f "$HOME/.bash_profile" ]
  run nx profile uninstall
  [ "$status" -eq 0 ]
  [ ! -f "$HOME/.bash_profile" ]
}

@test "profile uninstall keeps an empty ~/.bash_profile it never wrote" {
  # An empty ~/.bash_profile is deliberate on macOS: bash reads the first of
  # .bash_profile/.bash_login/.profile, so an empty one suppresses .profile.
  printf '# user content\n' >"$HOME/.bashrc"
  : >"$HOME/.bash_profile"
  run nx profile uninstall
  [ "$status" -eq 0 ]
  [ -f "$HOME/.bash_profile" ]
}

@test "profile uninstall keeps a ~/.bash_profile that has user content" {
  _stub_uname Darwin
  printf '# user content\n' >"$HOME/.bashrc"
  printf 'export MINE=1\n' >"$HOME/.bash_profile"
  # regenerate skips files already naming .bashrc, so seed the shim directly
  # to prove removal leaves the surrounding content intact.
  printf '# >>> nix:bash_profile >>>\n. "$HOME/.bashrc"\n# <<< nix:bash_profile <<<\n' \
    >>"$HOME/.bash_profile"
  run nx profile uninstall
  [ "$status" -eq 0 ]
  [ -f "$HOME/.bash_profile" ]
  grep -q 'export MINE=1' "$HOME/.bash_profile"
  run grep -c 'nix:bash_profile' "$HOME/.bash_profile"
  [ "$output" -eq 0 ]
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
