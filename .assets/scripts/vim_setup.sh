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

# Purge the existing system-wide vim configuration. Call this only from an arm
# that goes on to reinstall it - never before the case. alpine, arch and
# opensuse have no arm here, so purging unconditionally would delete the user's
# and root's vim config on those distros and install nothing.
_vim_purge_global() {
  sudo rm -fr ~/.vim ~/.vimrc /root/.vim /root/.vimrc /etc/vimrc.local /etc/vim/vimrc.local
}

# *Initialize vim setting from .vimrc example.
if [[ "$1" = 'global' ]]; then
  case $SYS_ID in
  fedora)
    _vim_purge_global
    sudo cp -f .assets/config/vim/.vimrc /etc/vimrc.local
    sudo dnf remove -y nano-default-editor nano && sudo dnf install -y vim-default-editor
    ;;
  debian | ubuntu)
    _vim_purge_global
    sudo cp -f .assets/config/vim/.vimrc /etc/vim//vimrc.local
    sudo update-alternatives --config editor
    ;;
  *)
    # Same shape as the house arm in .assets/provision/install_*.sh, but the
    # supported list is narrower: `global` mode only knows how to place the
    # vimrc on fedora/debian/ubuntu, so alpine/arch/opensuse reach this arm
    # with a successfully detected SYS_ID rather than an empty one.
    raw_id="$(sed -n 's/^ID=//p' /etc/os-release 2>/dev/null | tr -d '"' | head -1)" || true
    printf '\e[31;1m%s: unsupported distribution - detected ID "%s".\e[0m\n' "${0##*/}" "${raw_id:-unknown}" >&2
    printf '\e[31;1mglobal mode supports: fedora, debian, ubuntu.\e[0m\n' >&2
    exit 1
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
