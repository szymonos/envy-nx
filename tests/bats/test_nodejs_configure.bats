#!/usr/bin/env bats
# Unit tests for nix/configure/nodejs.sh - the stale npm prefix check, against
# stub fnm and npm binaries.
bats_require_minimum_version 1.5.0

setup() {
  TEST_DIR="$(mktemp -d)"
  export HOME="$TEST_DIR"
  REPO_ROOT="$(cd "$BATS_TEST_DIRNAME/../.." && pwd)"
  SCRIPT="$REPO_ROOT/nix/configure/nodejs.sh"
  mkdir -p "$TEST_DIR/bin"
  printf '#!/bin/sh\n[ "$1" = list ] && echo lts-latest\nexit 0\n' >"$TEST_DIR/bin/fnm"
  # npm resolves the prefix from the environment first, then from ~/.npmrc
  cat >"$TEST_DIR/bin/npm" <<'STUB'
#!/bin/sh
case "$1 $2" in
"config get")
  if [ "$3" = prefix ]; then
    v="${NPM_CONFIG_PREFIX:-${npm_config_prefix:-}}"
    [ -n "$v" ] || v="$(sed -n 's/^prefix=//p' "$HOME/.npmrc" 2>/dev/null)"
    echo "${v:-undefined}"
  else
    echo null
  fi
  ;;
"config delete") echo "$3" >>"$HOME/npm-deleted" ;;
esac
STUB
  chmod +x "$TEST_DIR/bin/fnm" "$TEST_DIR/bin/npm"
  export PATH="$TEST_DIR/bin:$PATH"
  unset NPM_CONFIG_PREFIX npm_config_prefix
}

teardown() {
  rm -rf "$TEST_DIR"
}

@test "nodejs: a prefix in ~/.npmrc is cleared unattended" {
  echo "prefix=$HOME/.npm-global" >"$HOME/.npmrc"
  run bash "$SCRIPT" true
  [ "$status" -eq 0 ]
  [ "$(cat "$HOME/npm-deleted")" = prefix ]
  [[ "$output" == *"removed stale npm prefix"* ]]
}

@test "nodejs: a prefix from NPM_CONFIG_PREFIX is named, not cleared" {
  export NPM_CONFIG_PREFIX="$HOME/.local"
  run bash "$SCRIPT" true
  [ "$status" -eq 0 ]
  [[ "$output" == *"set by the NPM_CONFIG_PREFIX environment variable"* ]]
  [[ "$output" == *"Unset NPM_CONFIG_PREFIX"* ]]
  [[ "$output" != *"removed stale npm prefix"* ]]
  [ ! -e "$HOME/npm-deleted" ]
}

@test "nodejs: a prefix from npm_config_prefix is named, not cleared" {
  export npm_config_prefix="$HOME/.local"
  run bash "$SCRIPT" false
  [ "$status" -eq 0 ]
  [[ "$output" == *"set by the npm_config_prefix environment variable"* ]]
  [[ "$output" != *"Remove the stale npm prefix"* ]]
  [ ! -e "$HOME/npm-deleted" ]
}

@test "nodejs: the environment-prefix warning goes to stdout, which _io_run keeps" {
  export NPM_CONFIG_PREFIX="$HOME/.local"
  run --separate-stderr bash "$SCRIPT" true
  [ "$status" -eq 0 ]
  [[ "$output" == *"Unset NPM_CONFIG_PREFIX"* ]]
}
