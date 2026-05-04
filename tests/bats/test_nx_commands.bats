#!/usr/bin/env bats
# Unit tests for nx CLI commands (pin, rollback, scope remove, scope edit, help)
bats_require_minimum_version 1.5.0

NX_SCRIPT="$(cd "$(dirname "$BATS_TEST_FILENAME")/../.." && pwd)/.assets/lib/nx.sh"

setup() {
  TEST_DIR="$(mktemp -d)"
  export HOME="$TEST_DIR"

  mkdir -p "$TEST_DIR/bin"
  printf '#!/bin/sh\nexit 0\n' >"$TEST_DIR/bin/nix"
  chmod +x "$TEST_DIR/bin/nix"
  export PATH="$TEST_DIR/bin:$PATH"

  ENV_DIR="$HOME/.config/nix-env"
  mkdir -p "$ENV_DIR/scopes"

  # shellcheck source=../../.assets/lib/nx.sh
  source "$NX_SCRIPT"
  nx() { nx_main "$@"; }
}

teardown() {
  rm -rf "$TEST_DIR"
}

# -- help ---------------------------------------------------------------------

@test "nx help shows usage" {
  run nx help
  [ "$status" -eq 0 ]
  [[ "$output" == *"Usage: nx"* ]]
  [[ "$output" == *"install"* ]]
  [[ "$output" == *"upgrade"* ]]
  [[ "$output" == *"pin"* ]]
  [[ "$output" == *"rollback"* ]]
}

@test "nx without args shows help" {
  run nx
  [ "$status" -eq 0 ]
  [[ "$output" == *"Usage: nx"* ]]
}

@test "nx unknown command shows error" {
  run nx fakecmd
  [ "$status" -eq 1 ]
  [[ "$output" == *"Unknown command"* ]]
}

# -- scope help (no default to list) ------------------------------------------

@test "nx scope without subcommand shows help" {
  run nx scope
  [ "$status" -eq 0 ]
  [[ "$output" == *"Usage: nx scope"* ]]
  [[ "$output" == *"list"* ]]
  [[ "$output" == *"add"* ]]
  [[ "$output" == *"edit"* ]]
  [[ "$output" == *"remove"* ]]
}

# -- pin set (no args = read from flake.lock) ---------------------------------

@test "pin set without rev reads from flake.lock" {
  cat >"$ENV_DIR/flake.lock" <<'EOF'
{
  "nodes": {
    "nixpkgs": {
      "locked": {
        "rev": "abc123def456"
      }
    }
  }
}
EOF
  run nx pin set
  [ "$status" -eq 0 ]
  [[ "$output" == *"Pinned nixpkgs to abc123def456"* ]]
  [ -f "$ENV_DIR/pinned_rev" ]
  [ "$(tr -d '[:space:]' <"$ENV_DIR/pinned_rev")" = "abc123def456" ]
}

@test "pin set with explicit rev uses that rev" {
  run nx pin set deadbeef123
  [ "$status" -eq 0 ]
  [[ "$output" == *"Pinned nixpkgs to deadbeef123"* ]]
  [ "$(tr -d '[:space:]' <"$ENV_DIR/pinned_rev")" = "deadbeef123" ]
}

@test "pin set without rev fails when no flake.lock" {
  run nx pin set
  [ "$status" -eq 1 ]
  [[ "$output" == *"No flake.lock found"* ]]
}

@test "pin set overwrites existing pin" {
  printf 'oldrev\n' >"$ENV_DIR/pinned_rev"
  run nx pin set newrev
  [ "$status" -eq 0 ]
  [ "$(tr -d '[:space:]' <"$ENV_DIR/pinned_rev")" = "newrev" ]
}

# -- pin show -----------------------------------------------------------------

@test "pin show displays current pin" {
  printf 'abc123\n' >"$ENV_DIR/pinned_rev"
  run nx pin show
  [ "$status" -eq 0 ]
  [[ "$output" == *"Pinned to:"* ]]
  [[ "$output" == *"abc123"* ]]
}

@test "pin show reports no pin when file missing" {
  run nx pin show
  [ "$status" -eq 0 ]
  [[ "$output" == *"No pin set"* ]]
}

# -- pin remove ---------------------------------------------------------------

@test "pin remove deletes pin file" {
  printf 'abc123\n' >"$ENV_DIR/pinned_rev"
  run nx pin remove
  [ "$status" -eq 0 ]
  [[ "$output" == *"Pin removed"* ]]
  [ ! -f "$ENV_DIR/pinned_rev" ]
}

@test "pin remove reports no pin when file missing" {
  run nx pin remove
  [ "$status" -eq 0 ]
  [[ "$output" == *"No pin set"* ]]
}

# -- pin help -----------------------------------------------------------------

@test "pin help shows usage" {
  run nx pin help
  [ "$status" -eq 0 ]
  [[ "$output" == *"Usage: nx pin"* ]]
  [[ "$output" == *"set"* ]]
  [[ "$output" == *"remove"* ]]
  [[ "$output" == *"show"* ]]
}

@test "pin without subcommand shows current pin status" {
  run nx pin
  [ "$status" -eq 0 ]
  [[ "$output" == *"No pin set"* ]]
}

# -- upgrade with pinned_rev --------------------------------------------------

@test "upgrade reads pinned_rev file when present" {
  printf 'pinnedabc123\n' >"$ENV_DIR/pinned_rev"
  run nx upgrade
  [ "$status" -eq 0 ]
  [[ "$output" == *"pinning nixpkgs to pinnedabc123"* ]]
}

@test "upgrade without pin does normal update" {
  run nx upgrade
  [ "$status" -eq 0 ]
  [[ "$output" != *"pinning nixpkgs"* ]]
}

# -- scope remove with local_ prefix -----------------------------------------

@test "scope remove handles local_ prefix transparently" {
  cat >"$ENV_DIR/config.nix" <<'EOF'
{
  isInit = false;
  scopes = [
    "shell"
    "local_devtools"
  ];
}
EOF
  mkdir -p "$ENV_DIR/local/scopes"
  printf '{ pkgs }: with pkgs; []\n' >"$ENV_DIR/local/scopes/devtools.nix"
  printf '{ pkgs }: with pkgs; []\n' >"$ENV_DIR/scopes/local_devtools.nix"

  run nx scope remove devtools
  [ "$status" -eq 0 ]
  [[ "$output" == *"removed scope: devtools"* ]]
  # config.nix should no longer have local_devtools
  run ! grep -q 'local_devtools' "$ENV_DIR/config.nix"
  # scope files should be cleaned up
  [ ! -f "$ENV_DIR/local/scopes/devtools.nix" ]
  [ ! -f "$ENV_DIR/scopes/local_devtools.nix" ]
}

@test "scope remove handles repo scope by name" {
  cat >"$ENV_DIR/config.nix" <<'EOF'
{
  isInit = false;
  scopes = [
    "shell"
    "python"
  ];
}
EOF
  run nx scope remove python
  [ "$status" -eq 0 ]
  [[ "$output" == *"removed scope: python"* ]]
  run ! grep -q '"python"' "$ENV_DIR/config.nix"
  grep -q '"shell"' "$ENV_DIR/config.nix"
}

@test "scope remove cleans orphaned overlay files" {
  cat >"$ENV_DIR/config.nix" <<'EOF'
{
  isInit = false;
  scopes = [
    "shell"
  ];
}
EOF
  mkdir -p "$ENV_DIR/local/scopes"
  printf '{ pkgs }: with pkgs; []\n' >"$ENV_DIR/local/scopes/orphan.nix"
  printf '{ pkgs }: with pkgs; []\n' >"$ENV_DIR/scopes/local_orphan.nix"

  run nx scope remove orphan
  [ "$status" -eq 0 ]
  [ ! -f "$ENV_DIR/local/scopes/orphan.nix" ]
  [ ! -f "$ENV_DIR/scopes/local_orphan.nix" ]
}

@test "scope remove multiple scopes at once" {
  cat >"$ENV_DIR/config.nix" <<'EOF'
{
  isInit = false;
  scopes = [
    "shell"
    "python"
    "local_devtools"
  ];
}
EOF
  mkdir -p "$ENV_DIR/local/scopes"
  printf '{ pkgs }: with pkgs; []\n' >"$ENV_DIR/local/scopes/devtools.nix"
  printf '{ pkgs }: with pkgs; []\n' >"$ENV_DIR/scopes/local_devtools.nix"

  run nx scope remove python devtools
  [ "$status" -eq 0 ]
  [[ "$output" == *"removed scope: python"* ]]
  [[ "$output" == *"removed scope: devtools"* ]]
  grep -q '"shell"' "$ENV_DIR/config.nix"
  run ! grep -q '"python"' "$ENV_DIR/config.nix"
  run ! grep -q 'local_devtools' "$ENV_DIR/config.nix"
}

@test "scope remove reports unknown scope" {
  cat >"$ENV_DIR/config.nix" <<'EOF'
{
  isInit = false;
  scopes = [
    "shell"
  ];
}
EOF
  run nx scope remove nonexistent
  [[ "$output" == *"is not configured"* ]]
}

# -- scope edit ---------------------------------------------------------------

@test "scope edit fails for nonexistent scope" {
  run nx scope edit nonexistent
  [ "$status" -eq 1 ]
  [[ "$output" == *"not found"* ]]
}

@test "scope edit opens file and syncs copy" {
  mkdir -p "$ENV_DIR/local/scopes"
  printf '{ pkgs }: with pkgs; []\n' >"$ENV_DIR/local/scopes/mytools.nix"
  # use 'true' as EDITOR to simulate a no-op edit
  EDITOR=true run nx scope edit mytools
  [ "$status" -eq 0 ]
  [[ "$output" == *"Synced scope"* ]]
  [ -f "$ENV_DIR/scopes/local_mytools.nix" ]
}

@test "scope edit falls back to vi when EDITOR unset" {
  mkdir -p "$ENV_DIR/local/scopes"
  printf '{ pkgs }: with pkgs; []\n' >"$ENV_DIR/local/scopes/mytools.nix"
  # create a fake vi that exits immediately
  printf '#!/bin/sh\nexit 0\n' >"$TEST_DIR/bin/vi"
  chmod +x "$TEST_DIR/bin/vi"
  unset EDITOR
  run nx scope edit mytools
  [ "$status" -eq 0 ]
}

# -- scope add with packages (validation stubbed) ----------------------------

@test "scope add creates scope and reports guidance" {
  cat >"$ENV_DIR/config.nix" <<'EOF'
{
  isInit = false;
  scopes = [];
}
EOF
  run nx scope add newscope
  [ "$status" -eq 0 ]
  [[ "$output" == *"Created scope"* ]]
  [[ "$output" == *"nx scope add newscope"* ]]
  [ -f "$ENV_DIR/local/scopes/newscope.nix" ]
}

@test "scope add to existing scope without packages shows hint" {
  mkdir -p "$ENV_DIR/local/scopes"
  printf '{ pkgs }: with pkgs; []\n' >"$ENV_DIR/local/scopes/existing.nix"
  run nx scope add existing
  [ "$status" -eq 0 ]
  [[ "$output" == *"already exists"* ]]
}

# -- scope list ---------------------------------------------------------------

@test "scope list shows installed scopes" {
  cat >"$ENV_DIR/config.nix" <<'EOF'
{
  isInit = false;
  scopes = [
    "shell"
    "python"
  ];
}
EOF
  run nx scope list
  [ "$status" -eq 0 ]
  [[ "$output" == *"shell"* ]]
  [[ "$output" == *"python"* ]]
}

@test "scope list shows local scopes with indicator" {
  cat >"$ENV_DIR/config.nix" <<'EOF'
{
  isInit = false;
  scopes = [
    "shell"
    "local_devtools"
  ];
}
EOF
  run nx scope list
  [ "$status" -eq 0 ]
  [[ "$output" == *"devtools"* ]]
  [[ "$output" == *"(local)"* ]]
  # should not show the local_ prefix
  run ! grep -q 'local_devtools' <<<"$output"
}

@test "scope list discovers orphaned local scopes from filesystem" {
  cat >"$ENV_DIR/config.nix" <<'EOF'
{
  isInit = false;
  scopes = [
    "shell"
  ];
}
EOF
  # local_test.nix exists on disk but "local_test" is NOT in config.nix
  printf '{ pkgs }: with pkgs; []\n' >"$ENV_DIR/scopes/local_test.nix"
  run nx scope list
  [ "$status" -eq 0 ]
  [[ "$output" == *"shell"* ]]
  [[ "$output" == *"test"* ]]
  [[ "$output" == *"(local)"* ]]
}

@test "scope list shows no scopes when empty" {
  cat >"$ENV_DIR/config.nix" <<'EOF'
{
  isInit = false;
  scopes = [];
}
EOF
  run nx scope list
  [ "$status" -eq 0 ]
  [[ "$output" == *"No scopes"* ]]
}

# -- scope show ---------------------------------------------------------------

@test "scope show displays packages in a scope" {
  cat >"$ENV_DIR/config.nix" <<'EOF'
{
  isInit = false;
  scopes = [
    "shell"
  ];
}
EOF
  cat >"$ENV_DIR/scopes/shell.nix" <<'EOF'
{ pkgs }: with pkgs; [
  fzf
  bat
  ripgrep
]
EOF
  run nx scope show shell
  [ "$status" -eq 0 ]
  [[ "$output" == *"fzf"* ]]
  [[ "$output" == *"bat"* ]]
  [[ "$output" == *"ripgrep"* ]]
}

@test "scope show reports unknown scope" {
  run nx scope show nonexistent
  [[ "$output" == *"not found"* ]] || [[ "$output" == *"No scope file"* ]]
}

# -- scope tree ---------------------------------------------------------------

@test "scope tree shows scopes with packages" {
  cat >"$ENV_DIR/config.nix" <<'EOF'
{
  isInit = false;
  scopes = [
    "shell"
  ];
}
EOF
  cat >"$ENV_DIR/scopes/shell.nix" <<'EOF'
{ pkgs }: with pkgs; [
  fzf
  bat
]
EOF
  cat >"$ENV_DIR/scopes/base.nix" <<'EOF'
{ pkgs }: with pkgs; [
  git
]
EOF
  run nx scope tree
  [ "$status" -eq 0 ]
  [[ "$output" == *"shell"* ]]
  [[ "$output" == *"fzf"* ]]
}

# -- _nx_scope_file_add helper ------------------------------------------------

@test "scope_file_add adds packages to scope file" {
  local file="$TEST_DIR/test.nix"
  printf '{ pkgs }: with pkgs; []\n' >"$file"
  _nx_scope_file_add "$file" httpie jq
  # verify the file contains the packages
  grep -q 'httpie' "$file"
  grep -q 'jq' "$file"
}

@test "scope_file_add deduplicates existing packages" {
  local file="$TEST_DIR/test.nix"
  cat >"$file" <<'EOF'
{ pkgs }: with pkgs; [
  httpie
]
EOF
  run _nx_scope_file_add "$file" httpie
  [[ "$output" == *"already in scope"* ]]
}

@test "scope_file_add sorts packages" {
  local file="$TEST_DIR/test.nix"
  printf '{ pkgs }: with pkgs; []\n' >"$file"
  _nx_scope_file_add "$file" zoxide bat httpie
  # read in order
  local pkgs
  pkgs="$(_nx_scope_pkgs "$file")"
  local first second third
  first="$(echo "$pkgs" | sed -n '1p')"
  second="$(echo "$pkgs" | sed -n '2p')"
  third="$(echo "$pkgs" | sed -n '3p')"
  [ "$first" = "bat" ]
  [ "$second" = "httpie" ]
  [ "$third" = "zoxide" ]
}

# -- _nx_validate_pkg helper --------------------------------------------------

@test "validate_pkg returns success for valid package" {
  # override nix to echo a name
  printf '#!/bin/sh\necho "test-1.0"\n' >"$TEST_DIR/bin/nix"
  chmod +x "$TEST_DIR/bin/nix"
  run _nx_validate_pkg testpkg
  [ "$status" -eq 0 ]
}

@test "validate_pkg returns failure for invalid package" {
  printf '#!/bin/sh\nexit 1\n' >"$TEST_DIR/bin/nix"
  chmod +x "$TEST_DIR/bin/nix"
  run _nx_validate_pkg fakepkg
  [ "$status" -ne 0 ]
}

# -- rollback -----------------------------------------------------------------

@test "rollback succeeds when nix profile rollback succeeds" {
  run nx rollback
  [ "$status" -eq 0 ]
  [[ "$output" == *"Rolled back"* ]]
  [[ "$output" == *"Restart your shell"* ]]
}

@test "rollback fails when nix profile rollback fails" {
  printf '#!/bin/sh\nexit 1\n' >"$TEST_DIR/bin/nix"
  chmod +x "$TEST_DIR/bin/nix"
  run nx rollback
  [ "$status" -eq 1 ]
  [[ "$output" == *"rollback failed"* ]]
}

# -- profile ------------------------------------------------------------------

@test "profile help shows usage with regenerate" {
  run nx profile help
  [ "$status" -eq 0 ]
  [[ "$output" == *"Usage: nx profile"* ]]
  [[ "$output" == *"regenerate"* ]]
  [[ "$output" == *"doctor"* ]]
}

@test "profile regenerate creates managed blocks" {
  # create profile_block.sh stub
  mkdir -p "$HOME/.config/nix-env"
  cat >"$HOME/.config/nix-env/profile_block.sh" <<'PBEOF'
_pb_begin_tag() { printf '# >>> %s >>>' "$1"; }
_pb_end_tag()   { printf '# <<< %s <<<' "$1"; }
_pb_count_occurrences() {
  local rc="$1" marker="$2" tag
  tag="$(_pb_begin_tag "$marker")"
  grep -cF "$tag" "$rc" 2>/dev/null || true
}
_pb_normalize_trailing() {
  awk '/^[[:space:]]*$/{blank++;next}{for(i=0;i<blank;i++)print"";blank=0;print}'
}
manage_block() {
  local rc="$1" marker="$2" action="$3" content_file="${4:-}"
  [ -f "$rc" ] || touch "$rc"
  local begin_tag end_tag
  begin_tag="$(_pb_begin_tag "$marker")"
  end_tag="$(_pb_end_tag "$marker")"
  case "$action" in
  remove)
    local count
    count="$(_pb_count_occurrences "$rc" "$marker")"
    [ "$count" -eq 0 ] 2>/dev/null && return 0
    local tmp; tmp="$(mktemp)"
    awk -v begin="$begin_tag" -v end="$end_tag" '
      $0==begin{skip=1;next} skip&&$0==end{skip=0;next} !skip{print}
    ' "$rc" | _pb_normalize_trailing >"$tmp"
    mv -f "$tmp" "$rc"
    ;;
  upsert)
    local tmp new_block count
    count="$(_pb_count_occurrences "$rc" "$marker")"
    tmp="$(mktemp)"
    new_block="$(printf '%s\n' "$begin_tag"; cat "$content_file"; printf '%s\n' "$end_tag")"
    if [ "$count" -eq 0 ] 2>/dev/null; then
      { [ -s "$rc" ] && cat "$rc" && printf '\n'; printf '%s\n' "$new_block"; } | _pb_normalize_trailing >"$tmp"
    else
      awk -v begin="$begin_tag" -v end="$end_tag" -v replacement="$new_block" '
        BEGIN{done=0;skip=0} $0==begin{if(!done){print replacement;done=1} skip=1;next}
        skip&&$0==end{skip=0;next} !skip{print}
      ' "$rc" | _pb_normalize_trailing >"$tmp"
    fi
    mv -f "$tmp" "$rc"
    ;;
  esac
}
PBEOF
  touch "$HOME/.bashrc"
  run nx profile regenerate
  [ "$status" -eq 0 ]
  [[ "$output" == *"Regenerated"* ]]
  grep -qF '# >>> env:managed >>>' "$HOME/.bashrc"
  grep -qF '# >>> nix:managed >>>' "$HOME/.bashrc"
}

# -- overlay help -------------------------------------------------------------

@test "overlay help shows usage" {
  run nx overlay help
  [ "$status" -eq 0 ]
  [[ "$output" == *"Usage: nx overlay"* ]]
  [[ "$output" == *"nx scope list"* ]]
}

# -- install/remove: _nx_apply integration ------------------------------------

@test "install calls _nx_apply after adding a package" {
  _nx_validate_pkg() { return 0; }
  _nx_apply() { printf 'APPLY_CALLED\n'; }
  cat >"$ENV_DIR/scopes/base.nix" <<'EOF'
{ pkgs }: with pkgs; [ git ]
EOF
  cat >"$ENV_DIR/config.nix" <<'EOF'
{ isInit = false; scopes = []; }
EOF
  run nx install ripgrep
  [[ "$output" == *"APPLY_CALLED"* ]]
}

@test "remove calls _nx_apply after removing a package" {
  _nx_apply() { printf 'APPLY_CALLED\n'; }
  cat >"$ENV_DIR/scopes/base.nix" <<'EOF'
{ pkgs }: with pkgs; [ git ]
EOF
  cat >"$ENV_DIR/config.nix" <<'EOF'
{ isInit = false; scopes = []; }
EOF
  printf 'ripgrep\nfd\n' | _nx_write_pkgs
  run nx remove ripgrep
  [[ "$output" == *"APPLY_CALLED"* ]]
}

# -- search -------------------------------------------------------------------

@test "search without query shows usage" {
  run nx search
  [ "$status" -eq 1 ]
  [[ "$output" == *"Usage: nx search"* ]]
}

@test "search calls nix search with query" {
  cat >"$TEST_DIR/bin/nix" <<'STUB'
#!/bin/sh
echo "nix_args: $*"
STUB
  chmod +x "$TEST_DIR/bin/nix"
  # stub jq to pass through (search pipes through jq)
  cat >"$TEST_DIR/bin/jq" <<'STUB'
#!/bin/sh
cat
STUB
  chmod +x "$TEST_DIR/bin/jq"
  run nx search ripgrep
  [[ "$output" == *"nixpkgs"* ]]
  [[ "$output" == *"ripgrep"* ]]
}

@test "search passes multi-word query" {
  cat >"$TEST_DIR/bin/nix" <<'STUB'
#!/bin/sh
echo "nix_args: $*"
STUB
  chmod +x "$TEST_DIR/bin/nix"
  cat >"$TEST_DIR/bin/jq" <<'STUB'
#!/bin/sh
cat
STUB
  chmod +x "$TEST_DIR/bin/jq"
  run nx search python web
  [[ "$output" == *"python web"* ]]
}

# -- gc / clean ---------------------------------------------------------------

@test "gc calls nix profile wipe-history and store gc" {
  cat >"$TEST_DIR/bin/nix" <<'STUB'
#!/bin/sh
echo "$*" >> "$HOME/.nix_calls"
STUB
  chmod +x "$TEST_DIR/bin/nix"
  run nx gc
  [ "$status" -eq 0 ]
  grep -q 'profile wipe-history' "$HOME/.nix_calls"
  grep -q 'store gc' "$HOME/.nix_calls"
}

@test "clean is an alias for gc" {
  cat >"$TEST_DIR/bin/nix" <<'STUB'
#!/bin/sh
echo "$*" >> "$HOME/.nix_calls"
STUB
  chmod +x "$TEST_DIR/bin/nix"
  run nx clean
  [ "$status" -eq 0 ]
  grep -q 'profile wipe-history' "$HOME/.nix_calls"
  grep -q 'store gc' "$HOME/.nix_calls"
}

@test "gc clears stale pwsh module-analysis cache files" {
  cat >"$TEST_DIR/bin/nix" <<'STUB'
#!/bin/sh
exit 0
STUB
  chmod +x "$TEST_DIR/bin/nix"
  mkdir -p "$HOME/.cache/powershell"
  : >"$HOME/.cache/powershell/ModuleAnalysisCache-DEAD"
  : >"$HOME/.cache/powershell/StartupProfileData-Interactive"
  : >"$HOME/.cache/powershell/PowerShellGet" # unrelated, must be kept
  run nx gc
  [ "$status" -eq 0 ]
  [[ "$output" == *"Cleared"*"PowerShell cache"* ]]
  [ ! -e "$HOME/.cache/powershell/ModuleAnalysisCache-DEAD" ]
  [ ! -e "$HOME/.cache/powershell/StartupProfileData-Interactive" ]
  [ -e "$HOME/.cache/powershell/PowerShellGet" ]
}

@test "gc is silent when pwsh cache dir is absent" {
  cat >"$TEST_DIR/bin/nix" <<'STUB'
#!/bin/sh
exit 0
STUB
  chmod +x "$TEST_DIR/bin/nix"
  [ ! -d "$HOME/.cache/powershell" ]
  run nx gc
  [ "$status" -eq 0 ]
  [[ "$output" != *"Cleared"* ]]
}

@test "upgrade clears stale pwsh module-analysis cache files" {
  cat >"$TEST_DIR/bin/nix" <<'STUB'
#!/bin/sh
exit 0
STUB
  chmod +x "$TEST_DIR/bin/nix"
  mkdir -p "$HOME/.cache/powershell"
  : >"$HOME/.cache/powershell/ModuleAnalysisCache-CAFE"
  run nx upgrade
  [ "$status" -eq 0 ]
  [[ "$output" == *"Cleared"*"PowerShell cache"* ]]
  [ ! -e "$HOME/.cache/powershell/ModuleAnalysisCache-CAFE" ]
}

# -- prune --------------------------------------------------------------------

@test "prune removes stale entries" {
  cat >"$TEST_DIR/bin/nix" <<'STUB'
#!/bin/sh
if [ "$1" = "profile" ] && [ "$2" = "list" ]; then
  cat <<'JSON'
{"elements":{"nix-env":{},"stale-pkg":{}}}
JSON
elif [ "$1" = "profile" ] && [ "$2" = "remove" ]; then
  echo "removed $3"
fi
STUB
  chmod +x "$TEST_DIR/bin/nix"
  run nx prune
  [ "$status" -eq 0 ]
  [[ "$output" == *"stale-pkg"* ]]
  [[ "$output" == *"removed"* ]]
}

@test "prune reports no stale entries" {
  cat >"$TEST_DIR/bin/nix" <<'STUB'
#!/bin/sh
cat <<'JSON'
{"elements":{"nix-env":{}}}
JSON
STUB
  chmod +x "$TEST_DIR/bin/nix"
  run nx prune
  [ "$status" -eq 0 ]
  [[ "$output" == *"No stale"* ]]
}

@test "prune fails on profile list error" {
  printf '#!/bin/sh\nexit 1\n' >"$TEST_DIR/bin/nix"
  chmod +x "$TEST_DIR/bin/nix"
  run nx prune
  [ "$status" -eq 1 ]
  [[ "$output" == *"Failed"* ]]
}

# -- version ------------------------------------------------------------------

@test "version shows provenance from install.json" {
  mkdir -p "$HOME/.config/dev-env"
  cat >"$HOME/.config/dev-env/install.json" <<'EOF'
{
  "entry_point": "nix",
  "version": "1.0.0",
  "source": "git",
  "source_ref": "abc123def456789",
  "scopes": ["shell", "python"],
  "installed_at": "2026-04-25T12:00:00Z",
  "mode": "install",
  "status": "success",
  "phase": "done",
  "platform": "Linux",
  "arch": "x86_64",
  "nix_version": "nix 2.28.0",
  "error": "",
  "allow_unfree": false,
  "installed_by": "testuser",
  "shell": "/bin/bash"
}
EOF
  run nx version
  [ "$status" -eq 0 ]
  [[ "$output" == *"1.0.0"* ]]
  [[ "$output" == *"git"* ]]
  [[ "$output" == *"shell, python"* ]]
}

@test "version without install.json shows warning" {
  run nx version
  [ "$status" -eq 0 ]
  [[ "$output" == *"No install record"* ]]
}

@test "version shows Bash: line when install.json has bash_version" {
  mkdir -p "$HOME/.config/dev-env"
  cat >"$HOME/.config/dev-env/install.json" <<'EOF'
{
  "entry_point": "nix",
  "version": "1.0.0",
  "source": "git",
  "scopes": ["shell"],
  "installed_at": "2026-04-25T12:00:00Z",
  "mode": "install",
  "status": "success",
  "phase": "done",
  "platform": "Linux",
  "arch": "x86_64",
  "bash_version": "3.2"
}
EOF
  run nx version
  [ "$status" -eq 0 ]
  [[ "$output" == *"Bash:"* ]]
  [[ "$output" == *"3.2"* ]]
}

@test "version omits Bash: line when install.json lacks bash_version" {
  mkdir -p "$HOME/.config/dev-env"
  cat >"$HOME/.config/dev-env/install.json" <<'EOF'
{
  "entry_point": "nix",
  "version": "1.0.0",
  "source": "git",
  "scopes": ["shell"],
  "installed_at": "2026-04-25T12:00:00Z",
  "mode": "install",
  "status": "success",
  "phase": "done",
  "platform": "Linux",
  "arch": "x86_64"
}
EOF
  run nx version
  [ "$status" -eq 0 ]
  [[ "$output" != *"Bash:"* ]]
}

@test "version without jq cats raw JSON" {
  mkdir -p "$HOME/.config/dev-env"
  printf '{"version":"1.0.0","source":"git"}\n' >"$HOME/.config/dev-env/install.json"
  # hide jq by overriding PATH with a dir that has everything except jq
  local nojq_dir="$TEST_DIR/nojq"
  mkdir -p "$nojq_dir"
  local cmd real
  for cmd in nix cat sed grep printf date id uname tr; do
    real="$(builtin command -v "$cmd" 2>/dev/null)" || continue
    ln -sf "$real" "$nojq_dir/$cmd"
  done
  ln -sf "$TEST_DIR/bin/nix" "$nojq_dir/nix"
  PATH="$nojq_dir" run nx version
  [ "$status" -eq 0 ]
  [[ "$output" == *'"version":"1.0.0"'* ]]
}

# -- list ---------------------------------------------------------------------

@test "list shows scoped and extra packages" {
  cat >"$ENV_DIR/config.nix" <<'EOF'
{
  isInit = false;
  scopes = [
    "shell"
  ];
}
EOF
  cat >"$ENV_DIR/scopes/base.nix" <<'EOF'
{ pkgs }: with pkgs; [
  git
]
EOF
  cat >"$ENV_DIR/scopes/shell.nix" <<'EOF'
{ pkgs }: with pkgs; [
  fzf
  bat
]
EOF
  printf 'httpie\n' | _nx_write_pkgs
  run nx list
  [ "$status" -eq 0 ]
  [[ "$output" == *"git"* ]]
  [[ "$output" == *"fzf"* ]]
  [[ "$output" == *"bat"* ]]
  [[ "$output" == *"httpie"* ]]
  [[ "$output" == *"(base)"* ]]
  [[ "$output" == *"(shell)"* ]]
  [[ "$output" == *"(extra)"* ]]
}

@test "list shows empty message when no packages" {
  run nx list
  [ "$status" -eq 0 ]
  [[ "$output" == *"No packages installed"* ]]
}

@test "list deduplicates packages across sources" {
  cat >"$ENV_DIR/config.nix" <<'EOF'
{
  isInit = false;
  scopes = [ "shell" ];
}
EOF
  cat >"$ENV_DIR/scopes/base.nix" <<'EOF'
{ pkgs }: with pkgs; [
  git
]
EOF
  cat >"$ENV_DIR/scopes/shell.nix" <<'EOF'
{ pkgs }: with pkgs; [
  fzf
]
EOF
  printf 'fzf\n' | _nx_write_pkgs
  run nx list
  [ "$status" -eq 0 ]
  local count
  count="$(echo "$output" | grep -c 'fzf')"
  [ "$count" -eq 1 ]
}

# -- overlay (merged list+status) ---------------------------------------------

@test "overlay shows scopes and shell config" {
  mkdir -p "$ENV_DIR/local/scopes"
  printf '{ pkgs }: with pkgs; []\n' >"$ENV_DIR/local/scopes/devtools.nix"
  printf '{ pkgs }: with pkgs; []\n' >"$ENV_DIR/scopes/local_devtools.nix"
  mkdir -p "$ENV_DIR/local/shell_cfg"
  printf '# custom\n' >"$ENV_DIR/local/shell_cfg/custom.sh"
  run nx overlay
  [ "$status" -eq 0 ]
  [[ "$output" == *"devtools"* ]]
  [[ "$output" == *"custom.sh"* ]]
}

@test "overlay reports no overlay when missing" {
  run nx overlay
  [ "$status" -eq 0 ]
  [[ "$output" == *"No overlay directory"* ]]
}

@test "overlay shows modified indicator for divergent scopes" {
  mkdir -p "$ENV_DIR/local/scopes"
  printf '{ pkgs }: with pkgs; [ httpie ]\n' >"$ENV_DIR/local/scopes/mytools.nix"
  printf '{ pkgs }: with pkgs; [ httpie jq ]\n' >"$ENV_DIR/scopes/local_mytools.nix"
  run nx overlay
  [ "$status" -eq 0 ]
  [[ "$output" == *"modified"* ]]
}

@test "overlay shows source missing for orphaned scope" {
  mkdir -p "$ENV_DIR/local"
  printf '{ pkgs }: with pkgs; []\n' >"$ENV_DIR/scopes/local_orphan.nix"
  run nx overlay
  [ "$status" -eq 0 ]
  [[ "$output" == *"source missing"* ]]
}

# -- scope edge cases ---------------------------------------------------------

@test "scope remove fails without config.nix" {
  rm -f "$ENV_DIR/config.nix"
  run nx scope remove shell
  [ "$status" -eq 1 ]
  [[ "$output" == *"No nix-env config"* ]]
}

@test "scope show without args shows usage" {
  run nx scope show
  [ "$status" -eq 1 ]
  [[ "$output" == *"Usage: nx scope show"* ]]
}

# -- _nx_read_install_field ---------------------------------------------------

@test "read_install_field reads field with jq" {
  if ! command -v jq &>/dev/null; then
    skip "jq not available"
  fi
  mkdir -p "$HOME/.config/dev-env"
  cat >"$HOME/.config/dev-env/install.json" <<'EOF'
{
  "repo_path": "/home/user/envy-nx",
  "repo_url": "https://github.com/szymonos/envy-nx.git",
  "version": "1.0.0"
}
EOF
  run _nx_read_install_field repo_path
  [ "$status" -eq 0 ]
  [ "$output" = "/home/user/envy-nx" ]

  run _nx_read_install_field repo_url
  [ "$status" -eq 0 ]
  [ "$output" = "https://github.com/szymonos/envy-nx.git" ]
}

@test "read_install_field falls back to sed without jq" {
  mkdir -p "$HOME/.config/dev-env"
  cat >"$HOME/.config/dev-env/install.json" <<'EOF'
{
  "repo_path": "/tmp/my-repo",
  "repo_url": "https://github.com/example/repo.git"
}
EOF
  local nojq_dir="$TEST_DIR/nojq"
  mkdir -p "$nojq_dir"
  local cmd real
  for cmd in nix cat sed grep head printf; do
    real="$(builtin command -v "$cmd" 2>/dev/null)" || continue
    ln -sf "$real" "$nojq_dir/$cmd"
  done
  ln -sf "$TEST_DIR/bin/nix" "$nojq_dir/nix"
  PATH="$nojq_dir" run _nx_read_install_field repo_path
  [ "$status" -eq 0 ]
  [ "$output" = "/tmp/my-repo" ]
}

@test "read_install_field returns empty when file missing" {
  run _nx_read_install_field repo_path
  [ "$status" -eq 0 ]
  [ -z "$output" ]
}

@test "read_install_field returns empty for missing field" {
  if ! command -v jq &>/dev/null; then
    skip "jq not available"
  fi
  mkdir -p "$HOME/.config/dev-env"
  printf '{"version":"1.0.0"}\n' >"$HOME/.config/dev-env/install.json"
  run _nx_read_install_field repo_path
  [ "$status" -eq 0 ]
  [ -z "$output" ]
}

# -- _nx_self_sync ------------------------------------------------------------

@test "self_sync delegates to nix/setup.sh --skip-repo-update" {
  # _nx_self_sync no longer copies files itself - it execs the latest
  # nix/setup.sh so the LATEST phase_bootstrap_sync_env_dir determines
  # the file list (cross-major upgrade safety). Stub setup.sh to record
  # its invocation args + cwd, then assert the delegation contract.
  local fake_repo="$TEST_DIR/fake-repo"
  mkdir -p "$fake_repo/nix"
  printf '#!/usr/bin/env bash\nprintf "stub-setup args=%%s pwd=%%s\\n" "$*" "$PWD"\n' \
    >"$fake_repo/nix/setup.sh"
  chmod +x "$fake_repo/nix/setup.sh"

  run _nx_self_sync "$fake_repo"
  [ "$status" -eq 0 ]
  [[ "$output" == *"stub-setup args=--skip-repo-update"* ]]
}

@test "self_sync errors when nix/setup.sh is missing or not executable" {
  local fake_repo="$TEST_DIR/empty-repo"
  mkdir -p "$fake_repo"

  run _nx_self_sync "$fake_repo"
  [ "$status" -eq 1 ]
  [[ "$output" == *"nx self sync"* ]]
  [[ "$output" == *"setup.sh not found"* ]]
}

# -- nx help includes setup and self ------------------------------------------

@test "nx help shows setup and self commands" {
  run nx help
  [ "$status" -eq 0 ]
  [[ "$output" == *"setup"* ]]
  [[ "$output" == *"self"* ]]
  [[ "$output" == *"nix/setup.sh"* ]]
  [[ "$output" == *"source repository"* ]]
}

# -- nx self help -------------------------------------------------------------

@test "nx self help shows usage" {
  run nx self help
  [ "$status" -eq 0 ]
  [[ "$output" == *"Usage: nx self"* ]]
  [[ "$output" == *"update"* ]]
  [[ "$output" == *"path"* ]]
  [[ "$output" == *"--force"* ]]
}

@test "nx self without subcommand shows help" {
  run nx self
  [ "$status" -eq 0 ]
  [[ "$output" == *"Usage: nx self"* ]]
}

# -- nx self path -------------------------------------------------------------

@test "self path prints repo path from install.json" {
  mkdir -p "$HOME/.config/dev-env"
  printf '{"repo_path": "/home/user/envy-nx"}\n' >"$HOME/.config/dev-env/install.json"
  run nx self path
  [ "$status" -eq 0 ]
  [ "$output" = "/home/user/envy-nx" ]
}

@test "self path fails when no repo path recorded" {
  run nx self path
  [ "$status" -eq 1 ]
  [[ "$output" == *"No repo path"* ]]
}

@test "self path fails with empty repo_path field" {
  mkdir -p "$HOME/.config/dev-env"
  printf '{"repo_path": ""}\n' >"$HOME/.config/dev-env/install.json"
  run nx self path
  [ "$status" -eq 1 ]
  [[ "$output" == *"No repo path"* ]]
}

# -- nx self update -----------------------------------------------------------

@test "self update fails when repo not found" {
  mkdir -p "$HOME/.config/dev-env"
  printf '{"repo_path": "/nonexistent/path"}\n' >"$HOME/.config/dev-env/install.json"
  run nx self update
  [ "$status" -eq 1 ]
  [[ "$output" == *"Repo not found"* ]]
  [[ "$output" == *"nx setup"* ]]
}

@test "self update fails when no repo path set" {
  run nx self update
  [ "$status" -eq 1 ]
  [[ "$output" == *"Repo not found"* ]]
}

@test "self update git pull succeeds on clean repo" {
  # clone from bare so tracking is set up automatically
  local bare_repo="$TEST_DIR/bare.git"
  git init --bare "$bare_repo" >/dev/null 2>&1
  local seed_repo="$TEST_DIR/seed"
  git clone "$bare_repo" "$seed_repo" >/dev/null 2>&1
  git -C "$seed_repo" config user.email "test@test.com"
  git -C "$seed_repo" config user.name "Test"
  printf 'initial\n' >"$seed_repo/file.txt"
  git -C "$seed_repo" add file.txt
  git -C "$seed_repo" commit -m "init" >/dev/null 2>&1
  git -C "$seed_repo" push >/dev/null 2>&1
  local git_repo="$TEST_DIR/git-repo"
  git clone "$bare_repo" "$git_repo" >/dev/null 2>&1
  git -C "$git_repo" config user.email "test@test.com"
  git -C "$git_repo" config user.name "Test"
  # _nx_self_sync now delegates to nix/setup.sh - stub it so the test
  # doesn't try to run the real setup pipeline
  mkdir -p "$git_repo/nix"
  printf '#!/usr/bin/env bash\necho "SETUP_RAN $*"\n' >"$git_repo/nix/setup.sh"
  chmod +x "$git_repo/nix/setup.sh"

  mkdir -p "$HOME/.config/dev-env"
  printf '{"repo_path": "%s"}\n' "$git_repo" >"$HOME/.config/dev-env/install.json"

  run nx self update
  [ "$status" -eq 0 ]
  [[ "$output" == *"Updated"* ]]
  [[ "$output" == *"SETUP_RAN --skip-repo-update"* ]]
}

@test "self update --force resets to origin" {
  local bare_repo="$TEST_DIR/bare2.git"
  git init --bare "$bare_repo" >/dev/null 2>&1
  local seed_repo="$TEST_DIR/seed2"
  git clone "$bare_repo" "$seed_repo" >/dev/null 2>&1
  git -C "$seed_repo" config user.email "test@test.com"
  git -C "$seed_repo" config user.name "Test"
  printf 'initial\n' >"$seed_repo/file.txt"
  git -C "$seed_repo" add file.txt
  git -C "$seed_repo" commit -m "init" >/dev/null 2>&1
  git -C "$seed_repo" push >/dev/null 2>&1
  local git_repo="$TEST_DIR/git-repo2"
  git clone "$bare_repo" "$git_repo" >/dev/null 2>&1
  git -C "$git_repo" config user.email "test@test.com"
  git -C "$git_repo" config user.name "Test"
  mkdir -p "$git_repo/nix"
  printf '#!/usr/bin/env bash\necho "SETUP_RAN $*"\n' >"$git_repo/nix/setup.sh"
  chmod +x "$git_repo/nix/setup.sh"

  mkdir -p "$HOME/.config/dev-env"
  printf '{"repo_path": "%s"}\n' "$git_repo" >"$HOME/.config/dev-env/install.json"

  run nx self update --force
  [ "$status" -eq 0 ]
  [[ "$output" == *"Force-updated"* ]]
  [[ "$output" == *"SETUP_RAN --skip-repo-update"* ]]
}

# -- nx setup -----------------------------------------------------------------

@test "setup runs setup.sh from install.json:repo_path when valid" {
  local fake_repo="$TEST_DIR/setup-repo"
  mkdir -p "$fake_repo/nix"
  printf '#!/bin/sh\necho "SETUP_RAN $*"\n' >"$fake_repo/nix/setup.sh"
  chmod +x "$fake_repo/nix/setup.sh"
  mkdir -p "$HOME/.config/dev-env"
  printf '{"repo_path": "%s"}\n' "$fake_repo" >"$HOME/.config/dev-env/install.json"

  run nx setup --shell --python
  [ "$status" -eq 0 ]
  [[ "$output" == *"SETUP_RAN --shell --python"* ]]
  [[ "$output" == *"$fake_repo"* ]]
}

@test "setup falls back to canonical clone when install.json:repo_path is unset" {
  local canonical="$HOME/source/repos/szymonos/envy-nx"
  mkdir -p "$canonical/nix"
  printf '#!/bin/sh\necho "SETUP_RAN_CANONICAL"\n' >"$canonical/nix/setup.sh"
  chmod +x "$canonical/nix/setup.sh"

  run nx setup
  [ "$status" -eq 0 ]
  [[ "$output" == *"SETUP_RAN_CANONICAL"* ]]
  [[ "$output" == *"$canonical"* ]]
}

@test "setup falls back to canonical with notice when install.json:repo_path is stale" {
  local canonical="$HOME/source/repos/szymonos/envy-nx"
  mkdir -p "$canonical/nix"
  printf '#!/bin/sh\necho "SETUP_RAN"\n' >"$canonical/nix/setup.sh"
  chmod +x "$canonical/nix/setup.sh"
  mkdir -p "$HOME/.config/dev-env"
  printf '{"repo_path": "/nonexistent/stale/path"}\n' >"$HOME/.config/dev-env/install.json"

  run nx setup
  [ "$status" -eq 0 ]
  [[ "$output" == *"falling back"* ]]
  [[ "$output" == *"/nonexistent/stale/path"* ]]
  [[ "$output" == *"$canonical"* ]]
}

# -- nx version with repo_path -----------------------------------------------

@test "version shows repo path when present" {
  if ! command -v jq &>/dev/null; then
    skip "jq not available"
  fi
  mkdir -p "$HOME/.config/dev-env"
  cat >"$HOME/.config/dev-env/install.json" <<'EOF'
{
  "entry_point": "nix",
  "version": "1.0.0",
  "source": "git",
  "source_ref": "abc123",
  "repo_path": "/home/user/envy-nx",
  "scopes": ["shell"],
  "installed_at": "2026-04-25T12:00:00Z",
  "mode": "install",
  "status": "success",
  "phase": "done",
  "platform": "Linux",
  "arch": "x86_64",
  "nix_version": "nix 2.28.0",
  "error": "",
  "allow_unfree": false,
  "installed_by": "testuser",
  "shell": "/bin/bash"
}
EOF
  run nx version
  [ "$status" -eq 0 ]
  [[ "$output" == *"Repo:"* ]]
  [[ "$output" == *"/home/user/envy-nx"* ]]
}
