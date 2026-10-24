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

@test "overlay reports no overlay when dir doesn't exist" {
  run nx overlay
  [ "$status" -eq 0 ]
  [[ "$output" == *"No overlay directory active"* ]]
}

@test "overlay discovers local dir" {
  mkdir -p "$ENV_DIR/local"
  run nx overlay
  [ "$status" -eq 0 ]
  [[ "$output" == *"$ENV_DIR/local"* ]]
}

@test "overlay lists the org overlay first, then the personal one" {
  mkdir -p "$ENV_DIR/local"
  local custom_dir="$TEST_DIR/custom-overlay"
  mkdir -p "$custom_dir"
  export NIX_ENV_OVERLAY_DIR="$custom_dir"
  run nx overlay
  [[ "$output" == *"$custom_dir"*"(organization)"*"$ENV_DIR/local"*"(personal)"* ]]
}

@test "overlay shows synced scopes from scopes dir" {
  mkdir -p "$ENV_DIR/local/scopes"
  printf '{ pkgs }: with pkgs; []\n' >"$ENV_DIR/local/scopes/my_tools.nix"
  cp "$ENV_DIR/local/scopes/my_tools.nix" "$ENV_DIR/scopes/local_my_tools.nix"
  run nx overlay
  [[ "$output" == *"Scopes:"* ]]
  [[ "$output" == *"my_tools"* ]]
}

@test "overlay marks header scopes setup does not know as ignored" {
  mkdir -p "$ENV_DIR/local/scopes"
  printf '# scopes: python not_a_scope\n{ pkgs }: with pkgs; []\n' >"$ENV_DIR/local/scopes/team.nix"
  run nx overlay
  [ "$status" -eq 0 ]
  [[ "$output" == *"+ scopes: python not_a_scope"*"(unknown, ignored: not_a_scope)"* ]]
}

@test "overlay shows shell config files" {
  mkdir -p "$ENV_DIR/local/shell_cfg"
  touch "$ENV_DIR/local/shell_cfg/custom.sh"
  run nx overlay
  [[ "$output" == *"Shell config:"* ]]
  [[ "$output" == *"custom.sh"* ]]
}

@test "overlay lists post-setup hooks as running and other hooks as ignored" {
  mkdir -p "$ENV_DIR/local/hooks/post-setup.d" "$ENV_DIR/local/hooks/pre-setup.d"
  touch "$ENV_DIR/local/hooks/post-setup.d/10-custom.sh" "$ENV_DIR/local/hooks/pre-setup.d/10-early.sh"
  run nx overlay
  [ "$status" -eq 0 ]
  [[ "$output" == *"hooks/post-setup.d/10-custom.sh"*"(runs after setup)"* ]]
  [[ "$output" == *"hooks/pre-setup.d/10-early.sh"*"(ignored - only hooks/post-setup.d runs)"* ]]
}

@test "overlay reports hooks in post-setup.d subfolders as ignored" {
  mkdir -p "$ENV_DIR/local/hooks/post-setup.d/sub"
  touch "$ENV_DIR/local/hooks/post-setup.d/sub/20-nested.sh"
  run nx overlay
  [ "$status" -eq 0 ]
  [[ "$output" == *"hooks/post-setup.d/sub/20-nested.sh"*"(ignored - only scripts directly in hooks/post-setup.d run)"* ]]
}

@test "overlay lists symlinked scope files and hooks that setup consumes" {
  mkdir -p "$TEST_DIR/src/hooks" "$ENV_DIR/local/scopes" "$ENV_DIR/local/hooks"
  printf '# scopes: python\n{ pkgs }: with pkgs; []\n' >"$TEST_DIR/src/team.nix"
  touch "$TEST_DIR/src/hooks/10-linked.sh"
  ln -s "$TEST_DIR/src/team.nix" "$ENV_DIR/local/scopes/team.nix"
  ln -s "$TEST_DIR/src/hooks" "$ENV_DIR/local/hooks/post-setup.d"
  run nx overlay
  [ "$status" -eq 0 ]
  [[ "$output" == *"team"*"+ scopes: python"* ]]
  [[ "$output" == *"hooks/post-setup.d/10-linked.sh"*"(runs after setup)"* ]]
}

@test "overlay prints no hook warning when the overlay has no hooks" {
  mkdir -p "$ENV_DIR/local/scopes"
  run nx overlay
  [ "$status" -eq 0 ]
  [[ "$output" != *"Hooks:"* ]]
}

@test "overlay handles empty overlay directory" {
  mkdir -p "$ENV_DIR/local"
  run nx overlay
  [ "$status" -eq 0 ]
  [[ "$output" == *"No overlay scopes"* ]]
}

@test "overlay shows modified indicator when source differs" {
  mkdir -p "$ENV_DIR/local/scopes"
  printf '{ pkgs }: with pkgs; []\n' >"$ENV_DIR/scopes/local_my_tools.nix"
  printf '{ pkgs }: with pkgs; [ hello ]\n' >"$ENV_DIR/local/scopes/my_tools.nix"
  run nx overlay
  [[ "$output" == *"modified"* ]]
}

@test "overlay shows source missing when overlay dir has no source" {
  mkdir -p "$ENV_DIR/local"
  printf '{ pkgs }: with pkgs; []\n' >"$ENV_DIR/scopes/local_orphan.nix"
  run nx overlay
  [[ "$output" == *"source missing"* ]]
}

@test "overlay shows shell config sync status" {
  mkdir -p "$ENV_DIR/local/shell_cfg" "$HOME/.config/shell/overlay"
  printf 'echo hello\n' >"$ENV_DIR/local/shell_cfg/custom.sh"
  cp "$ENV_DIR/local/shell_cfg/custom.sh" "$HOME/.config/shell/overlay/custom.sh"
  run nx overlay
  [[ "$output" == *"synced"* ]]
}

@test "overlay shows differs indicator for changed shell config" {
  mkdir -p "$ENV_DIR/local/shell_cfg" "$HOME/.config/shell/overlay"
  printf 'echo hello\n' >"$ENV_DIR/local/shell_cfg/custom.sh"
  printf 'echo world\n' >"$HOME/.config/shell/overlay/custom.sh"
  run nx overlay
  [[ "$output" == *"differs"* ]]
}

@test "overlay set remembers the org overlay and overlay shows it" {
  local org="$TEST_DIR/org-overlay"
  mkdir -p "$org/scopes"
  run nx overlay set "$org"
  [ "$status" -eq 0 ]
  [ "$(cat "$ENV_DIR/overlay_dir")" = "$org" ]
  run nx overlay
  [[ "$output" == *"$org"*"(organization)"* ]]
}

@test "overlay set rejects a path that is not a directory" {
  run nx overlay set "$TEST_DIR/nope"
  [ "$status" -ne 0 ]
  [ ! -f "$ENV_DIR/overlay_dir" ]
}

@test "overlay set warns when NIX_ENV_OVERLAY_DIR points elsewhere" {
  mkdir -p "$TEST_DIR/a" "$TEST_DIR/b"
  export NIX_ENV_OVERLAY_DIR="$TEST_DIR/b"
  run nx overlay set "$TEST_DIR/a"
  [ "$status" -eq 0 ]
  [[ "$output" == *"NIX_ENV_OVERLAY_DIR=$TEST_DIR/b is set in this shell and takes precedence"* ]]
}

@test "overlay set rejects a path with a colon" {
  mkdir -p "$TEST_DIR/team:blue"
  run nx overlay set "$TEST_DIR/team:blue"
  [ "$status" -ne 0 ]
  [ ! -f "$ENV_DIR/overlay_dir" ]
}

@test "overlay shows a saved org overlay that went missing" {
  printf '%s\n' "$TEST_DIR/gone" >"$ENV_DIR/overlay_dir"
  run nx overlay
  [ "$status" -eq 0 ]
  [[ "$output" == *"$TEST_DIR/gone"*"not a readable directory - setup stops"* ]]
}

@test "overlay set refuses the config folder and a bad scopes entry" {
  run nx overlay set "$ENV_DIR"
  [ "$status" -ne 0 ]
  [[ "$output" == *"is the Envy-NX config folder"* ]]
  mkdir -p "$TEST_DIR/org" && touch "$TEST_DIR/org/scopes"
  run nx overlay set "$TEST_DIR/org"
  [ "$status" -ne 0 ]
  [ ! -f "$ENV_DIR/overlay_dir" ]
}

@test "overlay unset forgets the org overlay" {
  mkdir -p "$TEST_DIR/org"
  printf '%s\n' "$TEST_DIR/org" >"$ENV_DIR/overlay_dir"
  run nx overlay unset
  [ "$status" -eq 0 ]
  [ ! -f "$ENV_DIR/overlay_dir" ]
  [[ "$output" == *"removes the overlay's scopes"* ]]
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

@test "scope add writes to the personal overlay even when NIX_ENV_OVERLAY_DIR is set" {
  local custom_dir="$TEST_DIR/custom-overlay"
  mkdir -p "$custom_dir"
  export NIX_ENV_OVERLAY_DIR="$custom_dir"
  cat >"$ENV_DIR/config.nix" <<'EOF'
{
  isInit = false;
  scopes = [];
}
EOF
  run nx scope add my_tools
  [ "$status" -eq 0 ]
  [ -f "$ENV_DIR/local/scopes/my_tools.nix" ]
  [ ! -f "$custom_dir/scopes/my_tools.nix" ]
}

# -- org overlay control (decision 0013) -------------------------------------

# Org overlay at $ORG providing scope `team` whose header names gcloud, as the
# last setup run recorded it in overlay_scopes.
_org_overlay() {
  ORG="$TEST_DIR/org-overlay"
  mkdir -p "$ORG/scopes"
  printf '# scopes: gcloud\n{ pkgs }: with pkgs; [ btop ]\n' >"$ORG/scopes/team.nix"
  cp "$ORG/scopes/team.nix" "$ENV_DIR/scopes/local_team.nix"
  export NIX_ENV_OVERLAY_DIR="$ORG"
  printf 'org local_team %s\norg gcloud %s\n' "$ORG/scopes/team.nix" "$ORG/scopes/team.nix" >"$ENV_DIR/overlay_scopes"
  cat >"$ENV_DIR/config.nix" <<'EOF'
{
  isInit = false;
  scopes = [
    "gcloud"
    "local_team"
  ];
}
EOF
  _nx_apply() { echo APPLY_CALLED; }
}

@test "scope remove refuses a scope the org overlay provides" {
  _org_overlay
  run nx scope remove team
  [ "$status" -ne 0 ]
  [[ "$output" == *"'team' is controlled by the organization overlay ($ORG/scopes/team.nix)"* ]]
  [[ "$output" != *"APPLY_CALLED"* ]]
  [ -f "$ORG/scopes/team.nix" ]
  grep -q 'local_team' "$ENV_DIR/config.nix"
}

@test "scope remove rejects a name with a space instead of splitting it" {
  _org_overlay
  run nx scope remove 'gcloud local_team'
  [ "$status" -ne 0 ]
  [[ "$output" == *"Invalid scope name: gcloud local_team"* ]]
  [[ "$output" != *"APPLY_CALLED"* ]]
  grep -q '"gcloud"' "$ENV_DIR/config.nix"
  grep -q 'local_team' "$ENV_DIR/config.nix"
}

@test "scope remove refuses a standard scope the org header names" {
  _org_overlay
  run nx scope remove gcloud
  [ "$status" -ne 0 ]
  [[ "$output" == *"'gcloud' is controlled by the organization overlay"* ]]
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
  _org_overlay
  mkdir -p "$ENV_DIR/local/scopes"
  printf '{ pkgs }: with pkgs; []\n' >"$ENV_DIR/local/scopes/mine.nix"
  printf '{\n  isInit = false;\n  scopes = [\n    "local_mine"\n    "local_team"\n  ];\n}\n' >"$ENV_DIR/config.nix"
  run nx scope remove team mine
  [ "$status" -eq 0 ]
  [[ "$output" == *"removed scope: mine"* ]]
  [ ! -f "$ENV_DIR/local/scopes/mine.nix" ]
  grep -q 'local_team' "$ENV_DIR/config.nix"
  ! grep -q 'local_mine' "$ENV_DIR/config.nix"
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

@test "scope add is a no-op for a scope the org overlay provides" {
  _org_overlay
  run nx scope add team
  [ "$status" -eq 0 ]
  [[ "$output" == *"'team' is provided by the organization overlay"* ]]
  [ ! -f "$ENV_DIR/local/scopes/team.nix" ]
}

@test "scope add is a no-op for a standard scope the org header names" {
  _org_overlay
  run nx scope add gcloud
  [ "$status" -eq 0 ]
  [[ "$output" == *"'gcloud' is provided by the organization overlay"* ]]
  [[ "$output" != *"managed scope"* ]]
}

@test "scope edit refuses a standard scope the org header names" {
  _org_overlay
  EDITOR=false run nx scope edit gcloud
  [ "$status" -ne 0 ]
  [[ "$output" == *"'gcloud' is controlled by the organization overlay"* ]]
}

@test "scope add and edit find an org scope whose file name has a hyphen" {
  _org_overlay
  printf 'org local_data-tools %s\n' "$ORG/scopes/data-tools.nix" >>"$ENV_DIR/overlay_scopes"
  run nx scope add data-tools
  [[ "$output" == *"provided by the organization overlay ($ORG/scopes/data-tools.nix)"* ]]
  EDITOR=false run nx scope edit data-tools
  [ "$status" -ne 0 ]
  [[ "$output" == *"controlled by the organization overlay"* ]]
}

@test "scope remove rejects a name with a slash" {
  _org_overlay
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

@test "scope edit refuses a scope the org overlay provides" {
  _org_overlay
  EDITOR=false run nx scope edit team
  [ "$status" -ne 0 ]
  [[ "$output" == *"controlled by the organization overlay"* ]]
}

@test "overlay marks a personal scope the org overlay shadows as ignored" {
  _org_overlay
  mkdir -p "$ENV_DIR/local/scopes"
  printf '{ pkgs }: with pkgs; []\n' >"$ENV_DIR/local/scopes/team.nix"
  run nx overlay
  [ "$status" -eq 0 ]
  [[ "$output" == *"team"*"(ignored - the organization overlay provides it)"* ]]
}

@test "overlay shows the standard scopes a header names" {
  _org_overlay
  run nx overlay
  [ "$status" -eq 0 ]
  [[ "$output" == *"team"*"+ scopes: gcloud"* ]]
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
