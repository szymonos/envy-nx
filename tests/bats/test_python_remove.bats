#!/usr/bin/env bats
# Unit tests for nix/configure/python_remove.sh
# Covers: no-op when no uv state, unattended removal across all three dirs,
# enumeration of pythons + tools, prompt-skip on non-tty, env-var overrides
# (UV_CACHE_DIR / UV_TOOL_DIR / UV_PYTHON_INSTALL_DIR).

setup() {
  TEST_DIR="$(mktemp -d)"
  export HOME="$TEST_DIR"
  REPO_ROOT="$(cd "$BATS_TEST_DIRNAME/../.." && pwd)"
  SCRIPT="$REPO_ROOT/nix/configure/python_remove.sh"
  # Ensure the env-var override path is unset by default; tests opt in.
  unset UV_CACHE_DIR UV_TOOL_DIR UV_PYTHON_INSTALL_DIR
}

teardown() {
  rm -rf "$TEST_DIR"
  unset UV_CACHE_DIR UV_TOOL_DIR UV_PYTHON_INSTALL_DIR
}

@test "no-op when no uv state directories exist" {
  [ ! -d "$HOME/.cache/uv" ]
  [ ! -d "$HOME/.local/share/uv" ]
  run bash "$SCRIPT" true
  [ "$status" -eq 0 ]
  [ -z "$output" ]
}

@test "unattended removes all three default dirs when present" {
  mkdir -p "$HOME/.cache/uv/wheels"
  mkdir -p "$HOME/.local/share/uv/tools/black"
  mkdir -p "$HOME/.local/share/uv/python/cpython-3.13.0-linux-x86_64-gnu"

  run bash "$SCRIPT" true
  [ "$status" -eq 0 ]
  [ ! -d "$HOME/.cache/uv" ]
  [ ! -d "$HOME/.local/share/uv/tools" ]
  [ ! -d "$HOME/.local/share/uv/python" ]
  [[ "$output" == *"removed"*".cache/uv"* ]]
  [[ "$output" == *"removed"*"uv/tools"* ]]
  [[ "$output" == *"removed"*"uv/python"* ]]
}

@test "unattended only removes dirs that exist (partial state)" {
  # User has cache but never used `uv tool install` or `uv python install`.
  mkdir -p "$HOME/.cache/uv/wheels"
  run bash "$SCRIPT" true
  [ "$status" -eq 0 ]
  [ ! -d "$HOME/.cache/uv" ]
  [[ "$output" == *"removed"*".cache/uv"* ]]
  [[ "$output" != *"removed"*"uv/tools"* ]]
  [[ "$output" != *"removed"*"uv/python"* ]]
}

@test "unattended enumerates managed Python versions" {
  mkdir -p "$HOME/.local/share/uv/python/cpython-3.13.0-linux-x86_64-gnu" \
    "$HOME/.local/share/uv/python/cpython-3.12.5-linux-x86_64-gnu" \
    "$HOME/.local/share/uv/python/pypy-3.10.14-linux-x86_64-gnu"

  run bash "$SCRIPT" true
  [ "$status" -eq 0 ]
  [[ "$output" == *"3 managed Python version(s)"* ]]
  [[ "$output" == *"cpython-3.13.0-linux-x86_64-gnu"* ]]
  [[ "$output" == *"cpython-3.12.5-linux-x86_64-gnu"* ]]
  [[ "$output" == *"pypy-3.10.14-linux-x86_64-gnu"* ]]
}

@test "unattended enumerates uv-installed tools and warns about ~/.local/bin/ symlinks" {
  mkdir -p "$HOME/.local/share/uv/tools/black" \
    "$HOME/.local/share/uv/tools/ruff" \
    "$HOME/.local/share/uv/tools/mypy"

  run bash "$SCRIPT" true
  [ "$status" -eq 0 ]
  [[ "$output" == *"3 uv-installed tool(s)"* ]]
  [[ "$output" == *"black"* ]]
  [[ "$output" == *"ruff"* ]]
  [[ "$output" == *"mypy"* ]]
  # The post-removal reminder about dangling ~/.local/bin/ symlinks must fire
  # whenever the tools dir was removed (uv leaves symlinks under ~/.local/bin/
  # pointing back into ~/.local/share/uv/tools/ - those become broken).
  [[ "$output" == *"~/.local/bin/"* ]]
  [[ "$output" == *"uv tool install"* ]]
}

@test "interactive declined leaves all uv state in place" {
  mkdir -p "$HOME/.cache/uv/wheels"
  mkdir -p "$HOME/.local/share/uv/tools/black"

  # `[ ! -t 0 ]` guard short-circuits when stdin is not a terminal; cf.
  # ARCHITECTURE.md §7.9. Same pattern as test_conda_remove.bats /
  # test_nodejs_remove.bats.
  run bash "$SCRIPT" </dev/null
  [ "$status" -eq 0 ]
  [ -d "$HOME/.cache/uv" ]
  [ -d "$HOME/.local/share/uv/tools" ]
  [[ "$output" == *"Skipped"* ]] || [[ "$output" == *"retained"* ]]
}

@test "honors UV_CACHE_DIR override" {
  export UV_CACHE_DIR="$HOME/custom-uv-cache"
  mkdir -p "$UV_CACHE_DIR/wheels"
  # Default ~/.cache/uv must NOT be touched (it doesn't exist anyway, but the
  # script must target the override location).
  [ ! -d "$HOME/.cache/uv" ]

  run bash "$SCRIPT" true
  [ "$status" -eq 0 ]
  [ ! -d "$UV_CACHE_DIR" ]
  [[ "$output" == *"removed"*"custom-uv-cache"* ]]
}

@test "honors UV_TOOL_DIR override" {
  export UV_TOOL_DIR="$HOME/custom-uv-tools"
  mkdir -p "$UV_TOOL_DIR/black"

  run bash "$SCRIPT" true
  [ "$status" -eq 0 ]
  [ ! -d "$UV_TOOL_DIR" ]
  [[ "$output" == *"removed"*"custom-uv-tools"* ]]
  [[ "$output" == *"black"* ]]
}

@test "honors UV_PYTHON_INSTALL_DIR override" {
  export UV_PYTHON_INSTALL_DIR="$HOME/custom-uv-pythons"
  mkdir -p "$UV_PYTHON_INSTALL_DIR/cpython-3.13.0"

  run bash "$SCRIPT" true
  [ "$status" -eq 0 ]
  [ ! -d "$UV_PYTHON_INSTALL_DIR" ]
  [[ "$output" == *"removed"*"custom-uv-pythons"* ]]
  [[ "$output" == *"cpython-3.13.0"* ]]
}
