#!/usr/bin/env bats
# Unit tests for .assets/config/shell_cfg/completions.bash
# Specifically the verb-flag value-completer dispatch (e.g. `nx setup --remove
# <TAB>` -> installed scopes from ~/.config/nix-env/config.nix).
#
# Source the generated completer once in setup(), fake config.nix state in
# $HOME, then call _nx_completions directly in the parent shell and inspect
# COMPREPLY.

setup() {
  TEST_DIR="$(mktemp -d)"
  export HOME="$TEST_DIR"
  REPO_ROOT="$(cd "$BATS_TEST_DIRNAME/../.." && pwd)"
  COMPLETER="$REPO_ROOT/.assets/config/shell_cfg/completions.bash"
  mkdir -p "$HOME/.config/nix-env/scopes"
  set +u
  # shellcheck source=../../.assets/config/shell_cfg/completions.bash
  source "$COMPLETER"
  set -u
}

teardown() {
  rm -rf "$TEST_DIR"
}

# Helper: run the completer with the given COMP_WORDS array (passed as
# positional args) and COMP_CWORD (last positional, an integer). Returns
# the COMPREPLY array sorted on its own line so the test can grep it.
# Sourcing the completer in setup() means we no longer round-trip COMP_WORDS
# through a `bash -c` payload, which removes a quoting bug class (any value
# with a single quote or backslash used to silently break the array init).
_run_completion() {
  # Last positional is the integer COMP_CWORD; everything before it is the
  # COMP_WORDS array contents.
  local cword="${!#}"
  local words=("${@:1:$#-1}")
  COMP_WORDS=("${words[@]}")
  COMP_CWORD="$cword"
  COMPREPLY=()
  _nx_completions
  printf "%s\n" "${COMPREPLY[@]}" | LC_ALL=C sort
}

# -- nx setup --remove <TAB> -> installed scopes -----------------------------

@test "setup --remove completes installed scopes from config.nix" {
  cat >"$HOME/.config/nix-env/config.nix" <<'EOF'
{
  isInit = false;
  allowUnfree = false;
  scopes = [
    "shell"
    "python"
    "nodejs"
  ];
}
EOF
  output="$(_run_completion nx setup --remove "" 3)"
  [[ "$output" == *"shell"* ]]
  [[ "$output" == *"python"* ]]
  [[ "$output" == *"nodejs"* ]]
  # Must NOT fall through to the static flag list when prev=--remove
  [[ "$output" != *"--az"* ]]
  [[ "$output" != *"--all"* ]]
}

@test "setup --remove with prefix filters by scope name prefix" {
  cat >"$HOME/.config/nix-env/config.nix" <<'EOF'
{
  scopes = [
    "shell"
    "python"
    "pwsh"
    "nodejs"
  ];
}
EOF
  output="$(_run_completion nx setup --remove "p" 3)"
  [[ "$output" == *"python"* ]]
  [[ "$output" == *"pwsh"* ]]
  [[ "$output" != *"shell"* ]]
  [[ "$output" != *"nodejs"* ]]
}

@test "setup --remove also includes overlay scopes from local_*.nix" {
  cat >"$HOME/.config/nix-env/config.nix" <<'EOF'
{
  scopes = [
    "shell"
    "local_devtools"
  ];
}
EOF
  : >"$HOME/.config/nix-env/scopes/local_devtools.nix"
  : >"$HOME/.config/nix-env/scopes/local_extras.nix"
  output="$(_run_completion nx setup --remove "" 3)"
  [[ "$output" == *"shell"* ]]
  [[ "$output" == *"devtools"* ]]
  # extras is on disk but not in config.nix scopes - should still appear
  # because the all_scopes completer unions both sources (matches existing
  # behavior used by `nx scope edit/remove`).
  [[ "$output" == *"extras"* ]]
}

# -- setup --omp-theme / --starship-theme -----------------------------------

@test "setup --omp-theme completes theme names (regression for the same dispatch)" {
  output="$(_run_completion nx setup --omp-theme "" 3)"
  [[ "$output" == *"base"* ]]
  [[ "$output" == *"nerd"* ]]
  [[ "$output" == *"powerline"* ]]
  [[ "$output" != *"--az"* ]]
}

@test "setup --starship-theme completes theme names" {
  output="$(_run_completion nx setup --starship-theme "" 3)"
  [[ "$output" == *"base"* ]]
  [[ "$output" == *"nerd"* ]]
  [[ "$output" != *"powerline"* ]] # powerline is omp-only
  [[ "$output" != *"--az"* ]]
}

# -- fallback to static flag list when prev is not a value-completer flag ---

@test "setup completes flags when prev is not a value-completer flag" {
  output="$(_run_completion nx setup "" 2)"
  [[ "$output" == *"--az"* ]]
  [[ "$output" == *"--remove"* ]]
  [[ "$output" == *"--omp-theme"* ]]
  [[ "$output" == *"--all"* ]]
}

@test "setup completes flags when prev is a non-value flag like --shell" {
  output="$(_run_completion nx setup --shell "" 3)"
  [[ "$output" == *"--az"* ]]
  [[ "$output" == *"--all"* ]]
}
