#!/usr/bin/env bats
# Unit tests for nx overlay and nx scope add commands
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

# -- overlay -----------------------------------------------------------------

@test "overlay with no subscriptions points at browse and add" {
  mkdir -p "$ENV_DIR/local"
  run nx overlay
  [ "$status" -eq 0 ]
  [[ "$output" == *"No overlay subscriptions"*"nx overlay browse <repo>"* ]]
}

# -- scope add ---------------------------------------------------------------

@test "scope add creates stub nix file in overlay directory" {
  cat >"$ENV_DIR/config.nix" <<'EOF'
{
  isInit = false;
  scopes = [
    "shell"
  ];
}
EOF
  run nx scope add my_tools
  [ "$status" -eq 0 ]
  [[ "$output" == *"Created scope"* ]]
  [ -f "$ENV_DIR/local/scopes/my_tools.nix" ]
  [ -f "$ENV_DIR/scopes/local_my_tools.nix" ]
}

@test "scope add registers scope in config.nix" {
  cat >"$ENV_DIR/config.nix" <<'EOF'
{
  isInit = false;
  scopes = [
    "shell"
  ];
}
EOF
  nx scope add my_tools
  grep -q 'local_my_tools' "$ENV_DIR/config.nix"
  grep -q 'shell' "$ENV_DIR/config.nix"
}

@test "scope add is idempotent for existing scope" {
  mkdir -p "$ENV_DIR/local/scopes"
  printf '{ pkgs }: with pkgs; [ hello ]\n' >"$ENV_DIR/local/scopes/my_tools.nix"
  run nx scope add my_tools
  [ "$status" -eq 0 ]
  [[ "$output" == *"already exists"* ]]
}

@test "scope add normalizes hyphens to underscores" {
  cat >"$ENV_DIR/config.nix" <<'EOF'
{
  isInit = false;
  scopes = [];
}
EOF
  run nx scope add my-tools
  [ "$status" -eq 0 ]
  [ -f "$ENV_DIR/local/scopes/my_tools.nix" ]
}

@test "scope add rejects names that collide with managed scopes" {
  # nx_scope.sh:add must reject overlay names matching scopes.json:valid_scopes
  # to prevent silent shadowing of canonical scopes (e.g. local_python.nix
  # shadowing nix/scopes/python.nix on the next nix/setup.sh run).
  # _nx_find_lib resolves scopes.json from the dev tree (alongside nx_scope.sh),
  # so no fixture setup is needed - the real valid_scopes list is consulted.
  cat >"$ENV_DIR/config.nix" <<'EOF'
{
  isInit = false;
  scopes = [];
}
EOF
  run nx scope add python
  [ "$status" -ne 0 ]
  [[ "$output" == *"managed scope"* ]]
  [[ "$output" == *"python"* ]]
  # Overlay file must NOT have been created.
  [ ! -f "$ENV_DIR/local/scopes/python.nix" ]
  [ ! -f "$ENV_DIR/scopes/local_python.nix" ]
  # config.nix must NOT mention local_python.
  ! grep -q 'local_python' "$ENV_DIR/config.nix"
}

@test "scope add rejects hyphenated managed scope names (k8s-base -> k8s_base)" {
  # Hyphens are normalized to underscores BEFORE the validation runs, so
  # `nx scope add k8s-base` should still hit the managed-scope rejection.
  cat >"$ENV_DIR/config.nix" <<'EOF'
{
  isInit = false;
  scopes = [];
}
EOF
  run nx scope add k8s-base
  [ "$status" -ne 0 ]
  [[ "$output" == *"managed scope"* ]]
  [ ! -f "$ENV_DIR/local/scopes/k8s_base.nix" ]
}

@test "scope add rejects names setup would skip" {
  printf '{\n  isInit = false;\n  scopes = [];\n}\n' >"$ENV_DIR/config.nix"
  run nx scope add dev.tools
  [ "$status" -ne 0 ]
  [[ "$output" == *"letters, digits, - and _"* ]]
  [ ! -f "$ENV_DIR/local/scopes/dev.tools.nix" ]
}

@test "scope add rejects names starting with local_" {
  printf '{\n  isInit = false;\n  scopes = [];\n}\n' >"$ENV_DIR/config.nix"
  run nx scope add local_extra
  [ "$status" -ne 0 ]
  [[ "$output" == *"cannot start with local_"* ]]
  [ ! -f "$ENV_DIR/local/scopes/local_extra.nix" ]
}

@test "scope add allows non-managed names (overlay-only)" {
  # Sanity: rejection must be selective. A name that's NOT in valid_scopes
  # (e.g. user-chosen 'my_devtools') should still create the overlay normally.
  cat >"$ENV_DIR/config.nix" <<'EOF'
{
  isInit = false;
  scopes = [];
}
EOF
  run nx scope add my_devtools
  [ "$status" -eq 0 ]
  [[ "$output" == *"Created scope"* ]]
  [ -f "$ENV_DIR/local/scopes/my_devtools.nix" ]
}

# -- header scopes (decisions 0013, 0015) ------------------------------------

# A subscribed overlay scope k8s/k8s whose header names gcloud, as the last
# setup run recorded it in overlay_scopes.
_sub_overlay() {
  SUB_FILE="$ENV_DIR/overlays/key/overlays/k8s/scopes/k8s.nix"
  printf 'sub k8s/k8s %s\nsub gcloud %s\n' "$SUB_FILE" "$SUB_FILE" >"$ENV_DIR/overlay_scopes"
  cat >"$ENV_DIR/config.nix" <<'EOF'
{
  isInit = false;
  scopes = [
    "gcloud"
    "k8s/k8s"
  ];
}
EOF
  _nx_apply() { echo APPLY_CALLED; }
  _nx_lifecycle_setup() { echo "SETUP $*"; }
}

@test "scope remove rejects a name with a space instead of splitting it" {
  _sub_overlay
  run nx scope remove 'gcloud k8s/k8s'
  [ "$status" -ne 0 ]
  [[ "$output" == *"Invalid scope name: gcloud k8s/k8s"* ]]
  [[ "$output" != *"APPLY_CALLED"* ]]
  grep -q '"gcloud"' "$ENV_DIR/config.nix"
}

@test "scope remove opts out of a standard scope an overlay header names" {
  _sub_overlay
  run nx scope remove gcloud
  [ "$status" -eq 0 ]
  [[ "$output" == *"opted out"*"SETUP --skip-configure"* ]]
  grep -qx gcloud "$ENV_DIR/overlays.exclude"
  # config.nix keeps it, so setup runs its remove step once
  grep -q '"gcloud"' "$ENV_DIR/config.nix"
}

@test "scope remove points at the personal file for a scope its header names" {
  mkdir -p "$ENV_DIR/local/scopes"
  printf 'local gcloud %s\n' "$ENV_DIR/local/scopes/mine.nix" >"$ENV_DIR/overlay_scopes"
  printf '{\n  isInit = false;\n  scopes = [\n    "gcloud"\n  ];\n}\n' >"$ENV_DIR/config.nix"
  run nx scope remove gcloud
  [ "$status" -ne 0 ]
  [[ "$output" == *"named in the # scopes: header of $ENV_DIR/local/scopes/mine.nix - remove it there"* ]]
}

@test "scope remove still removes the other scopes it was given" {
  _sub_overlay
  mkdir -p "$ENV_DIR/local/scopes"
  printf '{ pkgs }: with pkgs; []\n' >"$ENV_DIR/local/scopes/mine.nix"
  printf '{\n  isInit = false;\n  scopes = [\n    "gcloud"\n    "local_mine"\n  ];\n}\n' >"$ENV_DIR/config.nix"
  run nx scope remove gcloud mine
  [ "$status" -eq 0 ]
  [[ "$output" == *"removed scope: mine"* ]]
  [ ! -f "$ENV_DIR/local/scopes/mine.nix" ]
  grep -q '"gcloud"' "$ENV_DIR/config.nix"
  run ! grep -q 'local_mine' "$ENV_DIR/config.nix"
}

@test "scope remove accepts the local_ prefix for a personal scope" {
  mkdir -p "$ENV_DIR/local/scopes"
  printf '{ pkgs }: with pkgs; []\n' >"$ENV_DIR/local/scopes/mine.nix"
  cp "$ENV_DIR/local/scopes/mine.nix" "$ENV_DIR/scopes/local_mine.nix"
  printf '{\n  isInit = false;\n  scopes = [\n    "local_mine"\n  ];\n}\n' >"$ENV_DIR/config.nix"
  _nx_apply() { :; }
  run nx scope remove local_mine
  [ "$status" -eq 0 ]
  [ ! -f "$ENV_DIR/local/scopes/mine.nix" ]
  [ ! -f "$ENV_DIR/scopes/local_mine.nix" ]
}

@test "scope add of a name an old organization overlay used creates a personal scope" {
  printf 'org local_team /gone/team.nix\n' >"$ENV_DIR/overlay_scopes"
  printf '{\n  isInit = false;\n  scopes = [];\n}\n' >"$ENV_DIR/config.nix"
  run nx scope add team
  [ "$status" -eq 0 ]
  [ -f "$ENV_DIR/local/scopes/team.nix" ]
}

@test "scope remove rejects a name with a slash" {
  _sub_overlay
  touch "$TEST_DIR/victim.nix"
  run nx scope remove "local_../../../../victim"
  [ "$status" -ne 0 ]
  [[ "$output" == *"Invalid scope name"* ]]
  [ -f "$TEST_DIR/victim.nix" ]
}

@test "scope edit rejects a name with a slash" {
  EDITOR=false run nx scope edit "../../org/scopes/team"
  [ "$status" -ne 0 ]
  [[ "$output" == *"Invalid scope name"* ]]
}

# -- hand-written scope protection -------------------------------------------

@test "scope file shape check accepts a generated scope file" {
  printf '{ pkgs }: with pkgs; [\n  bat\n  fd\n]\n' >"$TEST_DIR/gen.nix"
  run _nx_scope_file_is_generated "$TEST_DIR/gen.nix"
  [ "$status" -eq 0 ]
}

@test "scope file shape check accepts an empty generated scope file" {
  printf '{ pkgs }: with pkgs; []\n' >"$TEST_DIR/empty.nix"
  run _nx_scope_file_is_generated "$TEST_DIR/empty.nix"
  [ "$status" -eq 0 ]
}

@test "scope file shape check rejects hand-written Nix" {
  printf '{ pkgs }:\nlet tool = pkgs.stdenvNoCC.mkDerivation { };\nin [ tool ]\n' >"$TEST_DIR/hand.nix"
  run _nx_scope_file_is_generated "$TEST_DIR/hand.nix"
  [ "$status" -ne 0 ]
}

@test "scope file shape check rejects fragments without the generated frame" {
  local body
  for body in '  foo\n' ']\n' '' '{ pkgs }: with pkgs; []\n  foo\n' '{ pkgs }: with pkgs; [\n]\n  foo\n]\n'; do
    printf "$body" >"$TEST_DIR/frag.nix"
    run _nx_scope_file_is_generated "$TEST_DIR/frag.nix"
    [ "$status" -ne 0 ] || {
      printf 'accepted: %q\n' "$body"
      return 1
    }
  done
}

@test "scope file shape check ignores a grep function in the shell" {
  printf '{ pkgs }:\nlet tool = pkgs.stdenvNoCC.mkDerivation { };\nin [ tool ]\n' >"$TEST_DIR/hand.nix"
  grep() { return 2; }
  run _nx_scope_file_is_generated "$TEST_DIR/hand.nix"
  unset -f grep
  [ "$status" -ne 0 ]
}

@test "scope file shape check fails closed when the file cannot be read" {
  [ "$(id -u)" -eq 0 ] && skip "root can read a mode-000 file"
  printf '{ pkgs }: with pkgs; [\n  bat\n]\n' >"$TEST_DIR/locked.nix"
  chmod 000 "$TEST_DIR/locked.nix"
  run _nx_scope_file_is_generated "$TEST_DIR/locked.nix"
  chmod 644 "$TEST_DIR/locked.nix"
  [ "$status" -ne 0 ]
}

@test "scope add refuses to rewrite a hand-written scope file" {
  local f="$TEST_DIR/hand.nix"
  printf '{ pkgs }:\nlet tool = pkgs.stdenvNoCC.mkDerivation { };\nin [ tool ]\n' >"$f"
  run _nx_scope_file_add "$f" bat
  [ "$status" -ne 0 ]
  [[ "$output" == *"hand-written Nix"* ]]
  [[ "$output" == *"nx scope edit"* ]]
}

@test "nx scope add exits non-zero when the scope file is hand-written" {
  cat >"$ENV_DIR/config.nix" <<'EOF'
{
  isInit = false;
  scopes = [];
}
EOF
  mkdir -p "$ENV_DIR/local/scopes"
  printf '{ pkgs }:\nlet tool = pkgs.stdenvNoCC.mkDerivation { };\nin [ tool ]\n' >"$ENV_DIR/local/scopes/mine.nix"
  _nx_validate_pkgs() { printf '%s\n' "$@"; }
  _nx_apply() { echo APPLY_CALLED; }
  run nx scope add mine bat
  [ "$status" -ne 0 ]
  [[ "$output" == *"hand-written Nix"* ]]
  [[ "$output" != *"APPLY_CALLED"* ]]
}

@test "nx scope add exits zero without rebuilding when nothing changed" {
  cat >"$ENV_DIR/config.nix" <<'EOF'
{
  isInit = false;
  scopes = [];
}
EOF
  mkdir -p "$ENV_DIR/local/scopes"
  printf '{ pkgs }: with pkgs; [\n  bat\n]\n' >"$ENV_DIR/local/scopes/mine.nix"
  _nx_validate_pkgs() { printf '%s\n' "$@"; }
  _nx_apply() { echo APPLY_CALLED; }
  run nx scope add mine bat
  [ "$status" -eq 0 ]
  [[ "$output" != *"APPLY_CALLED"* ]]
}

@test "scope add leaves a hand-written scope file byte-identical" {
  local f="$TEST_DIR/hand.nix"
  printf '{ pkgs }:\nlet tool = pkgs.stdenvNoCC.mkDerivation { };\nin [ tool ]\n' >"$f"
  cp "$f" "$TEST_DIR/before.nix"
  _nx_scope_file_add "$f" bat || true
  run diff "$TEST_DIR/before.nix" "$f"
  [ "$status" -eq 0 ]
}

@test "scope add still appends to a generated scope file" {
  local f="$TEST_DIR/gen.nix"
  printf '{ pkgs }: with pkgs; [\n  bat\n]\n' >"$f"
  run _nx_scope_file_add "$f" fd
  [ "$status" -eq 0 ]
  grep -q '^  fd$' "$f"
  grep -q '^  bat$' "$f"
}
