# phase: bootstrap
# Root guard, path resolution, nix/jq detection, ENV_DIR sync, arg parsing.
# shellcheck disable=SC2034  # variables used by other phases
#
# Reads:  BASH_SOURCE (for path resolution)
# Writes: SCRIPT_ROOT, NIX_ENV_VERSION, NIX_SRC, CONFIGURE_DIR, ENV_DIR,
#         CONFIG_NIX, omp_theme, starship_theme, unattended, update_modules,
#         upgrade_packages, quiet_summary, allow_unfree, remove_scopes,
#         any_scope, _scope_set, _ir_skip

# Refresh the repo from upstream when behind. Skips silently when:
#   - NX_REEXECED is already set (we are the post-exec invocation; refresh
#     already ran in the parent process - guards against the pathological
#     loop where upstream still reports as behind after our reset)
#   - --skip-repo-update is in $@ (caller already refreshed the repo, e.g.
#     wsl_setup.ps1's Update-GitRepository, or developer iterating locally)
#   - SCRIPT_ROOT is not a git work tree (tarball install)
#   - git is unavailable
#   - no upstream tracking branch is configured (e.g. detached HEAD on CI)
#   - working tree has uncommitted changes (would be discarded by reset)
#   - HEAD has diverged from upstream (would discard local commits)
# Uses ls-remote as a cheap pre-check (one small network round-trip, no local
# writes) to skip the heavy `git fetch` when the remote tip already matches the
# local tracking ref - the common case on rerun. After a successful update,
# `exec`s the new setup.sh with the same args (instead of exiting and asking
# the user to re-run), so the user invocation completes in one go.
phase_bootstrap_refresh_repo() {
  [ -n "${NX_REEXECED:-}" ] && return 0
  local _arg
  for _arg in "$@"; do
    [ "$_arg" = "--skip-repo-update" ] && return 0
  done
  command -v git >/dev/null 2>&1 || return 0
  git -C "$SCRIPT_ROOT" rev-parse --is-inside-work-tree >/dev/null 2>&1 || return 0

  local upstream
  upstream="$(git -C "$SCRIPT_ROOT" rev-parse --abbrev-ref --symbolic-full-name '@{upstream}' 2>/dev/null)" || return 0
  [ -n "$upstream" ] || return 0
  local remote="${upstream%%/*}"
  local branch="${upstream#*/}"

  local remote_sha local_sha
  remote_sha="$(git -C "$SCRIPT_ROOT" ls-remote --heads "$remote" "$branch" 2>/dev/null | awk 'NR==1{print $1}')"
  local_sha="$(git -C "$SCRIPT_ROOT" rev-parse "$upstream" 2>/dev/null)"
  if [ -n "$remote_sha" ] && [ -n "$local_sha" ] && [ "$remote_sha" = "$local_sha" ]; then
    [ "$(git -C "$SCRIPT_ROOT" rev-parse HEAD)" = "$local_sha" ] && return 0
    _bootstrap_refresh_apply "$upstream" "$@"
    return 0
  fi

  if ! git -C "$SCRIPT_ROOT" fetch --tags --prune --prune-tags --force "$remote" 2>/dev/null; then
    warn "failed to fetch from $remote, continuing with current revision"
    return 0
  fi
  local head_sha upstream_sha
  head_sha="$(git -C "$SCRIPT_ROOT" rev-parse HEAD)"
  upstream_sha="$(git -C "$SCRIPT_ROOT" rev-parse "$upstream")"
  [ "$head_sha" = "$upstream_sha" ] && return 0
  _bootstrap_refresh_apply "$upstream" "$@"
}

# Apply upstream as new HEAD when the working tree is clean and HEAD is an
# ancestor of upstream (safe fast-forward). Bails with a warning when local
# work would be lost - protects feature-branch and dirty-tree development.
# On success, `exec`s the new setup.sh so the user invocation continues
# transparently with the refreshed source. NX_REEXECED is exported as a loop
# guard - the post-exec invocation skips the whole refresh phase via the
# guard at the top of phase_bootstrap_refresh_repo. exec failures fall
# through to set -e (script exits, EXIT trap records the failure).
_bootstrap_refresh_apply() {
  local upstream="$1"
  shift
  if [ -n "$(git -C "$SCRIPT_ROOT" status --porcelain 2>/dev/null)" ]; then
    warn "uncommitted changes in $SCRIPT_ROOT - skipping auto-update of repository"
    return 0
  fi
  if ! git -C "$SCRIPT_ROOT" merge-base --is-ancestor HEAD "$upstream" 2>/dev/null; then
    warn "local branch has diverged from $upstream - skipping auto-update"
    return 0
  fi
  git -C "$SCRIPT_ROOT" reset --hard "$upstream" >/dev/null
  info "repository updated to $upstream - re-executing with new source"
  export NX_REEXECED=1
  exec bash "$SCRIPT_ROOT/nix/setup.sh" "$@"
}

phase_bootstrap_check_root() {
  if [[ $EUID -eq 0 ]]; then
    err "Do not run the script as root (sudo)."
    exit 1
  fi
}

phase_bootstrap_resolve_paths() {
  SCRIPT_ROOT="${1:?phase_bootstrap_resolve_paths requires repo root}"
  NIX_ENV_VERSION="$(git -C "$SCRIPT_ROOT" describe --tags --dirty 2>/dev/null ||
    cat "$SCRIPT_ROOT/VERSION" 2>/dev/null ||
    git -C "$SCRIPT_ROOT" rev-parse --short HEAD 2>/dev/null ||
    echo "unknown")"
  export NIX_ENV_VERSION
  NIX_SRC="$SCRIPT_ROOT/nix"
  CONFIGURE_DIR="$SCRIPT_ROOT/nix/configure"
  ENV_DIR="$HOME/.config/nix-env"
  CONFIG_NIX="$ENV_DIR/config.nix"
}

# Provenance line printed early in setup so the user (and CI logs) can see
# which checkout + branch + version is actually running. Mirrors the same
# shape that nx_lifecycle.sh:_nx_lifecycle_setup prints when launching
# nix/setup.sh from the nx CLI; the version field is appended here so
# `Running setup from <path> (<branch> [<version>])` matches `nx version`.
# Always prints (no quiet_summary gate) - it's a one-line provenance marker
# useful even in quiet mode.
phase_bootstrap_print_banner() {
  local _branch
  _branch="$(git -C "$SCRIPT_ROOT" rev-parse --abbrev-ref HEAD 2>/dev/null)" || _branch=""
  printf '\n\e[96mRunning setup from %s' "$SCRIPT_ROOT"
  if [ -n "$_branch" ]; then
    printf ' (\e[3;90m%s\e[0;96m [\e[3;90m%s\e[0;96m])' "$_branch" "$NIX_ENV_VERSION"
  else
    printf ' ([\e[3;90m%s\e[0;96m])' "$NIX_ENV_VERSION"
  fi
  printf '\e[0m\n'
}

# Build ca-bundle.crt and self-heal stale cert env vars BEFORE any nix or
# git network call. Without this, a user who deletes ~/.config/certs/ca-bundle.crt
# (or whose previous run left a stale path in NIX_SSL_CERT_FILE / git
# http.sslCAInfo) hits opaque failures in nix profile commands during
# install_jq, because the inherited env var points at a missing file and
# nix's OpenSSL aborts before any of our error handlers print a message.
# build_ca_bundle is cheap (Linux: ln -sf to system bundle; macOS: Keychain
# dump via security) and works without nix being installed yet.
phase_bootstrap_ensure_certs() {
  # shellcheck source=../../../.assets/lib/certs.sh
  source "$SCRIPT_ROOT/.assets/lib/certs.sh"
  build_ca_bundle
  # If env vars still point to a missing file (e.g. build_ca_bundle no-op'd
  # on an unsupported Linux distro without /etc/ssl/certs), unset so nix
  # tools fall back to their bundled cacert instead of aborting.
  if [ -n "${NIX_SSL_CERT_FILE:-}" ] && [ ! -f "$NIX_SSL_CERT_FILE" ]; then
    warn "NIX_SSL_CERT_FILE=$NIX_SSL_CERT_FILE points to missing file - unsetting for this run"
    unset NIX_SSL_CERT_FILE
  fi
  if [ -n "${SSL_CERT_FILE:-}" ] && [ ! -f "$SSL_CERT_FILE" ]; then
    warn "SSL_CERT_FILE=$SSL_CERT_FILE points to missing file - unsetting for this run"
    unset SSL_CERT_FILE
  fi
}

_source_nix_profile() {
  for nix_profile in \
    "$HOME/.nix-profile/etc/profile.d/nix.sh" \
    /nix/var/nix/profiles/default/etc/profile.d/nix-daemon.sh; do
    if [ -f "$nix_profile" ]; then
      # shellcheck source=/dev/null
      . "$nix_profile"
      return 0
    fi
  done
  return 1
}

# Check whether a GID and UID range [base, base+32) are all unassigned on macOS.
_darwin_id_range_free() {
  local base=$1
  local end=$((base + 31))
  dscl . -list /Groups PrimaryGroupID 2>/dev/null |
    awk -v id="$base" '$NF == id {exit 1}' || return 1
  dscl . -list /Users UniqueID 2>/dev/null |
    awk -v lo="$base" -v hi="$end" '$NF >= lo && $NF <= hi {exit 1}' || return 1
  return 0
}

_install_nix_darwin() {
  info "Nix is not installed. Attempting automatic installation on macOS..."

  local id_base=""
  local candidate
  # prefer < 500 (macOS system band - hidden from login screen by default)
  # 300/400 are commonly reserved by macOS system services
  for candidate in 350 450 460 470 480 490 4000; do
    if _darwin_id_range_free "$candidate"; then
      id_base=$candidate
      break
    fi
    warn "GID/UID range $candidate is already in use, trying next..."
  done

  if [ -z "$id_base" ]; then
    _ir_error="Nix install failed: no free GID/UID range found"
    err "Could not find a free GID/UID range for Nix build users."
    err "Install Nix manually with a free range, e.g.:"
    err "  curl --proto '=https' --tlsv1.2 -sSf -L https://install.determinate.systems/nix | \\"
    err "    sh -s -- install --nix-build-group-id <GID> --nix-build-user-id-base <UID_BASE>"
    exit 1
  fi

  local install_args=(install --no-confirm)
  if [ "$id_base" -ne 350 ]; then
    install_args+=(--nix-build-group-id "$id_base" --nix-build-user-id-base "$id_base")
    info "using custom GID $id_base and UID base $id_base"
  fi

  _io_run curl --proto '=https' --tlsv1.2 -sSf -L https://install.determinate.systems/nix |
    sh -s -- "${install_args[@]}"

  _source_nix_profile
  if ! command -v nix &>/dev/null && [ -x "$HOME/.nix-profile/bin/nix" ]; then
    export PATH="$HOME/.nix-profile/bin:$PATH"
  fi

  if ! command -v nix &>/dev/null; then
    _ir_error="Nix installation completed but nix command not found"
    err "Nix installation completed but 'nix' command is not available."
    err "Open a new terminal and run setup.sh again."
    exit 1
  fi
  ok "Nix installed successfully"
}

phase_bootstrap_detect_nix() {
  if ! command -v nix &>/dev/null; then
    _source_nix_profile || true
  fi
  if ! command -v nix &>/dev/null && [ -x "$HOME/.nix-profile/bin/nix" ]; then
    export PATH="$HOME/.nix-profile/bin:$PATH"
  fi
  if ! command -v nix &>/dev/null; then
    if [ "$(uname -s)" = "Darwin" ]; then
      _install_nix_darwin
    else
      _ir_error="Nix is not installed"
      err "Nix is not installed. Install it first (requires root, one-time):"
      err "  curl --proto '=https' --tlsv1.2 -sSf -L https://install.determinate.systems/nix | sh -s -- install"
      exit 1
    fi
  fi
}

phase_bootstrap_verify_store() {
  if ! _io_nix store info &>/dev/null; then
    _ir_error="nix store is unreachable"
    err "nix store is unreachable. Possible causes:"
    err "  - nix daemon is not running (check: systemctl status nix-daemon)"
    err "  - nix was installed without --no-daemon and systemd is missing"
    err "Reinstall nix if needed: https://install.determinate.systems/nix"
    exit 1
  fi
}

phase_bootstrap_sync_env_dir() {
  mkdir -p "$ENV_DIR"
  cp "$NIX_SRC/flake.nix" "$ENV_DIR/"
  cp -r "$NIX_SRC/scopes" "$ENV_DIR/"
  # Sync scopes.json so nx commands can validate against the canonical
  # valid_scopes list at runtime (e.g. nx_scope.sh:add rejects overlay
  # names that collide with managed scopes). _nx_find_lib resolves it
  # via the same script_dir lookup as the .sh family files.
  cp "$SCRIPT_ROOT/.assets/lib/scopes.json" "$ENV_DIR/"
  # Atomic install for files that user shells may source/exec concurrently:
  # nx.sh is read on every `nx` invocation; nx_pkg/scope/profile/lifecycle.sh
  # are sourced by nx.sh at startup; profile_block.sh is sourced by
  # nx_profile.sh at runtime; nx_doctor.sh is exec'd by `nx doctor`. Plain
  # `cp` opens the dest with O_TRUNC and writes in chunks - a shell that
  # reads mid-write sees a half-written file (e.g. heredoc body without
  # its opening line, body lines then interpreted as commands).
  local _nx_lib
  # >>> nx-libs generated >>> (regenerate: python3 -m tests.hooks.gen_nx_completions)
  for _nx_lib in nx.sh nx_lifecycle.sh nx_pkg.sh nx_profile.sh nx_scope.sh nx_doctor.sh profile_block.sh; do
    # <<< nx-libs generated <<<
    install_atomic "$SCRIPT_ROOT/.assets/lib/$_nx_lib" "$ENV_DIR/$_nx_lib"
  done
  chmod +x "$ENV_DIR/nx.sh"
  ok "synced nix declarations to $ENV_DIR"
}

phase_bootstrap_install_jq() {
  if ! command -v jq &>/dev/null; then
    info "first run - installing base packages via nix..."
    cat >"$CONFIG_NIX" <<BOOTSTRAP
{
  isInit = true;
  allowUnfree = false;
  scopes = [];
}
BOOTSTRAP
    if ! _io_nix profile add "path:$ENV_DIR" 2>&1; then
      warn "nix profile add failed (may already exist) - continuing with upgrade"
    fi
    _io_nix profile upgrade nix-env ||
      {
        _ir_error="nix bootstrap failed"
        err "$_ir_error"
        exit 1
      }
  fi
}

usage() {
  cat <<'EOF'
Usage: nix/setup.sh [options]

Additive: scope flags add to the existing config. Without scope flags,
re-applies configuration using existing package versions (idempotent).
Use --upgrade to pull latest packages from nixpkgs.

Scope flags (add new packages - merged with existing config):
  --az          Azure CLI + azcopy
  --bun         Bun JavaScript/TypeScript runtime
  --conda       Miniforge (conda-forge)
  --docker      Docker post-install check (Docker itself installed separately)
  --gcloud      Google Cloud CLI
  --k8s-base    kubectl, kubelogin, k9s, kubecolor, kubectx/kubens
  --k8s-dev     argo rollouts, cilium, flux, helm, hubble, kustomize, trivy
  --k8s-ext     minikube, k3d, kind
  --nodejs      Node.js
  --pwsh        PowerShell
  --python      uv + prek (python managed by uv/conda, not nix)
  --rice        btop, cmatrix, cowsay, fastfetch
  --shell       fzf, eza, bat, ripgrep, yq
  --terraform   terraform, tflint
  --zsh         zsh plugins (autosuggestions, syntax-highlighting, completions)
  --all         Enable all scopes above

Options:
  --remove <scope> [...]    Remove one or more scopes (space-separated)
  --upgrade                 Update flake.lock to latest nixpkgs and upgrade all packages
  --allow-unfree            Allow unfree (proprietary-licensed) nix packages
  --omp-theme <name>        Install oh-my-posh with theme (base, nerd, powerline, ...)
  --starship-theme <name>   Install starship with theme (base, nerd)
  --unattended              Skip all interactive steps (gh auth, SSH key, git config)
  --skip-repo-update        Skip the git fetch + fast-forward of the source repo
  --update-modules          Update installed PowerShell modules
  -h, --help                Show this help
EOF
}

phase_bootstrap_parse_args() {
  omp_theme=""
  starship_theme=""
  unattended="false"
  update_modules="false"
  quiet_summary="false"
  upgrade_packages="false"
  allow_unfree="false"
  remove_scopes=()
  _scope_set=" "
  any_scope=false

  while [[ $# -gt 0 ]]; do
    case "$1" in
    -h | --help)
      _ir_skip=true
      usage
      exit 0
      ;;
    --az | --bun | --conda | --docker | --gcloud | --k8s-base | --k8s-dev | --k8s-ext | \
      --nodejs | --pwsh | --python | --rice | --shell | --terraform | --zsh)
      scope_add "${1#--}"
      any_scope=true
      ;;
    --all)
      for s in "${VALID_SCOPES[@]}"; do
        [[ "$s" == "oh_my_posh" || "$s" == "starship" ]] && continue
        scope_add "$s"
      done
      any_scope=true
      ;;
    --omp-theme)
      omp_theme="${2:-}"
      scope_add oh_my_posh
      any_scope=true
      shift
      ;;
    --starship-theme)
      starship_theme="${2:-}"
      scope_add starship
      any_scope=true
      shift
      ;;
    --remove)
      shift
      while [[ $# -gt 0 && "$1" != --* ]]; do
        remove_scopes+=("${1//-/_}")
        shift
      done
      if [[ ${#remove_scopes[@]} -eq 0 ]]; then
        err "--remove requires at least one scope name"
        usage
        exit 2
      fi
      continue
      ;;
    --unattended)
      unattended="true"
      ;;
    --skip-repo-update)
      # consumed earlier by phase_bootstrap_refresh_repo; accept here so
      # parse_args doesn't reject it as an unknown option
      ;;
    --update-modules)
      update_modules="true"
      ;;
    --allow-unfree)
      allow_unfree="true"
      ;;
    --upgrade)
      upgrade_packages="true"
      ;;
    --quiet-summary)
      quiet_summary="true"
      ;;
    *)
      err "Unknown option: $1"
      usage
      exit 2
      ;;
    esac
    shift
  done

  # normalize hyphenated flag names to underscored scope names
  _scope_set="${_scope_set//-/_}"
}
