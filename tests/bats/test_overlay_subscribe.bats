#!/usr/bin/env bats
# Unit tests for overlay subscriptions: address parsing, choosing overlays, the
# overlays setup phase against a local copy of the github:szymonos/nix-overlay
# layout (a bare repository and a plain folder), and the nx overlay verbs.
# shellcheck disable=SC2034,SC2154
bats_require_minimum_version 1.5.0

setup_file() {
  export REPO_ROOT="$BATS_TEST_DIRNAME/../.."
}

setup() {
  TEST_HOME="$(mktemp -d)"
  export HOME="$TEST_HOME"
  export XDG_CACHE_HOME="$TEST_HOME/.cache"
  export GIT_CONFIG_GLOBAL="$TEST_HOME/.gitconfig"
  git config --global user.email t@example.com
  git config --global user.name t
  git config --global init.defaultBranch main
  git config --global protocol.file.allow always
  ENV_DIR="$TEST_HOME/.config/nix-env"
  mkdir -p "$ENV_DIR/scopes"

  source "$REPO_ROOT/nix/lib/io.sh"
  source "$REPO_ROOT/nix/lib/phases/platform.sh"
  source "$REPO_ROOT/nix/lib/phases/overlays.sh"
  source "$REPO_ROOT/nix/lib/phases/scopes.sh"
  export SCOPES_JSON="$REPO_ROOT/.assets/lib/scopes.json"
  source "$REPO_ROOT/.assets/lib/scopes.sh"
  source "$REPO_ROOT/.assets/lib/nx_overlay.sh"
  SCRIPT_ROOT="$REPO_ROOT"
  CONFIG_NIX="$ENV_DIR/config.nix"
  allow_unfree=false
  unattended=true
  overlay_args=()
  overlay_entries=""
  OVERLAY_DIR=""
  _scope_set=" "

  # the fixture's layout: four overlays, sofka shared from lib/ by a symlink
  WORK="$TEST_HOME/work"
  REMOTE_DIR="$TEST_HOME/remote.git"
  REMOTE="file://$REMOTE_DIR"
  _overlay base "Shell, PowerShell and oh-my-posh" "shell pwsh oh_my_posh"
  _overlay k8s "Kubernetes tools and sofka" "docker k8s_base k8s_dev"
  _overlay cloud "Azure and Google Cloud CLIs" "az gcloud"
  _overlay dev "Python, Node.js and Bun" "python nodejs bun"
  mkdir -p "$WORK/lib" "$WORK/overlays/k8s/shell_cfg"
  printf '{ pkgs }: with pkgs; [ hello ]\n' >"$WORK/lib/sofka.nix"
  ln -s ../../../lib/sofka.nix "$WORK/overlays/k8s/scopes/sofka.nix"
  printf 'alias k=kubectl\n' >"$WORK/overlays/k8s/shell_cfg/k8s.sh"
  printf 'readme\n' >"$WORK/README.md"
  git -C "$WORK" init -q
  _commit "initial"
  git clone -q --bare "$WORK" "$REMOTE_DIR"
  git -C "$WORK" remote add origin "$REMOTE_DIR"
}

teardown() {
  rm -rf "$TEST_HOME"
}

# overlay $1 with README line $2 and a scope file named after it whose header names $3
_overlay() {
  mkdir -p "$WORK/overlays/$1/scopes"
  printf '# %s\n' "$2" >"$WORK/overlays/$1/README.md"
  printf '# scopes: %s\n{ pkgs }: with pkgs; [ jq ]\n' "$3" >"$WORK/overlays/$1/scopes/$1.nix"
}

_commit() {
  git -C "$WORK" add -A
  git -C "$WORK" commit -qm "$1"
}

_push() {
  _commit "$1"
  git -C "$WORK" push -q origin HEAD:main
}

_subscribe() {
  printf '%s\n' "$@" >"$ENV_DIR/overlays.list"
}

_key() { _nx_ov_parse "$1" "${2:-}" | cut -d '|' -f 4; }

# one pass over the phases that turn subscriptions into config.nix
_pass() {
  overlay_entries=""
  OVERLAY_DIR=""
  phase_platform_discover_overlay >/dev/null
  phase_overlays_sync
  phase_scopes_apply_overlay
  phase_scopes_resolve_and_sort >/dev/null
  is_init=false
  phase_scopes_write_config >/dev/null
  phase_scopes_save_overlay_state
}

_config_scopes() {
  sed -n 's/^[[:space:]]*"\([^"]*\)".*/\1/p' "$CONFIG_NIX"
}

# -- addresses -----------------------------------------------------------------

@test "parse: github shorthand with /ref and #overlay" {
  run _nx_ov_parse 'github:szymonos/nix-overlay/v2#k8s'
  [ "$status" -eq 0 ]
  [[ "$output" == "https://github.com/szymonos/nix-overlay.git|v2|k8s|github.com-szymonos-nix-overlay--v2-"*"|false" ]]
}

@test "parse: ?ref= on a git URL and on github:, a local folder takes none" {
  run _nx_ov_parse 'https://host/o/r.git?ref=v2#k8s'
  [[ "$output" == "https://host/o/r.git|v2|k8s|"*"|false" ]]
  run _nx_ov_parse 'github:o/r?ref=v2#k8s'
  [[ "$output" == "https://github.com/o/r.git|v2|k8s|"*"|false" ]]
  run _nx_ov_parse '/opt/overlays#k8s'
  [[ "$output" == "/opt/overlays||k8s|"*"|true" ]]
  run _nx_ov_parse '/opt/overlays?ref=v2#k8s'
  [ "$status" -eq 1 ]
  [[ "$output" == *"takes no ref"* ]]
}

@test "parse: refuses plain http, a ref given twice, odd refs and names" {
  run _nx_ov_parse 'http://example.com/o/r'
  [ "$status" -eq 1 ]
  run _nx_ov_parse 'github:o/r/v1?ref=v2'
  [ "$status" -eq 1 ]
  run _nx_ov_parse 'github:o/r?ref=--upload-pack=x'
  [ "$status" -eq 1 ]
  run _nx_ov_parse 'github:o/r#a/b'
  [ "$status" -eq 1 ]
  run _nx_ov_parse 'github:o/r?dir=k8s'
  [ "$status" -eq 1 ]
}

@test "parse: lookalike repositories get different keys" {
  [ "$(_key github:a-b/c)" != "$(_key github:a/b-c)" ]
}

# -- choosing ------------------------------------------------------------------

@test "choose: one overlay, then default, then refusal listing the names" {
  run _nx_ov_choose "$(printf 'k8s\tKubernetes')" false false
  [ "$output" = k8s ]
  run _nx_ov_choose "$(printf 'base\t\ndefault\t\nk8s\t')" false false
  [ "$output" = default ]
  run _nx_ov_choose "$(printf 'base\tShell\nk8s\tKubernetes')" false false
  [ "$status" -eq 1 ]
  [[ "$output" == *"none named default"*"base - Shell"*"k8s - Kubernetes"* ]]
  run _nx_ov_choose "$(printf 'base\t\nk8s\t')" true false
  [ "$output" = "$(printf 'base\nk8s')" ]
}

@test "choose: the picker takes numbers and names" {
  run _nx_ov_choose "$(printf 'base\t\ncloud\t\nk8s\t')" false true <<<"1 k8s"
  [ "$status" -eq 0 ]
  [[ "$output" == *"$(printf 'base\nk8s')" ]]
}

@test "list: a repository without overlays/ is refused" {
  mkdir -p "$TEST_HOME/plain"
  run _nx_ov_list "$TEST_HOME/plain" "" true
  [ "$status" -eq 2 ]
  [[ "$output" == *"no overlays/ in this repository"* ]]
}

# -- acceptance on the fixture layout ------------------------------------------

@test "acceptance 1: browse lists the four overlays with their README lines" {
  run _nx overlay browse "$REMOTE"
  [ "$status" -eq 0 ]
  [[ "$output" == *base*" - Shell, PowerShell and oh-my-posh"*cloud*" - Azure"*dev*" - Python"*k8s*" - Kubernetes tools and sofka"* ]]
}

@test "acceptance 2 and 5: --overlay <repo>#k8s subscribes k8s with k8s/k8s and k8s/sofka" {
  overlay_args=("$REMOTE#k8s")
  _pass
  grep -qx "k8s k8s - $REMOTE" "$ENV_DIR/overlays.list"
  _config_scopes | grep -qx 'k8s/k8s'
  _config_scopes | grep -qx 'k8s/sofka'
  _config_scopes | grep -qx 'k8s_base'
  run ! grep -q '"base/' "$ENV_DIR/overlays/index.nix"
}

@test "acceptance 3: no name with several overlays refuses unattended and lists them" {
  overlay_args=("$REMOTE")
  run _overlays_save_args
  [ "$status" -eq 2 ]
  [[ "$output" == *"base - "*"cloud - "*"dev - "*"k8s - "* ]]
}

@test "acceptance 4: --all subscribes all four from one clone" {
  run _nx overlay add "$REMOTE" --all
  [ "$status" -eq 0 ]
  [ "$(wc -l <"$ENV_DIR/overlays.list" | tr -d ' ')" = 4 ]
  _pass
  [ "$(find "$XDG_CACHE_HOME/nix-env/overlays" -mindepth 1 -maxdepth 1 | wc -l | tr -d ' ')" = 1 ]
  _config_scopes | grep -qx 'dev/dev'
  _config_scopes | grep -qx 'cloud/cloud'
}

@test "acceptance 6: a local folder without .git is copied and runs its hooks; remote does not" {
  local plain="$TEST_HOME/plain-overlays"
  cp -R "$WORK" "$plain"
  rm -rf "$plain/.git"
  mkdir -p "$plain/overlays/k8s/hooks/post-setup.d" "$WORK/overlays/k8s/hooks/post-setup.d"
  printf 'touch "%s/ran-local"\n' "$TEST_HOME" >"$plain/overlays/k8s/hooks/post-setup.d/10.sh"
  printf 'touch "%s/ran-remote"\n' "$TEST_HOME" >"$WORK/overlays/k8s/hooks/post-setup.d/10.sh"
  _push "remote hook"
  overlay_args=("$plain#k8s")
  _pass
  _config_scopes | grep -qx 'k8s/sofka'
  phase_platform_run_overlay_hooks >/dev/null
  [ -f "$TEST_HOME/ran-local" ]
  rm -f "$ENV_DIR/overlays.list"
  overlay_args=("$REMOTE#k8s")
  _pass
  phase_platform_run_overlay_hooks >/dev/null
  [ ! -f "$TEST_HOME/ran-remote" ]
}

@test "acceptance 7: a fifth overlay upstream changes nothing for existing subscriptions" {
  overlay_args=("$REMOTE#k8s")
  _pass
  local before
  before="$(cat "$ENV_DIR/overlays.list")"
  _overlay default "Everything" "shell"
  _push "fifth overlay"
  overlay_args=()
  _pass
  [ "$(cat "$ENV_DIR/overlays.list")" = "$before" ]
  run ! grep -q '"default/' "$ENV_DIR/overlays/index.nix"
}

@test "acceptance 8: a symlink leaving the repository is refused with its name" {
  printf 'secret\n' >"$TEST_HOME/secret"
  ln -s "$TEST_HOME/secret" "$WORK/overlays/k8s/scopes/leak.nix"
  _push "leak"
  overlay_args=("$REMOTE#k8s")
  run phase_overlays_sync
  [[ "$output" == *"overlays/k8s/scopes/leak.nix: refused - the symlink resolves outside the repository"* ]]
  run ! grep -rq secret "$ENV_DIR/overlays"
}

# -- setup phase ---------------------------------------------------------------

@test "phase: the copy holds *.nix and subscribed shell_cfg only" {
  overlay_args=("$REMOTE#base")
  _pass
  local copy
  copy="$ENV_DIR/overlays/$(_key "$REMOTE")"
  [ -f "$copy/lib/sofka.nix" ]
  [ ! -e "$copy/README.md" ]
  [ ! -e "$copy/.git" ]
  [ ! -e "$copy/overlays/k8s/shell_cfg" ]
}

@test "phase: a shell_cfg folder symlinked outside the repository is refused" {
  mkdir -p "$TEST_HOME/outside"
  printf 'secret\n' >"$TEST_HOME/outside/evil.sh"
  ln -s "$TEST_HOME/outside" "$WORK/overlays/base/shell_cfg"
  _push "outside shell_cfg"
  overlay_args=("$REMOTE#base")
  run phase_overlays_sync
  [[ "$output" == *"overlays/base/shell_cfg/evil.sh: refused"* ]]
  run ! grep -rq secret "$ENV_DIR/overlays"
}

@test "phase: a symlink into .git is refused" {
  ln -s ../../../.git/config "$WORK/overlays/base/scopes/cfg.nix"
  _push "git link"
  overlay_args=("$REMOTE#base")
  run phase_overlays_sync
  [[ "$output" == *"overlays/base/scopes/cfg.nix: refused - it resolves into a .git folder"* ]]
}

@test "phase: an update prints the commit range and the changed files" {
  overlay_args=("$REMOTE#dev")
  _pass
  printf '# scopes: python\n{ pkgs }: with pkgs; [ jq fd ]\n' >"$WORK/overlays/dev/scopes/dev.nix"
  _push "add fd"
  overlay_args=()
  run phase_overlays_sync
  [[ "$output" == *"overlay $REMOTE: updated "* ]]
  [[ "$output" == *"add fd"* ]]
  [[ "$output" == *"overlays/dev/scopes/dev.nix"* ]]
}

@test "phase: an unattended run skips a shell_cfg change, a new ref applies it" {
  overlay_args=("$REMOTE#k8s")
  _pass
  printf 'alias k=kubecolor\n' >"$WORK/overlays/k8s/shell_cfg/k8s.sh"
  _commit "v2"
  git -C "$WORK" tag v2
  git -C "$WORK" push -q origin HEAD:main v2
  overlay_args=()
  run phase_overlays_sync
  [[ "$output" == *"shell config change skipped"* ]]
  overlay_args=("$REMOTE?ref=v2#k8s")
  run phase_overlays_sync
  [[ "$output" != *"skipped"* ]]
  grep -q kubecolor "$ENV_DIR/overlays/$(_key "$REMOTE" v2)/overlays/k8s/shell_cfg/k8s.sh"
  grep -qx "k8s k8s v2 $REMOTE" "$ENV_DIR/overlays.list"
}

@test "phase: an unreachable repository fails alone" {
  _subscribe "gone gone - file://$TEST_HOME/missing.git" "dev dev - $REMOTE"
  run phase_overlays_sync
  [ "$status" -eq 0 ]
  [[ "$output" == *"overlay file://$TEST_HOME/missing.git: could not fetch"* ]]
  _pass 2>/dev/null
  _config_scopes | grep -qx 'dev/dev'
}

@test "phase: a missing local folder keeps its previous copy and removes nothing" {
  local plain="$TEST_HOME/plain-overlays"
  cp -R "$WORK" "$plain"
  overlay_args=("$plain#cloud")
  _pass
  rm -rf "$plain"
  overlay_args=()
  run _pass
  [[ "$output" == *"missing or unreadable - keeping the previous copy"* ]]
  [[ "$output" != *"removing it"* ]]
  _pass 2>/dev/null
  _config_scopes | grep -qx 'cloud/cloud'
  _config_scopes | grep -qx 'gcloud'
}

@test "phase: a ref that cannot be fetched keeps the previous copy" {
  overlay_args=("$REMOTE#dev")
  _pass
  _subscribe "dev dev nope $REMOTE"
  overlay_args=()
  run phase_overlays_sync
  [[ "$output" == *"overlay dev: keeping the previous copy"* ]]
  _pass 2>/dev/null
  _config_scopes | grep -qx 'dev/dev'
}

@test "phase: a dropped header name is removed once" {
  overlay_args=("$REMOTE#dev")
  _pass
  printf '# scopes: python nodejs\n{ pkgs }: with pkgs; [ jq ]\n' >"$WORK/overlays/dev/scopes/dev.nix"
  _push "drop bun"
  overlay_args=()
  remove_scopes=()
  run _pass
  [[ "$output" == *"bun is no longer named by an overlay - removing it"* ]]
}

@test "phase: an excluded scope stays out across updates; re-adding keeps it out" {
  overlay_args=("$REMOTE#k8s")
  _pass
  printf 'k8s/sofka\n' >"$ENV_DIR/overlays.exclude"
  _pass
  run ! grep -q '"k8s/sofka"' "$CONFIG_NIX"
  overlay_args=("$REMOTE#k8s")
  _pass
  run ! grep -q '"k8s/sofka"' "$CONFIG_NIX"
  grep -qx 'k8s/sofka' "$ENV_DIR/overlays.exclude"
}

@test "phase: removing every subscription drops the scopes and the copies" {
  overlay_args=("$REMOTE#dev")
  _pass
  : >"$ENV_DIR/overlays.list"
  overlay_args=()
  _pass
  run ! grep -q '"dev/' "$CONFIG_NIX"
  [ ! -d "$ENV_DIR/overlays" ]
}

@test "phase: --overlay under a name another repository holds stops" {
  _subscribe "k8s k8s - github:someone/else"
  overlay_args=("$REMOTE#k8s")
  run _overlays_save_args
  [ "$status" -eq 1 ]
  [[ "$output" == *"--as <name>"* ]]
}

@test "phase: every applied overlay joins OVERLAY_DIR before the personal scopes" {
  mkdir -p "$ENV_DIR/local"
  overlay_args=("$REMOTE#dev")
  phase_platform_discover_overlay >/dev/null
  phase_overlays_sync >/dev/null
  [ "$OVERLAY_DIR" = "$ENV_DIR/overlays/$(_key "$REMOTE")/overlays/dev:$ENV_DIR/local" ]
}

@test "phase: a pinned tag moved onto unrelated history is not applied" {
  git -C "$WORK" tag v1
  git -C "$WORK" push -q origin v1
  overlay_args=("$REMOTE?ref=v1#dev")
  _pass
  git -C "$WORK" checkout -q --orphan other
  printf '{ pkgs }: with pkgs; [ evil ]\n' >"$WORK/overlays/dev/scopes/dev.nix"
  _commit "unrelated"
  git -C "$WORK" tag -f v1
  git -C "$WORK" push -q -f origin v1
  overlay_args=()
  run phase_overlays_sync
  [[ "$output" == *"v1 moved to a commit that does not descend from the current one"* ]]
  run ! grep -rq evil "$ENV_DIR/overlays"
}

@test "phase: a missing overlay name warns and adds nothing" {
  _subscribe "nope nope - $REMOTE"
  run phase_overlays_sync
  [[ "$output" == *"overlay nope: no overlays/nope in $REMOTE"* ]]
}

@test "phase: a list whose last line has no newline still counts it" {
  printf 'dev dev - %s' "$REMOTE" >"$ENV_DIR/overlays.list"
  _pass
  _config_scopes | grep -qx 'dev/dev'
}

@test "phase: the legacy organization overlay folder warns and removes nothing" {
  export NIX_ENV_OVERLAY_DIR="$TEST_HOME/org"
  printf 'org gcloud /x/team.nix\n' >"$ENV_DIR/overlay_scopes"
  printf '{\n  isInit = false;\n\n  scopes = [\n    "gcloud"\n  ];\n}\n' >"$CONFIG_NIX"
  scope_add gcloud
  remove_scopes=()
  run phase_platform_discover_overlay
  [[ "$output" == *"NIX_ENV_OVERLAY_DIR and nx overlay set are gone"* ]]
  phase_platform_discover_overlay 2>/dev/null
  phase_scopes_apply_overlay
  [ "${#remove_scopes[@]}" -eq 0 ]
}

# -- nx verbs ------------------------------------------------------------------

_nx() {
  source "$REPO_ROOT/.assets/lib/nx.sh"
  _nx_pkg_upgrade() { echo "UPGRADE"; }
  _nx_lifecycle_setup() { echo "SETUP $*"; }
  _nx_apply() { echo "APPLY"; }
  nx_main "$@"
}

@test "nx overlay add: names pick overlays, --as renames one, setup applies them" {
  run _nx overlay add "$REMOTE" k8s dev </dev/null
  [ "$status" -eq 0 ]
  # no terminal: setup runs unattended, so nothing waits on a prompt
  [[ "$output" == *"SETUP --unattended"* ]]
  grep -qx "k8s k8s - $REMOTE" "$ENV_DIR/overlays.list"
  grep -qx "dev dev - $REMOTE" "$ENV_DIR/overlays.list"
  mkdir -p "$TEST_HOME/other/overlays/k8s/scopes"
  run _nx overlay add "$TEST_HOME/other#k8s"
  [ "$status" -eq 1 ]
  [[ "$output" == *"already subscribes"* ]]
  run _nx overlay add "$TEST_HOME/other#k8s" --as k8s-other
  [ "$status" -eq 0 ]
  grep -qx "k8s-other k8s - $TEST_HOME/other" "$ENV_DIR/overlays.list"
}

@test "nx overlay add: no name with several overlays and no terminal refuses" {
  run _nx overlay add "$REMOTE" </dev/null
  [ "$status" -eq 1 ]
  [[ "$output" == *"none named default"* ]]
  [ ! -e "$ENV_DIR/overlays.list" ]
}

@test "nx overlay add: re-adding keeps the line and the exclusions" {
  printf 'k8s k8s - %s\n' "$REMOTE" >"$ENV_DIR/overlays.list"
  printf 'k8s/sofka\n' >"$ENV_DIR/overlays.exclude"
  run _nx overlay add "$REMOTE" k8s
  [ "$status" -eq 0 ]
  [[ "$output" == *"Already subscribed"* ]]
  grep -qx 'k8s/sofka' "$ENV_DIR/overlays.exclude"
}

@test "nx overlay add: a relative folder becomes absolute and keeps #overlay" {
  mkdir -p "$TEST_HOME/rel/catalog/overlays/k8s/scopes"
  cd "$TEST_HOME/rel"
  run _nx overlay add './catalog#k8s'
  [ "$status" -eq 0 ]
  grep -qx "k8s k8s - $TEST_HOME/rel/catalog" "$ENV_DIR/overlays.list"
}

@test "nx overlay remove: several names, their exclusions go too" {
  printf 'web web - github:o/r\nk8s k8s - github:o/r\ndev dev - github:o/r\n' >"$ENV_DIR/overlays.list"
  printf 'web/base\nk8s/base\n' >"$ENV_DIR/overlays.exclude"
  run _nx overlay remove web dev
  [ "$status" -eq 0 ]
  [[ "$output" == *"SETUP --skip-configure"* ]]
  [ "$(cat "$ENV_DIR/overlays.list")" = "k8s k8s - github:o/r" ]
  [ "$(cat "$ENV_DIR/overlays.exclude")" = "k8s/base" ]
}

@test "nx overlay: lists subscriptions with their scopes" {
  printf 'k8s k8s v2 github:o/r\n' >"$ENV_DIR/overlays.list"
  mkdir -p "$ENV_DIR/overlays"
  printf '{\n  "k8s/k8s" = ./. + "/x/overlays/k8s/scopes/k8s.nix";\n  "k8s/sofka" = ./. + "/x/overlays/k8s/scopes/sofka.nix";\n}\n' >"$ENV_DIR/overlays/index.nix"
  printf 'k8s/sofka\n' >"$ENV_DIR/overlays.exclude"
  run _nx overlay
  [ "$status" -eq 0 ]
  [[ "$output" == *"k8s"*"overlay k8s of github:o/r at v2"*"not fetched"*"k8s/k8s"*"k8s/sofka"*"(opted out)"* ]]
}

@test "nx overlay: an unknown subcommand is refused" {
  run _nx overlay set /tmp
  [ "$status" -eq 1 ]
}

@test "nx scope remove/add: a subscribed scope opts out and back in through setup" {
  mkdir -p "$ENV_DIR/overlays"
  printf '{\n  "k8s/sofka" = ./. + "/x/overlays/k8s/scopes/sofka.nix";\n}\n' >"$ENV_DIR/overlays/index.nix"
  printf '{\n  isInit = false;\n  allowUnfree = true;\n\n  scopes = [\n    "shell"\n    "k8s/sofka"\n  ];\n}\n' >"$CONFIG_NIX"
  run _nx scope remove k8s/sofka
  [ "$status" -eq 0 ]
  grep -qx 'k8s/sofka' "$ENV_DIR/overlays.exclude"
  run ! grep -q '"k8s/sofka"' "$CONFIG_NIX"
  grep -q 'allowUnfree = true;' "$CONFIG_NIX"
  run _nx scope add k8s/sofka
  [ "$status" -eq 0 ]
  [[ "$output" == *"SETUP"* ]]
  [ ! -s "$ENV_DIR/overlays.exclude" ]
}

@test "nx scope remove: an id no subscription provides is refused" {
  printf '{\n  isInit = false;\n\n  scopes = [\n    "shell"\n  ];\n}\n' >"$CONFIG_NIX"
  run _nx scope remove web/base
  [ "$status" -eq 1 ]
  [[ "$output" == *"not a scope of a subscribed overlay"* ]]
}

# -- review fixes --------------------------------------------------------------

@test "phase: a nameless --overlay already subscribed is not resolved again" {
  local plain="$TEST_HOME/single"
  mkdir -p "$plain/overlays/only/scopes"
  printf '{ pkgs }: with pkgs; [ jq ]\n' >"$plain/overlays/only/scopes/only.nix"
  overlay_args=("$plain")
  _pass
  mkdir -p "$plain/overlays/default/scopes"
  printf '{ pkgs }: with pkgs; [ jq ]\n' >"$plain/overlays/default/scopes/default.nix"
  _pass
  [ "$(cat "$ENV_DIR/overlays.list")" = "only only - $plain" ]
}

@test "phase: --overlay naming an overlay the repository lacks is refused" {
  overlay_args=("$REMOTE#typo")
  run _overlays_save_args
  [ "$status" -eq 2 ]
  [[ "$output" == *"has no overlay typo"* ]]
  [ ! -e "$ENV_DIR/overlays.list" ]
}

@test "phase: a local source that cannot be read in full keeps the previous copy" {
  [ "$(id -u)" -ne 0 ] || skip "root reads everything"
  local plain="$TEST_HOME/plain-overlays"
  cp -R "$WORK" "$plain"
  overlay_args=("$plain#cloud")
  _pass
  chmod 000 "$plain/overlays/cloud/scopes"
  overlay_args=()
  run _pass
  chmod 755 "$plain/overlays/cloud/scopes"
  [[ "$output" == *"could not be read in full - keeping the previous copy"* ]]
  [[ "$output" != *"removing it"* ]]
  [ -f "$ENV_DIR/overlays/$(_key "$plain")/overlays/cloud/scopes/cloud.nix" ]
}

@test "phase: a local overlay with no scope file still runs its hooks" {
  local plain="$TEST_HOME/hooks-only"
  mkdir -p "$plain/overlays/tools/hooks/post-setup.d"
  printf 'touch "%s/ran"\n' "$TEST_HOME" >"$plain/overlays/tools/hooks/post-setup.d/10.sh"
  overlay_args=("$plain#tools")
  _pass
  phase_platform_run_overlay_hooks >/dev/null
  [ -f "$TEST_HOME/ran" ]
}

@test "phase: an overlay hook gets the trust-store variables when the cert files exist" {
  local plain="$TEST_HOME/hooks-certs"
  # the developer's own shell may export them already
  unset NODE_EXTRA_CA_CERTS SSL_CERT_FILE PIP_CERT
  mkdir -p "$plain/overlays/tools/hooks/post-setup.d" "$HOME/.config/certs"
  printf 'printf "%%s|%%s|%%s\\n" "$NODE_EXTRA_CA_CERTS" "$SSL_CERT_FILE" "$PIP_CERT" >"%s/env"\n' "$TEST_HOME" \
    >"$plain/overlays/tools/hooks/post-setup.d/10.sh"
  overlay_args=("$plain#tools")
  _pass
  phase_platform_run_overlay_hooks >/dev/null
  [ "$(cat "$TEST_HOME/env")" = "||" ]
  : >"$HOME/.config/certs/ca-custom.crt"
  : >"$HOME/.config/certs/ca-bundle.crt"
  phase_platform_run_overlay_hooks >/dev/null
  local c="$HOME/.config/certs"
  [ "$(cat "$TEST_HOME/env")" = "$c/ca-custom.crt|$c/ca-bundle.crt|$c/ca-bundle.crt" ]
}

@test "phase: a symlinked local folder is copied through the link" {
  local plain="$TEST_HOME/plain-overlays"
  cp -R "$WORK" "$plain"
  ln -s "$plain" "$TEST_HOME/link-overlays"
  overlay_args=("$TEST_HOME/link-overlays#cloud")
  _pass
  _config_scopes | grep -qx 'cloud/cloud'
}

@test "parse: a local folder path with a colon is refused" {
  run _nx_ov_parse '/opt/a:b#k8s'
  [ "$status" -eq 1 ]
}

@test "nx overlay add: a refused name leaves earlier names unwritten" {
  printf 'dev dev - github:someone/else\n' >"$ENV_DIR/overlays.list"
  run _nx overlay add "$REMOTE" k8s dev
  [ "$status" -eq 1 ]
  [ "$(cat "$ENV_DIR/overlays.list")" = "dev dev - github:someone/else" ]
  run _nx overlay add "$REMOTE" typo
  [ "$status" -eq 1 ]
  [[ "$output" == *"has no overlay typo"* ]]
}

@test "choose: the picker splits picks under zsh too" {
  command -v zsh >/dev/null 2>&1 || skip "zsh not installed"
  run zsh -c "source '$REPO_ROOT/.assets/lib/nx_overlay.sh'; _nx_ov_choose \"\$(printf 'base\t\ncloud\t\nk8s\t')\" false true <<<'1 k8s'"
  [ "$status" -eq 0 ]
  [[ "$output" == *"$(printf 'base\nk8s')" ]]
}

# -- decision 16: an address on the command line is an explicit request --------

@test "explicit: the same --overlay on every start applies a shell_cfg change unattended" {
  overlay_args=("$REMOTE#k8s")
  _pass
  printf 'alias k=kubecolor\n' >"$WORK/overlays/k8s/shell_cfg/k8s.sh"
  _push "new alias"
  run phase_overlays_sync
  [[ "$output" != *"skipped"* ]]
  grep -q kubecolor "$ENV_DIR/overlays/$(_key "$REMOTE")/overlays/k8s/shell_cfg/k8s.sh"
}

@test "explicit: an --overlay source that cannot be read stops setup" {
  local plain="$TEST_HOME/plain-overlays"
  cp -R "$WORK" "$plain"
  overlay_args=("$plain#cloud")
  _pass
  rm -rf "$plain"
  run phase_overlays_sync
  [ "$status" -eq 1 ]
  [[ "$output" == *"overlay cloud: could not read $plain"* ]]
}

@test "explicit: an --overlay whose remote cannot be fetched stops setup despite a cached clone" {
  overlay_args=("$REMOTE#dev")
  _pass
  mv "$REMOTE_DIR" "$REMOTE_DIR.gone"
  run phase_overlays_sync
  mv "$REMOTE_DIR.gone" "$REMOTE_DIR"
  [ "$status" -eq 1 ]
  [[ "$output" == *"overlay dev: could not read $REMOTE"* ]]
  overlay_args=()
  run phase_overlays_sync
  [ "$status" -eq 0 ]
}

@test "explicit: an --overlay whose overlay left the repository stops setup" {
  overlay_args=("$REMOTE#dev")
  _pass
  rm -rf "$WORK/overlays/dev"
  _push "drop dev"
  run phase_overlays_sync
  [ "$status" -eq 2 ]
  [[ "$output" == *"overlay dev: $REMOTE has no overlays/dev"* ]]
}

@test "explicit: nx overlay add marks its names for setup" {
  _nx_lifecycle_setup() { echo "EXPLICIT=$NX_OVERLAY_EXPLICIT"; }
  source "$REPO_ROOT/.assets/lib/nx.sh"
  _nx_lifecycle_setup() { echo "EXPLICIT=$NX_OVERLAY_EXPLICIT"; }
  run nx_main overlay add "$REMOTE" k8s
  [[ "$output" == *"EXPLICIT= k8s"* ]]
  [ -z "${NX_OVERLAY_EXPLICIT:-}" ]
}

# -- decision 15: opting out of a scope an overlay header names ------------------

@test "opt-out: a header scope in overlays.exclude is removed once and stays out" {
  overlay_args=("$REMOTE#dev")
  _pass
  _config_scopes | grep -qx bun
  printf 'bun\n' >"$ENV_DIR/overlays.exclude"
  overlay_args=()
  remove_scopes=()
  _pass >"$TEST_HOME/out" 2>&1
  grep -q "bun is no longer named by an overlay - removing it" "$TEST_HOME/out"
  [[ " ${remove_scopes[*]} " == *" bun "* ]]
  [[ "$overlay_entries" != *"sub bun "* ]]
  # the next run neither merges it back nor removes it again
  remove_scopes=()
  _pass 2>/dev/null
  [[ " ${remove_scopes[*]} " != *" bun "* ]]
  [[ "$overlay_entries" != *"sub bun "* ]]
}

@test "opt-out: setup.sh --remove of a header scope opts out of it" {
  overlay_args=("$REMOTE#dev")
  _pass
  overlay_args=()
  remove_scopes=(bun)
  phase_platform_discover_overlay >/dev/null
  phase_overlays_sync >/dev/null
  phase_scopes_apply_overlay
  [[ " ${remove_scopes[*]} " == *" bun "* ]]
  grep -qx bun "$ENV_DIR/overlays.exclude"
}

@test "opt-out: nx scope remove/add of a header scope go through overlays.exclude" {
  printf 'sub bun %s\n' "$ENV_DIR/overlays/x/overlays/dev/scopes/dev.nix" >"$ENV_DIR/overlay_scopes"
  printf '{\n  isInit = false;\n\n  scopes = [\n    "bun"\n  ];\n}\n' >"$CONFIG_NIX"
  run _nx scope remove bun
  [ "$status" -eq 0 ]
  [[ "$output" == *"opted out"*"SETUP --skip-configure"* ]]
  grep -qx bun "$ENV_DIR/overlays.exclude"
  grep -q '"bun"' "$CONFIG_NIX"
  run _nx scope add bun
  [ "$status" -eq 0 ]
  [[ "$output" == *"back in"*"SETUP"* ]]
  [ ! -s "$ENV_DIR/overlays.exclude" ]
}
