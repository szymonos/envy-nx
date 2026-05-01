#region common aliases
# navigation
alias ..='cd ../'
alias ...='cd ../../'
alias .3='cd ../../../'
alias .4='cd ../../../../'
alias .5='cd ../../../../../'
alias .6='cd ../../../../../../'
alias cd..='cd ../'

# saved working directory
export SWD=$(pwd)
alias swd="echo $SWD"
alias cds="cd $SWD"

# sudo
alias sudo='sudo '
alias _='sudo'
alias please='sudo'

# file operations
alias cp='cp -iv'
alias mv='mv -iv'
alias mkdir='mkdir -pv'
alias md='mkdir -p'
alias rd='rmdir'

# tools
alias c='clear'
alias grep='grep -i --color=auto'
alias less='less -FRX'
alias nano='nano -W'
alias tree='tree -C'
alias vi='vim'
alias wget='wget -c'

# info / shell
alias path='printf "${PATH//:/\\n}\n"'
alias src='source ~/.bashrc'
alias fix_stty='stty sane'
alias fix_term='printf "\ec"'

# linux-specific
if [ -f /etc/os-release ]; then
  alias osr='cat /etc/os-release'
  alias systemctl='systemctl --no-pager'
  if grep -qEw 'ID="?alpine' /etc/os-release 2>/dev/null; then
    alias bsh='/usr/bin/env -i ash --noprofile --norc'
    alias ls='ls -h --color=auto --group-directories-first'
  else
    alias bsh='/usr/bin/env -i bash --noprofile --norc'
    alias ip='ip --color=auto'
    alias ls='ls -h --color=auto --group-directories-first --time-style=long-iso'
  fi
else
  alias bsh='/usr/bin/env -i bash --noprofile --norc'
fi
#endregion

#region dev tool aliases
_nb="$HOME/.nix-profile/bin"

if [ -x "$_nb/eza" ]; then
  alias eza='eza -g --color=auto --time-style=long-iso --group-directories-first --color-scale=all --git-repos'
  alias l='eza -1'
  alias lsa='eza -a'
  alias ll='eza -lah'
  alias lt='eza -Th'
  alias lta='eza -aTh --git-ignore'
  alias ltd='eza -DTh'
  alias ltad='eza -aDTh --git-ignore'
  alias llt='eza -lTh'
  alias llta='eza -laTh --git-ignore'
else
  alias l='ls -1'
  alias lsa='ls -a'
  alias ll='ls -lah'
fi

[ -x "$_nb/bat" ] && alias batp='bat -pP' || true
[ -x "$_nb/rg" ] && alias rg='rg --ignore-case' || true
[ -x "$_nb/fastfetch" ] && alias ff='fastfetch' || true
[ -x "$_nb/pwsh" ] && alias pwsh='pwsh -NoProfileLoadTime' && alias p='pwsh -NoProfileLoadTime' || true
[ -x "$_nb/kubectx" ] && alias kc='kubectx' || true
[ -x "$_nb/kubens" ] && alias kn='kubens' || true
[ -x "$_nb/kubecolor" ] && alias kubectl='kubecolor' || true

unset _nb
#endregion

#region nix package management wrapper (apt/brew-like UX)
if command -v nix &>/dev/null; then
  function nx() {
    if ! type nx_main &>/dev/null 2>&1; then
      local _nx_script _nx_dir
      _nx_dir="$(dirname "$(realpath "${BASH_SOURCE[0]}" 2>/dev/null || echo "$HOME/.config/shell/aliases_nix.sh")")"
      for _nx_script in \
        "$_nx_dir/../../.assets/lib/nx.sh" \
        "$HOME/.config/nix-env/nx.sh"; do
        if [ -f "$_nx_script" ]; then
          source "$_nx_script"
          break
        fi
      done
    fi
    nx_main "$@"
  }

fi
#endregion
