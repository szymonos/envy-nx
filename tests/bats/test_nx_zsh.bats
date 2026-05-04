#!/usr/bin/env bats
# Runtime-zsh smoke tests for nx.sh, the four family files, and completions.zsh.
#
# Bats itself runs under bash, but each test invokes a fresh `zsh -c` that
# sources the SUT - so any zsh parse/expansion issue (BASH_SOURCE empty, glob
# nomatch, numeric subscripts, compdef/compinit) breaks the test.
#
# Scope is intentionally narrow: ~10 tests covering the documented zsh
# trip-points and the dispatcher entry points for each family. Most bats
# tests in this directory verify string outputs of internal helpers that
# behave identically under bash and zsh - duplicating them here would add
# CI time for no signal. If a future bug surfaces under zsh that the static
# check_zsh_compat hook missed, add a test here.
#
# Skipped when zsh isn't installed (bats sees `skip` and treats them as
# passes - keeps developer machines without zsh happy; CI always runs
# them since zsh is on ubuntu-slim and macos-15 by default).
bats_require_minimum_version 1.5.0

REPO_ROOT="$(cd "$(dirname "$BATS_TEST_FILENAME")/../.." && pwd)"

setup() {
  command -v zsh >/dev/null 2>&1 || skip "zsh not installed"
  TEST_DIR="$(mktemp -d)"
  export HOME="$TEST_DIR"
  export ENV_DIR="$TEST_DIR/.config/nix-env"
  # Point _nx_find_lib at the source repo's .assets/lib/ via NX_LIB_DIR
  # override - removes the need to copy 7 files into ENV_DIR before each
  # test. The fallback test below uses a marker.sh that isn't in
  # NX_LIB_DIR, so it still exercises the zsh BASH_SOURCE-empty fallback
  # to $HOME/.config/nix-env/.
  export NX_LIB_DIR="$REPO_ROOT/.assets/lib"
  mkdir -p "$ENV_DIR/scopes"
  # minimal config.nix with one scope so dispatchers don't hit empty-config bail-outs
  cat >"$ENV_DIR/config.nix" <<'EOF'
{
  isInit = false;

  scopes = [
    "shell"
  ];
}
EOF
  # minimal scope file (a `# bins:` line keeps the doctor's scope_binaries warn quiet)
  printf '# bins: rg\n{ pkgs }: with pkgs; [ ripgrep ]\n' >"$ENV_DIR/scopes/shell.nix"
}

teardown() {
  rm -rf "$TEST_DIR"
}

# Run a snippet under zsh with the test's HOME/ENV_DIR/NX_LIB_DIR exported.
_zsh() {
  HOME="$HOME" ENV_DIR="$ENV_DIR" NX_LIB_DIR="$NX_LIB_DIR" zsh -c "$@"
}

# -- sourcing -----------------------------------------------------------------

@test "nx.sh sources cleanly into zsh (no parse errors, all family files load)" {
  run _zsh "source $NX_LIB_DIR/nx.sh"
  [ "$status" -eq 0 ]
  # any family-file load failure prints "nx: family file <name> not found"
  [[ "$output" != *"family file"*"not found"* ]]
}

@test "all four family files source cleanly into zsh in isolation" {
  for f in nx_pkg.sh nx_scope.sh nx_profile.sh nx_lifecycle.sh; do
    # source nx.sh first to set up shared helpers + constants the family expects
    run _zsh "source $NX_LIB_DIR/nx.sh && source $REPO_ROOT/.assets/lib/$f"
    [ "$status" -eq 0 ] || fail "$f failed to source under zsh: $output"
  done
}

@test "completions.zsh sources cleanly under zsh (compdef/compinit guard fires)" {
  # compinit prints a warning about insecure dirs in some envs; -i suppresses it.
  # The test passes as long as zsh doesn't error out on `compdef` itself.
  run _zsh "source $REPO_ROOT/.assets/config/shell_cfg/completions.zsh && type _nx >/dev/null"
  [ "$status" -eq 0 ]
}

# -- dispatcher routing -------------------------------------------------------

@test "nx_main help works under zsh" {
  run _zsh "source $NX_LIB_DIR/nx.sh && nx_main help"
  [ "$status" -eq 0 ]
  [[ "$output" == *"Usage: nx"* ]]
}

@test "nx_main version works under zsh (no install.json - early return path)" {
  # Without install.json, _nx_lifecycle_version prints "No install record
  # found" and returns before declaring any locals. This is the path that
  # *used to be* the only one tested - it never executed the local
  # declarations and so missed the `local status` zsh-readonly-variable
  # bug. The "with install.json" test below covers the full happy path.
  run _zsh "source $NX_LIB_DIR/nx.sh && nx_main version"
  [ "$status" -eq 0 ]
  [[ "$output" == *"No install record found"* ]]
}

@test "nx_main version works under zsh (with install.json - full path, no zsh-readonly conflicts)" {
  # Regression: `local status=...` errored with `read-only variable: status`
  # under zsh because $status is a zsh special read-only var. This test
  # writes a real install.json so the function reaches the local
  # declarations + jq parses + final printfs - the path that breaks under
  # zsh if any local shadows a read-only special.
  mkdir -p "$HOME/.config/dev-env"
  cat >"$HOME/.config/dev-env/install.json" <<'EOF'
{
  "version": "1.5.3",
  "entry_point": "nix",
  "source": "git",
  "source_ref": "abcdef123456",
  "scopes": ["shell"],
  "installed_at": "2026-05-04T06:52:13Z",
  "mode": "reconfigure",
  "status": "success",
  "phase": "complete",
  "platform": "Linux",
  "arch": "x86_64",
  "nix_version": "nix (Nix) 2.18.1",
  "bash_version": "5.2",
  "repo_path": "/home/test/envy-nx"
}
EOF
  run _zsh "source $NX_LIB_DIR/nx.sh && nx_main version"
  [ "$status" -eq 0 ]
  [[ "$output" == *"dev-env"* ]]
  [[ "$output" == *"1.5.3"* ]]
  [[ "$output" == *"success"* ]]
  # explicitly assert the regression: no read-only error
  [[ "$output" != *"read-only variable"* ]]
}

@test "nx_main pin show works under zsh (scope/pin family dispatcher)" {
  run _zsh "source $NX_LIB_DIR/nx.sh && nx_main pin show"
  [ "$status" -eq 0 ]
  [[ "$output" == *"No pin set"* ]]
}

@test "nx_main profile help works under zsh (profile family dispatcher)" {
  run _zsh "source $NX_LIB_DIR/nx.sh && nx_main profile help"
  [ "$status" -eq 0 ]
  [[ "$output" == *"Usage: nx profile"* ]]
}

@test "nx_main self help works under zsh (lifecycle family dispatcher)" {
  run _zsh "source $NX_LIB_DIR/nx.sh && nx_main self help"
  [ "$status" -eq 0 ]
  [[ "$output" == *"Usage: nx self"* ]]
}

# -- known glob-nomatch trip-points (the bug that bit 1.3.1 on macOS) --------

@test "nx_main scope list works under zsh with no overlay scopes" {
  # The for-loop over $scopes_dir/local_*.nix used to abort under zsh's
  # `nomatch` option when no local_*.nix existed. After the find/while
  # refactor, this should pass cleanly.
  run _zsh "source $NX_LIB_DIR/nx.sh && nx_main scope list"
  [ "$status" -eq 0 ]
  [[ "$output" != *"no matches found"* ]]
  [[ "$output" == *"shell"* ]]
}

@test "nx_main scope tree works under zsh with no overlay scopes" {
  run _zsh "source $NX_LIB_DIR/nx.sh && nx_main scope tree"
  [ "$status" -eq 0 ]
  [[ "$output" != *"no matches found"* ]]
}

@test "nx_main overlay works under zsh with no overlay dir" {
  run _zsh "source $NX_LIB_DIR/nx.sh && nx_main overlay"
  [ "$status" -eq 0 ]
  [[ "$output" != *"no matches found"* ]]
}

# -- BASH_SOURCE fallback -----------------------------------------------------

@test "_nx_find_lib falls back to \$HOME/.config/nix-env when BASH_SOURCE is empty" {
  # Plant a marker file in the runtime location and verify _nx_find_lib finds
  # it when invoked under zsh (where BASH_SOURCE[0] is empty by default).
  : >"$ENV_DIR/marker.sh"
  run _zsh "source $NX_LIB_DIR/nx.sh && _nx_find_lib marker.sh"
  [ "$status" -eq 0 ]
  [[ "$output" == *"$ENV_DIR/marker.sh"* ]]
}
