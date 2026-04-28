# zsh tab completions for the nx command
function _nx() {
  local -a subcmds
  subcmds=(
    'search:search nixpkgs for a package'
    'install:install packages from nixpkgs'
    'remove:remove installed packages'
    'upgrade:upgrade all packages'
    'rollback:rollback to previous profile generation'
    'pin:manage nixpkgs revision pin'
    'list:list installed packages'
    'scope:manage scopes'
    'overlay:manage overlay directory'
    'profile:manage shell profile blocks'
    'doctor:run health checks'
    'prune:remove old profile generations'
    'gc:run nix garbage collection'
    'setup:run nix/setup.sh from anywhere'
    'self:manage the source repository'
    'version:show version information'
    'help:show help'
  )

  if (( CURRENT == 2 )); then
    _describe 'nx command' subcmds
    return
  fi

  case "${words[2]}" in
  scope)
    if (( CURRENT == 3 )); then
      local -a scope_cmds
      scope_cmds=(
        'list:list all scopes'
        'show:show scope contents'
        'tree:show scope dependency tree'
        'add:create a new overlay scope'
        'edit:edit a scope file'
        'remove:remove an overlay scope'
      )
      _describe 'scope command' scope_cmds
    elif (( CURRENT >= 4 )); then
      case "${words[3]}" in
      show|edit|remove|rm)
        local _env="$HOME/.config/nix-env"
        local -a _scopes
        _scopes=("${(@f)$(sed -n '/scopes[[:space:]]*=[[:space:]]*\[/,/\]/{
          s/^[[:space:]]*"\([^"]*\)".*/\1/p
        }' "$_env/config.nix" 2>/dev/null | sed 's/^local_//')}")
        local _f _n
        for _f in "$_env/scopes"/local_*.nix(N); do
          _n="${${_f:t:r}#local_}"
          if ! (( ${_scopes[(Ie)$_n]} )); then
            _scopes+=("$_n")
          fi
        done
        _describe 'scope name' _scopes
        ;;
      esac
    fi
    ;;
  pin)
    if (( CURRENT == 3 )); then
      local -a pin_cmds
      pin_cmds=(
        'set:pin nixpkgs to a specific revision'
        'remove:remove the nixpkgs pin'
        'show:show current pin'
        'help:show pin help'
      )
      _describe 'pin command' pin_cmds
    fi
    ;;
  profile)
    if (( CURRENT == 3 )); then
      local -a profile_cmds
      profile_cmds=(
        'doctor:check profile block health'
        'regenerate:regenerate profile blocks'
        'uninstall:remove profile blocks'
        'help:show profile help'
      )
      _describe 'profile command' profile_cmds
    fi
    ;;
  setup)
    local -a setup_flags
    setup_flags=(
      '--az:Azure CLI + azcopy'
      '--bun:Bun JavaScript/TypeScript runtime'
      '--conda:Miniforge'
      '--docker:Docker post-install check'
      '--gcloud:Google Cloud CLI'
      '--k8s-base:kubectl, kubelogin, k9s, kubecolor'
      '--k8s-dev:argo, cilium, flux, helm, hubble, kustomize, trivy'
      '--k8s-ext:minikube, k3d, kind'
      '--nodejs:Node.js'
      '--pwsh:PowerShell'
      '--python:uv + prek'
      '--rice:btop, cmatrix, cowsay, fastfetch'
      '--shell:fzf, eza, bat, ripgrep, yq'
      '--terraform:terraform, tflint'
      '--zsh:zsh plugins'
      '--all:enable all scopes'
      '--upgrade:upgrade all packages'
      '--allow-unfree:allow unfree packages'
      '--unattended:skip interactive steps'
      '--update-modules:update PowerShell modules'
      '--omp-theme:oh-my-posh theme name'
      '--starship-theme:starship theme name'
      '--remove:remove scopes'
      '--help:show help'
    )
    _describe 'setup flag' setup_flags
    ;;
  self)
    if (( CURRENT == 3 )); then
      local -a self_cmds
      self_cmds=(
        'update:update the source repository'
        'path:print the source repository path'
        'help:show self help'
      )
      _describe 'self command' self_cmds
    elif (( CURRENT >= 4 )) && [[ "${words[3]}" == "update" ]]; then
      local -a update_flags
      update_flags=('--force:force reset to origin')
      _describe 'update flag' update_flags
    fi
    ;;
  remove|uninstall)
    local -a _pkgs
    _pkgs=("${(@f)$(sed -n 's/^[[:space:]]*"\([^"]*\)".*/\1/p' "$HOME/.config/nix-env/packages.nix" 2>/dev/null)}")
    [[ -n "${_pkgs[*]}" ]] && _describe 'package' _pkgs
    ;;
  esac
}
compdef _nx nx
