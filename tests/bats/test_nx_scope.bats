#!/usr/bin/env bats
# Unit tests for nx scope helpers and scope-aware install/remove validation
# Tests: _nx_scope_pkgs, _nx_scopes, _nx_is_init, _nx_all_scope_pkgs,
#        install scope-check, remove scope-check
# shellcheck disable=SC2030,SC2031
bats_require_minimum_version 1.5.0

setup() {
  TEST_DIR="$(mktemp -d)"
  export HOME="$TEST_DIR"

  # Point nx.sh at .assets/lib/ so the family files load and override
  # _NX_ENV_DIR / _NX_PKG_FILE before sourcing so the constants resolve to
  # the per-test temp dir (nx.sh sets them once at source time).
  export NX_LIB_DIR="$(cd "$BATS_TEST_DIRNAME/../.." && pwd)/.assets/lib"
  _NX_ENV_DIR="$TEST_DIR/nix-env"
  _NX_PKG_FILE="$_NX_ENV_DIR/packages.nix"
  mkdir -p "$_NX_ENV_DIR/scopes"

  # shellcheck source=../../.assets/lib/nx.sh
  source "$NX_LIB_DIR/nx.sh"

  # nx.sh hard-codes the constants from $HOME at source time; reassert the
  # test overrides so the production functions read/write the temp dir.
  _NX_ENV_DIR="$TEST_DIR/nix-env"
  _NX_PKG_FILE="$_NX_ENV_DIR/packages.nix"

  # Default stubs for nix-touching helpers - install/remove tests rely on
  # these. Tests that need different behavior redefine after setup.
  _nx_validate_pkg() { return 0; }
  _nx_apply() { printf 'APPLY_CALLED\n'; }

  # Test-only convenience wrappers that compose production functions.
  _nx_scopes_sorted() {
    _nx_scopes | sort
  }
  _nx_scope_pkgs_sorted() {
    _nx_scope_pkgs "$1" | sort
  }
}

teardown() {
  rm -rf "$TEST_DIR"
}

# =============================================================================
# _nx_scope_pkgs
# =============================================================================

@test "scope_pkgs: parses standard scope file" {
  cat >"$_NX_ENV_DIR/scopes/shell.nix" <<'EOF'
# Shell tools
{ pkgs }: with pkgs; [
  fzf
  eza
  bat
  ripgrep
]
EOF
  run _nx_scope_pkgs "$_NX_ENV_DIR/scopes/shell.nix"
  [ "$status" -eq 0 ]
  [ "${lines[0]}" = "fzf" ]
  [ "${lines[1]}" = "eza" ]
  [ "${lines[2]}" = "bat" ]
  [ "${lines[3]}" = "ripgrep" ]
  [ "${#lines[@]}" -eq 4 ]
}

@test "scope_pkgs: handles inline comments" {
  cat >"$_NX_ENV_DIR/scopes/test.nix" <<'EOF'
{ pkgs }: with pkgs; [
  bind          # provides dig, nslookup, host
  git
  openssl
]
EOF
  run _nx_scope_pkgs "$_NX_ENV_DIR/scopes/test.nix"
  [ "${lines[0]}" = "bind" ]
  [ "${lines[1]}" = "git" ]
  [ "${lines[2]}" = "openssl" ]
  [ "${#lines[@]}" -eq 3 ]
}

@test "scope_pkgs: handles packages with hyphens and underscores" {
  cat >"$_NX_ENV_DIR/scopes/test.nix" <<'EOF'
{ pkgs }: with pkgs; [
  bash-completion
  yq-go
  k9s
]
EOF
  run _nx_scope_pkgs "$_NX_ENV_DIR/scopes/test.nix"
  [ "${lines[0]}" = "bash-completion" ]
  [ "${lines[1]}" = "yq-go" ]
  [ "${lines[2]}" = "k9s" ]
}

@test "scope_pkgs: returns empty for nonexistent file" {
  run _nx_scope_pkgs "$_NX_ENV_DIR/scopes/nonexistent.nix"
  [ "$status" -eq 0 ]
  [ -z "$output" ]
}

@test "scope_pkgs: returns empty for empty list" {
  cat >"$_NX_ENV_DIR/scopes/empty.nix" <<'EOF'
{ pkgs }: with pkgs; [
]
EOF
  run _nx_scope_pkgs "$_NX_ENV_DIR/scopes/empty.nix"
  [ "$status" -eq 0 ]
  [ -z "$output" ]
}

@test "scope_pkgs: ignores comment-only lines inside list" {
  cat >"$_NX_ENV_DIR/scopes/test.nix" <<'EOF'
{ pkgs }: with pkgs; [
  # this is a comment
  git
  # another comment
  jq
]
EOF
  run _nx_scope_pkgs "$_NX_ENV_DIR/scopes/test.nix"
  [ "${lines[0]}" = "git" ]
  [ "${lines[1]}" = "jq" ]
  [ "${#lines[@]}" -eq 2 ]
}

# =============================================================================
# _nx_scopes
# =============================================================================

@test "scopes: returns empty when config.nix missing" {
  run _nx_scopes
  [ "$status" -eq 0 ]
  [ -z "$output" ]
}

@test "scopes: parses config.nix with multiple scopes" {
  cat >"$_NX_ENV_DIR/config.nix" <<'EOF'
{
  isInit = true;

  scopes = [
    "shell"
    "python"
    "docker"
  ];
}
EOF
  run _nx_scopes
  [ "${lines[0]}" = "shell" ]
  [ "${lines[1]}" = "python" ]
  [ "${lines[2]}" = "docker" ]
  [ "${#lines[@]}" -eq 3 ]
}

@test "scopes: parses config.nix with empty scopes" {
  cat >"$_NX_ENV_DIR/config.nix" <<'EOF'
{
  isInit = false;

  scopes = [
  ];
}
EOF
  run _nx_scopes
  [ "$status" -eq 0 ]
  [ -z "$output" ]
}

@test "scopes: parses single scope" {
  cat >"$_NX_ENV_DIR/config.nix" <<'EOF'
{
  isInit = false;

  scopes = [
    "shell"
  ];
}
EOF
  run _nx_scopes
  [ "${lines[0]}" = "shell" ]
  [ "${#lines[@]}" -eq 1 ]
}

# =============================================================================
# _nx_is_init
# =============================================================================

@test "is_init: returns false when config.nix missing" {
  run _nx_is_init
  [ "$output" = "false" ]
}

@test "is_init: returns true when isInit is true" {
  cat >"$_NX_ENV_DIR/config.nix" <<'EOF'
{
  isInit = true;
  scopes = [];
}
EOF
  run _nx_is_init
  [ "$output" = "true" ]
}

@test "is_init: returns false when isInit is false" {
  cat >"$_NX_ENV_DIR/config.nix" <<'EOF'
{
  isInit = false;
  scopes = [];
}
EOF
  run _nx_is_init
  [ "$output" = "false" ]
}

# =============================================================================
# _nx_all_scope_pkgs
# =============================================================================

@test "all_scope_pkgs: includes base packages" {
  cat >"$_NX_ENV_DIR/scopes/base.nix" <<'EOF'
{ pkgs }: with pkgs; [
  git
  jq
]
EOF
  cat >"$_NX_ENV_DIR/config.nix" <<'EOF'
{
  isInit = false;
  scopes = [];
}
EOF
  run _nx_all_scope_pkgs
  [ "${lines[0]}" = "git	base" ]
  [ "${lines[1]}" = "jq	base" ]
  [ "${#lines[@]}" -eq 2 ]
}

@test "all_scope_pkgs: includes base_init when isInit is true" {
  cat >"$_NX_ENV_DIR/scopes/base.nix" <<'EOF'
{ pkgs }: with pkgs; [
  git
]
EOF
  cat >"$_NX_ENV_DIR/scopes/base_init.nix" <<'EOF'
{ pkgs }: with pkgs; [
  nano
]
EOF
  cat >"$_NX_ENV_DIR/config.nix" <<'EOF'
{
  isInit = true;
  scopes = [];
}
EOF
  run _nx_all_scope_pkgs
  [ "${lines[0]}" = "git	base" ]
  [ "${lines[1]}" = "nano	base_init" ]
  [ "${#lines[@]}" -eq 2 ]
}

@test "all_scope_pkgs: excludes base_init when isInit is false" {
  cat >"$_NX_ENV_DIR/scopes/base.nix" <<'EOF'
{ pkgs }: with pkgs; [
  git
]
EOF
  cat >"$_NX_ENV_DIR/scopes/base_init.nix" <<'EOF'
{ pkgs }: with pkgs; [
  nano
]
EOF
  cat >"$_NX_ENV_DIR/config.nix" <<'EOF'
{
  isInit = false;
  scopes = [];
}
EOF
  run _nx_all_scope_pkgs
  [ "${lines[0]}" = "git	base" ]
  [ "${#lines[@]}" -eq 1 ]
}

@test "all_scope_pkgs: includes configured scope packages" {
  cat >"$_NX_ENV_DIR/scopes/base.nix" <<'EOF'
{ pkgs }: with pkgs; [
  git
]
EOF
  cat >"$_NX_ENV_DIR/scopes/shell.nix" <<'EOF'
{ pkgs }: with pkgs; [
  fzf
  bat
]
EOF
  cat >"$_NX_ENV_DIR/config.nix" <<'EOF'
{
  isInit = false;
  scopes = [
    "shell"
  ];
}
EOF
  run _nx_all_scope_pkgs
  [ "${lines[0]}" = "git	base" ]
  [ "${lines[1]}" = "fzf	shell" ]
  [ "${lines[2]}" = "bat	shell" ]
  [ "${#lines[@]}" -eq 3 ]
}

@test "all_scope_pkgs: handles multiple scopes" {
  cat >"$_NX_ENV_DIR/scopes/base.nix" <<'EOF'
{ pkgs }: with pkgs; [
  git
]
EOF
  cat >"$_NX_ENV_DIR/scopes/shell.nix" <<'EOF'
{ pkgs }: with pkgs; [
  fzf
]
EOF
  cat >"$_NX_ENV_DIR/scopes/python.nix" <<'EOF'
{ pkgs }: with pkgs; [
  uv
]
EOF
  cat >"$_NX_ENV_DIR/config.nix" <<'EOF'
{
  isInit = false;
  scopes = [
    "shell"
    "python"
  ];
}
EOF
  run _nx_all_scope_pkgs
  [ "${lines[0]}" = "git	base" ]
  [ "${lines[1]}" = "fzf	shell" ]
  [ "${lines[2]}" = "uv	python" ]
  [ "${#lines[@]}" -eq 3 ]
}

@test "all_scope_pkgs: returns empty when no scopes dir" {
  rmdir "$_NX_ENV_DIR/scopes"
  run _nx_all_scope_pkgs
  [ "$status" -eq 0 ]
  [ -z "$output" ]
}

# =============================================================================
# Install: scope-aware validation - drives the real _nx_pkg_install
# =============================================================================

@test "install: warns when package is already in a scope and does not add it" {
  cat >"$_NX_ENV_DIR/scopes/base.nix" <<'EOF'
{ pkgs }: with pkgs; [
  git
  jq
]
EOF
  cat >"$_NX_ENV_DIR/config.nix" <<'EOF'
{
  isInit = false;
  scopes = [];
}
EOF
  run _nx_pkg_install git
  [[ "$output" == *"already installed in scope 'base'"* ]]
  # should NOT add git to the user package list
  [ ! -s "$_NX_PKG_FILE" ] || ! grep -q '"git"' "$_NX_PKG_FILE"
}

@test "install: adds package not in any scope to the user list" {
  cat >"$_NX_ENV_DIR/scopes/base.nix" <<'EOF'
{ pkgs }: with pkgs; [
  git
]
EOF
  cat >"$_NX_ENV_DIR/config.nix" <<'EOF'
{
  isInit = false;
  scopes = [];
}
EOF
  run _nx_pkg_install ripgrep
  [[ "$output" == *"added ripgrep"* ]]
  [[ "$output" == *"APPLY_CALLED"* ]]
  run grep -q '"ripgrep"' "$_NX_PKG_FILE"
  [ "$status" -eq 0 ]
}

@test "install: warns when package is in a configured non-base scope" {
  cat >"$_NX_ENV_DIR/scopes/base.nix" <<'EOF'
{ pkgs }: with pkgs; [
  git
]
EOF
  cat >"$_NX_ENV_DIR/scopes/shell.nix" <<'EOF'
{ pkgs }: with pkgs; [
  fzf
  bat
]
EOF
  cat >"$_NX_ENV_DIR/config.nix" <<'EOF'
{
  isInit = false;
  scopes = [
    "shell"
  ];
}
EOF
  run _nx_pkg_install bat
  [[ "$output" == *"already installed in scope 'shell'"* ]]
}

@test "install: does not false-match a pkg whose name is a regex prefix of a scope pkg [F-004]" {
  # Regression: scope-detection used `grep -m1 "^${p}\t"` which interpolated
  # the pkg name into a regex. nixpkgs names commonly contain regex
  # metacharacters (`.`, `+`, `_`) - so `python3` could falsely match
  # `python311` and the user would be told the (different) pkg they asked
  # for "is already installed in scope X". Use awk's explicit column-1
  # equality check instead. Only `python311` is in the scope list here;
  # `python3` is a different pkg that the user actually wants installed.
  cat >"$_NX_ENV_DIR/scopes/python.nix" <<'EOF'
{ pkgs }: with pkgs; [
  python311
]
EOF
  cat >"$_NX_ENV_DIR/config.nix" <<'EOF'
{
  isInit = false;
  scopes = [
    "python"
  ];
}
EOF
  run _nx_pkg_install python3
  # Must NOT report python3 as already-in-scope (the false-positive case).
  [[ "$output" != *"already installed in scope"* ]]
  # python3 should land in the user package list (added cleanly).
  [[ "$output" == *"added python3"* ]]
  run grep -q '"python3"' "$_NX_PKG_FILE"
  [ "$status" -eq 0 ]
}

@test "install: warns when the package is already in the user list (extra)" {
  cat >"$_NX_ENV_DIR/scopes/base.nix" <<'EOF'
{ pkgs }: with pkgs; [
  git
]
EOF
  cat >"$_NX_ENV_DIR/config.nix" <<'EOF'
{
  isInit = false;
  scopes = [];
}
EOF
  printf 'ripgrep\nfd\n' | _nx_write_pkgs
  run _nx_pkg_install ripgrep
  [[ "$output" == *"ripgrep is already installed (extra)"* ]]
}

# =============================================================================
# Remove: scope-aware validation - drives the real _nx_pkg_remove
# =============================================================================

@test "remove: refuses to remove a scope-managed package" {
  cat >"$_NX_ENV_DIR/scopes/base.nix" <<'EOF'
{ pkgs }: with pkgs; [
  git
]
EOF
  cat >"$_NX_ENV_DIR/scopes/shell.nix" <<'EOF'
{ pkgs }: with pkgs; [
  bat
]
EOF
  cat >"$_NX_ENV_DIR/config.nix" <<'EOF'
{
  isInit = false;
  scopes = [
    "shell"
  ];
}
EOF
  printf 'ripgrep\n' | _nx_write_pkgs
  run _nx_pkg_remove bat
  [[ "$output" == *"managed by scope 'shell'"* ]]
  # bat must NOT be removed from anywhere; ripgrep stays in user list
  run grep -q '"ripgrep"' "$_NX_PKG_FILE"
  [ "$status" -eq 0 ]
}

@test "remove: removes a non-scope package from the user list" {
  cat >"$_NX_ENV_DIR/scopes/base.nix" <<'EOF'
{ pkgs }: with pkgs; [
  git
]
EOF
  cat >"$_NX_ENV_DIR/config.nix" <<'EOF'
{
  isInit = false;
  scopes = [];
}
EOF
  printf 'ripgrep\nfd\n' | _nx_write_pkgs
  run _nx_pkg_remove ripgrep
  [[ "$output" == *"removed ripgrep"* ]]
  [[ "$output" == *"APPLY_CALLED"* ]]
  run ! grep -q '"ripgrep"' "$_NX_PKG_FILE"
  run grep -q '"fd"' "$_NX_PKG_FILE"
  [ "$status" -eq 0 ]
}

@test "remove: filters scope-managed args and removes only the eligible ones" {
  cat >"$_NX_ENV_DIR/scopes/base.nix" <<'EOF'
{ pkgs }: with pkgs; [
  git
]
EOF
  cat >"$_NX_ENV_DIR/config.nix" <<'EOF'
{
  isInit = false;
  scopes = [];
}
EOF
  printf 'ripgrep\nfd\n' | _nx_write_pkgs
  run _nx_pkg_remove git ripgrep fd
  # git stays (scope-managed); ripgrep + fd come out of the user list
  [[ "$output" == *"managed by scope 'base'"* ]]
  [[ "$output" == *"removed ripgrep"* ]]
  [[ "$output" == *"removed fd"* ]]
  run ! grep -q '"ripgrep"' "$_NX_PKG_FILE"
  run ! grep -q '"fd"' "$_NX_PKG_FILE"
}

# =============================================================================
# scope list: sorted output
# =============================================================================

@test "scope list: returns scopes in sorted order" {
  cat >"$_NX_ENV_DIR/config.nix" <<'EOF'
{
  isInit = false;

  scopes = [
    "python"
    "shell"
    "az"
    "k8s_base"
  ];
}
EOF
  run _nx_scopes_sorted
  [ "${lines[0]}" = "az" ]
  [ "${lines[1]}" = "k8s_base" ]
  [ "${lines[2]}" = "python" ]
  [ "${lines[3]}" = "shell" ]
  [ "${#lines[@]}" -eq 4 ]
}

@test "scope list: single scope stays unchanged" {
  cat >"$_NX_ENV_DIR/config.nix" <<'EOF'
{
  isInit = false;

  scopes = [
    "shell"
  ];
}
EOF
  run _nx_scopes_sorted
  [ "${lines[0]}" = "shell" ]
  [ "${#lines[@]}" -eq 1 ]
}

# =============================================================================
# scope tree: sorted scopes and packages
# =============================================================================

@test "scope tree: packages within a scope are sorted" {
  cat >"$_NX_ENV_DIR/scopes/shell.nix" <<'EOF'
{ pkgs }: with pkgs; [
  ripgrep
  bat
  fzf
  eza
]
EOF
  run _nx_scope_pkgs_sorted "$_NX_ENV_DIR/scopes/shell.nix"
  [ "${lines[0]}" = "bat" ]
  [ "${lines[1]}" = "eza" ]
  [ "${lines[2]}" = "fzf" ]
  [ "${lines[3]}" = "ripgrep" ]
  [ "${#lines[@]}" -eq 4 ]
}

@test "scope tree: empty scope file returns nothing" {
  cat >"$_NX_ENV_DIR/scopes/empty.nix" <<'EOF'
{ pkgs }: with pkgs; []
EOF
  run _nx_scope_pkgs_sorted "$_NX_ENV_DIR/scopes/empty.nix"
  [ "$status" -eq 0 ]
  [ -z "$output" ]
}

# =============================================================================
# scope edit: overlay vs repo-managed distinction - drives _nx_scope_dispatch
# =============================================================================

@test "scope edit: opens overlay scope file" {
  local ov_dir="$_NX_ENV_DIR/local"
  mkdir -p "$ov_dir/scopes"
  cat >"$ov_dir/scopes/tools.nix" <<'EOF'
{ pkgs }: with pkgs; [ htop ]
EOF
  # Stub EDITOR to a no-op so the test doesn't try to open vi.
  EDITOR=true NIX_ENV_OVERLAY_DIR="$ov_dir" run _nx_scope_dispatch edit tools
  [ "$status" -eq 0 ]
  [[ "$output" == *"Synced scope 'tools'"* ]]
}

@test "scope edit: repo-managed scope is read-only and returns non-zero" {
  cat >"$_NX_ENV_DIR/scopes/k8s_dev.nix" <<'EOF'
{ pkgs }: with pkgs; [ helm ]
EOF
  EDITOR=true run _nx_scope_dispatch edit k8s_dev
  [ "$status" -eq 1 ]
  [[ "$output" == *"managed by the base repository"* ]]
}

@test "scope edit: missing scope returns non-zero" {
  EDITOR=true run _nx_scope_dispatch edit nonexistent
  [ "$status" -eq 1 ]
  [[ "$output" == *"not found"* ]]
}
