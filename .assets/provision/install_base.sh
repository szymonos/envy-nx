#!/usr/bin/env sh
: '
sudo .assets/provision/install_base.sh
Install system-wide base packages that nix cannot or should not replace.
Packages managed by nix (git, jq, fd, ripgrep, etc.) are NOT included here.
'
set -eu

if [ "$(id -u)" -ne 0 ]; then
  printf '\e[31;1mRun the script as root.\e[0m\n' >&2
  exit 1
fi

# skip on macOS - Xcode Command Line Tools provide these
[ "$(uname -s)" = "Darwin" ] && exit 0

SYS_ID="$(sed -En '/^ID.*(alpine|arch|fedora|debian|ubuntu|opensuse).*/{s//\1/;p;q}' /etc/os-release)"

printf "\e[92minstalling \e[1msystem base packages\e[0m\n" >&2
case ${SYS_ID:-} in
alpine)
  apk update 2>/dev/null || true
  apk add --no-cache bash build-base ca-certificates curl iputils openssh-client sudo tar vim
  ;;
arch)
  pacman-key --init
  pacman -Sy --needed --noconfirm --color=auto archlinux-keyring
  pacman -S --needed --noconfirm --color=auto base-devel curl openssh sudo tar vim
  ;;
fedora)
  dnf makecache -q 2>/dev/null || true
  rpm -q patch >/dev/null 2>&1 || dnf group install -y development-tools 2>/dev/null || true
  dnf install -y -q curl iputils sudo tar vim
  ;;
debian | ubuntu)
  export DEBIAN_FRONTEND=noninteractive
  apt-get update -qq
  apt-get install -y -qq build-essential ca-certificates curl gnupg iputils-tracepath sudo tar vim
  ;;
opensuse)
  zypper refresh 2>/dev/null || true
  rpm -q patch >/dev/null 2>&1 || zypper --non-interactive --no-refresh in -yt pattern devel_basis 2>/dev/null || true
  zypper --non-interactive --no-refresh in -y curl sudo tar vim
  ;;
*)
  printf '\e[33mUnsupported distro, skipping system base install.\e[0m\n' >&2
  ;;
esac
