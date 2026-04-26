#!/usr/bin/env bash
: '
# :single user
.assets/scripts/vim_setup.sh
# :global (system-wide)
.assets/scripts/vim_setup.sh global
'

# set script working directory to workspace folder
SCRIPT_ROOT=$(cd "$(dirname "${BASH_SOURCE[0]:-$0}")" && pwd)
pushd "$(cd "${SCRIPT_ROOT}/../../" && pwd)" >/dev/null || exit

# determine system id
SYS_ID=$(grep -oPm1 '^ID(_LIKE)?=.*?\K(alpine|arch|fedora|debian|ubuntu|opensuse)' /etc/os-release)

# *Initialize vim setting from .vimrc example.
if [[ "$1" = 'global' ]]; then
  sudo rm -fr ~/.vim ~/.vimrc /root/.vim /root/.vimrc /etc/vimrc.local /etc/vim/vimrc.local
  case $SYS_ID in
  fedora)
    sudo cp -f .assets/config/vim/.vimrc /etc/vimrc.local
    sudo dnf remove -y nano-default-editor nano && sudo dnf install -y vim-default-editor
    ;;
  debian | ubuntu)
    sudo cp -f .assets/config/vim/.vimrc /etc/vim//vimrc.local
    sudo update-alternatives --config editor
    ;;
  esac
else
  rm -fr ~/.vim ~/.vimrc
  cp -f .assets/config/vim/.vimrc ~
fi

# *set up git to use vim as editor
if command -v git >/dev/null; then
  git config --global core.editor "vim"
fi

# *set up gh-cli to use vim as editor
if command -v gh >/dev/null; then
  gh config set editor vim
fi
