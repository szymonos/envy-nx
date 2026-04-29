# bash tab completions for the nx command
function _nx_completions() {
  local cur prev
  cur="${COMP_WORDS[COMP_CWORD]}"
  prev="${COMP_WORDS[COMP_CWORD - 1]}"

  if [ "$COMP_CWORD" -eq 1 ]; then
    while IFS= read -r line; do COMPREPLY+=("$line"); done < <(compgen -W "search install remove upgrade rollback pin list scope overlay profile setup self doctor prune gc version help" -- "$cur")
  elif [ "$COMP_CWORD" -eq 2 ] && [ "$prev" = "scope" ]; then
    while IFS= read -r line; do COMPREPLY+=("$line"); done < <(compgen -W "list show tree add edit remove" -- "$cur")
  elif [ "$COMP_CWORD" -eq 2 ] && [ "$prev" = "pin" ]; then
    while IFS= read -r line; do COMPREPLY+=("$line"); done < <(compgen -W "set remove show help" -- "$cur")
  elif [ "$COMP_CWORD" -eq 2 ] && [ "$prev" = "profile" ]; then
    while IFS= read -r line; do COMPREPLY+=("$line"); done < <(compgen -W "doctor regenerate uninstall help" -- "$cur")
  elif [ "$COMP_CWORD" -eq 2 ] && [ "$prev" = "self" ]; then
    while IFS= read -r line; do COMPREPLY+=("$line"); done < <(compgen -W "update path help" -- "$cur")
  elif [ "$COMP_CWORD" -ge 2 ] && [ "${COMP_WORDS[1]}" = "setup" ]; then
    while IFS= read -r line; do COMPREPLY+=("$line"); done < <(compgen -W "--az --bun --conda --docker --gcloud --k8s-base --k8s-dev --k8s-ext --nodejs --pwsh --python --rice --shell --terraform --zsh --all --upgrade --allow-unfree --unattended --update-modules --omp-theme --starship-theme --remove --help" -- "$cur")
  elif [ "$COMP_CWORD" -ge 3 ] && [ "${COMP_WORDS[1]}" = "self" ] && [ "${COMP_WORDS[2]}" = "update" ]; then
    while IFS= read -r line; do COMPREPLY+=("$line"); done < <(compgen -W "--force" -- "$cur")
  elif [ "$COMP_CWORD" -ge 3 ] && [ "${COMP_WORDS[1]}" = "scope" ] &&
    { [ "${COMP_WORDS[2]}" = "show" ] || [ "${COMP_WORDS[2]}" = "edit" ] || [ "${COMP_WORDS[2]}" = "remove" ] || [ "${COMP_WORDS[2]}" = "rm" ]; }; then
    local _scopes _env="$HOME/.config/nix-env"
    _scopes="$(sed -n '/scopes[[:space:]]*=[[:space:]]*\[/,/\]/{
      s/^[[:space:]]*"\([^"]*\)".*/\1/p
    }' "$_env/config.nix" 2>/dev/null | sed 's/^local_//')"
    local _f
    for _f in "$_env/scopes"/local_*.nix; do
      [ -f "$_f" ] || continue
      local _n
      _n="$(basename "$_f" .nix)"
      _n="${_n#local_}"
      echo "$_scopes" | grep -qx "$_n" 2>/dev/null || _scopes="${_scopes:+$_scopes
}$_n"
    done
    [ -n "$_scopes" ] && while IFS= read -r line; do COMPREPLY+=("$line"); done < <(compgen -W "$_scopes" -- "$cur")
  elif [ "$COMP_CWORD" -ge 2 ] && { [ "${COMP_WORDS[1]}" = "remove" ] || [ "${COMP_WORDS[1]}" = "uninstall" ]; }; then
    local _pkgs
    _pkgs="$(sed -n 's/^[[:space:]]*"\([^"]*\)".*/\1/p' "$HOME/.config/nix-env/packages.nix" 2>/dev/null)"
    [ -n "$_pkgs" ] && while IFS= read -r line; do COMPREPLY+=("$line"); done < <(compgen -W "$_pkgs" -- "$cur")
  fi
}
complete -F _nx_completions nx
