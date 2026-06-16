#!/usr/bin/env bats
# Unit tests for setup_vscode_macos_env in .assets/lib/vscode.sh.
# Covers the JSONC-safe User settings.json writer that registers
# nix-installed pwsh (when no existing entry points at it) and the
# ripgrep path the Todo-Tree extension needs (it does NOT use PATH).
# The /etc/paths.d/nix branch is skipped because it requires `sudo -n`
# and real root write access; that path is exercised by integration tests.
bats_require_minimum_version 1.5.0

setup() {
  # jq drives the test assertions only - the production function no
  # longer uses jq (it's JSONC-incompatible). The strip()-and-parse
  # helper below uses jq with a regex pre-strip so we can assert on
  # JSONC files; without jq the assertions can't run. Matches the skip
  # pattern in test_install_record.bats.
  if ! command -v jq >/dev/null 2>&1; then
    skip "jq not available"
  fi

  TEST_DIR="$(mktemp -d)"
  export HOME="$TEST_DIR"
  REPO_ROOT="$(cd "$BATS_TEST_DIRNAME/../.." && pwd)"

  # Force the Darwin code path on Linux CI runners.
  STUB_BIN="$TEST_DIR/bin"
  mkdir -p "$STUB_BIN"
  cat >"$STUB_BIN/uname" <<'EOF'
#!/usr/bin/env bash
if [ "$1" = "-s" ]; then echo "Darwin"; else /usr/bin/uname "$@"; fi
EOF
  chmod +x "$STUB_BIN/uname"
  export PATH="$STUB_BIN:$PATH"

  # Stub the nix-profile bin layout. Both pwsh and rg are real executables
  # (the function checks `[ -x ... ]`) but trivial no-ops.
  NIX_BIN="$HOME/.nix-profile/bin"
  mkdir -p "$NIX_BIN"
  printf '#!/usr/bin/env bash\nexit 0\n' >"$NIX_BIN/pwsh"
  printf '#!/usr/bin/env bash\nexit 0\n' >"$NIX_BIN/rg"
  chmod +x "$NIX_BIN/pwsh" "$NIX_BIN/rg"

  # VS Code User settings dir must exist for the function to write.
  SETTINGS_DIR="$HOME/Library/Application Support/Code/User"
  mkdir -p "$SETTINGS_DIR"
  SETTINGS_FILE="$SETTINGS_DIR/settings.json"

  # Source the lib with the required ok() helper. The /etc/paths.d branch
  # is best-effort (sudo -n) and silently skips when sudo prompts - safe in
  # a sandbox - so we don't need to stub sudo.
  ok() { :; }
  export -f ok
  # shellcheck source=../../.assets/lib/vscode.sh
  source "$REPO_ROOT/.assets/lib/vscode.sh"
}

teardown() {
  rm -rf "$TEST_DIR"
}

# Strip JSONC line + inline + block comments (and trailing commas) so
# the result parses as strict JSON. Mirrors how VS Code's jsonc-parser
# treats the file; here we only need it to make jq queries work.
_strip_jsonc() {
  sed -E '
    # remove block comments (single-line only - assumes no multi-line)
    s|/\*[^*]*\*+([^/*][^*]*\*+)*/||g
    # remove line comments NOT inside strings - approximation good enough
    # for our test fixtures
    s|//[^"]*$||
  ' "$1" | sed -E 's/,([[:space:]]*[}\]])/\1/g'
}

# Assert a JSONC file is parseable as strict JSON after comment strip.
_assert_valid_jsonc() {
  local stripped
  stripped="$(_strip_jsonc "$1")"
  printf '%s' "$stripped" | jq -e . >/dev/null
}

@test "macos: writes both pwsh and todo-tree.ripgrep.ripgrep on fresh install" {
  [ ! -f "$SETTINGS_FILE" ]
  setup_vscode_macos_env
  [ -f "$SETTINGS_FILE" ]
  _assert_valid_jsonc "$SETTINGS_FILE"

  local stripped
  stripped="$(_strip_jsonc "$SETTINGS_FILE")"

  run bash -c "printf %s '$stripped' | jq -r '.[\"powershell.powerShellAdditionalExePaths\"][\"nix\"]'"
  [ "$output" = "$NIX_BIN/pwsh" ]

  run bash -c "printf %s '$stripped' | jq -r '.[\"powershell.powerShellDefaultVersion\"]'"
  [ "$output" = "nix" ]

  run bash -c "printf %s '$stripped' | jq -r '.[\"todo-tree.ripgrep.ripgrep\"]'"
  [ "$output" = "$NIX_BIN/rg" ]
}

@test "macos: second run is a no-op (no rewrite)" {
  setup_vscode_macos_env
  local before_inode after_inode
  before_inode="$(ls -i "$SETTINGS_FILE" | awk '{print $1}')"
  setup_vscode_macos_env
  after_inode="$(ls -i "$SETTINGS_FILE" | awk '{print $1}')"
  [ "$before_inode" = "$after_inode" ]
}

@test "macos: preserves existing unrelated settings" {
  cat >"$SETTINGS_FILE" <<'EOF'
{
  "editor.fontSize": 14,
  "workbench.colorTheme": "Default Dark+"
}
EOF
  setup_vscode_macos_env
  _assert_valid_jsonc "$SETTINGS_FILE"

  local stripped
  stripped="$(_strip_jsonc "$SETTINGS_FILE")"
  run bash -c "printf %s '$stripped' | jq -r '.[\"editor.fontSize\"]'"
  [ "$output" = "14" ]
  run bash -c "printf %s '$stripped' | jq -r '.[\"workbench.colorTheme\"]'"
  [ "$output" = "Default Dark+" ]
  run bash -c "printf %s '$stripped' | jq -r '.[\"todo-tree.ripgrep.ripgrep\"]'"
  [ "$output" = "$NIX_BIN/rg" ]
}

@test "macos: preserves JSONC line, inline, and block comments" {
  cat >"$SETTINGS_FILE" <<'EOF'
{
  // top-level comment
  "editor.fontSize": 14, // inline comment about size
  /* block comment */
  "workbench.colorTheme": "Default Dark+"
}
EOF
  setup_vscode_macos_env

  # Every comment from the input must survive verbatim.
  grep -qF '// top-level comment' "$SETTINGS_FILE"
  grep -qF '// inline comment about size' "$SETTINGS_FILE"
  grep -qF '/* block comment */' "$SETTINGS_FILE"

  # And the new key must have been inserted.
  grep -qF '"todo-tree.ripgrep.ripgrep"' "$SETTINGS_FILE"
}

@test "macos: leaves existing todo-tree.ripgrep.ripgrep value alone" {
  # Detection is by key presence, not value match - the writer respects
  # any path the user has set intentionally (a system rg, a fork, etc.).
  cat >"$SETTINGS_FILE" <<'EOF'
{
  "todo-tree.ripgrep.ripgrep": "/usr/local/bin/rg"
}
EOF
  setup_vscode_macos_env
  _assert_valid_jsonc "$SETTINGS_FILE"

  local stripped
  stripped="$(_strip_jsonc "$SETTINGS_FILE")"
  run bash -c "printf %s '$stripped' | jq -r '.[\"todo-tree.ripgrep.ripgrep\"]'"
  [ "$output" = "/usr/local/bin/rg" ]
}

@test "macos: detects existing nix pwsh under a custom key name" {
  # The user already has nix pwsh registered as 'pwsh (Nix)' (the most
  # common label produced by older setup paths and manual configuration).
  # The function must detect this by VALUE, not by key, and not insert a
  # duplicate entry under the 'nix' key.
  cat >"$SETTINGS_FILE" <<EOF
{
  "powershell.powerShellAdditionalExePaths": {
    "pwsh (Nix)": "$NIX_BIN/pwsh"
  },
  "powershell.powerShellDefaultVersion": "pwsh (Nix)"
}
EOF
  setup_vscode_macos_env
  _assert_valid_jsonc "$SETTINGS_FILE"

  local stripped
  stripped="$(_strip_jsonc "$SETTINGS_FILE")"
  # User's custom key preserved
  run bash -c "printf %s '$stripped' | jq -r '.[\"powershell.powerShellAdditionalExePaths\"][\"pwsh (Nix)\"]'"
  [ "$output" = "$NIX_BIN/pwsh" ]
  # No duplicate 'nix' key inserted
  run bash -c "printf %s '$stripped' | jq -r '.[\"powershell.powerShellAdditionalExePaths\"][\"nix\"] // \"absent\"'"
  [ "$output" = "absent" ]
  # User's chosen default-version preserved
  run bash -c "printf %s '$stripped' | jq -r '.[\"powershell.powerShellDefaultVersion\"]'"
  [ "$output" = "pwsh (Nix)" ]
  # And the ripgrep key was still added (independent of pwsh state)
  run bash -c "printf %s '$stripped' | jq -r '.[\"todo-tree.ripgrep.ripgrep\"]'"
  [ "$output" = "$NIX_BIN/rg" ]
}

@test "macos: handles file ending without trailing comma" {
  cat >"$SETTINGS_FILE" <<'EOF'
{
  "editor.fontSize": 14
}
EOF
  setup_vscode_macos_env
  _assert_valid_jsonc "$SETTINGS_FILE"
}

@test "macos: handles file ending with trailing comma (JSONC)" {
  cat >"$SETTINGS_FILE" <<'EOF'
{
  "editor.fontSize": 14,
}
EOF
  setup_vscode_macos_env
  _assert_valid_jsonc "$SETTINGS_FILE"
}

@test "macos: writes only todo-tree when pwsh missing" {
  rm -f "$NIX_BIN/pwsh"
  setup_vscode_macos_env
  _assert_valid_jsonc "$SETTINGS_FILE"

  local stripped
  stripped="$(_strip_jsonc "$SETTINGS_FILE")"
  run bash -c "printf %s '$stripped' | jq -r '.[\"todo-tree.ripgrep.ripgrep\"]'"
  [ "$output" = "$NIX_BIN/rg" ]
  run bash -c "printf %s '$stripped' | jq -r '.[\"powershell.powerShellAdditionalExePaths\"] // \"absent\"'"
  [ "$output" = "absent" ]
}

@test "macos: writes only pwsh when rg missing" {
  rm -f "$NIX_BIN/rg"
  setup_vscode_macos_env
  _assert_valid_jsonc "$SETTINGS_FILE"

  local stripped
  stripped="$(_strip_jsonc "$SETTINGS_FILE")"
  run bash -c "printf %s '$stripped' | jq -r '.[\"powershell.powerShellAdditionalExePaths\"][\"nix\"]'"
  [ "$output" = "$NIX_BIN/pwsh" ]
  run bash -c "printf %s '$stripped' | jq -r '.[\"todo-tree.ripgrep.ripgrep\"] // \"absent\"'"
  [ "$output" = "absent" ]
}

@test "macos: no-op when neither pwsh nor rg available" {
  rm -f "$NIX_BIN/pwsh" "$NIX_BIN/rg"
  setup_vscode_macos_env
  [ ! -f "$SETTINGS_FILE" ]
}
