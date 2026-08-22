#!/usr/bin/env bash
: '
sudo .assets/provision/install_podman.sh
'
set -euo pipefail

if [ $EUID -ne 0 ]; then
  printf '\e[31;1mRun the script as root.\e[0m\n' >&2
  exit 1
fi

# determine system id
SYS_ID="$(sed -En '/^ID.*(alpine|arch|fedora|debian|ubuntu|opensuse).*/{s//\1/;p;q}' /etc/os-release)"
# check if package installed already using package manager
APP='podman'
case $SYS_ID in
alpine)
  apk -e info $APP &>/dev/null && exit 0 || true
  ;;
arch)
  pacman -Qqe $APP &>/dev/null && exit 0 || true
  ;;
fedora | opensuse)
  rpm -q $APP &>/dev/null && exit 0 || true
  ;;
debian | ubuntu)
  dpkg -s $APP &>/dev/null && exit 0 || true
  ;;
*)
  # The caller (linux_setup.sh) has no ERR trap and its EXIT trap prints
  # nothing, so this message is all the user gets - spell out the diagnosis.
  # SYS_ID is empty by construction here (the arm only fires when the detection
  # sed matched nothing), so read the raw ID= field to name the actual distro.
  raw_id="$(sed -n 's/^ID=//p' /etc/os-release 2>/dev/null | tr -d '"' | head -1)" || true
  printf '\e[31;1m%s: unsupported distribution - detected ID "%s".\e[0m\n' "${0##*/}" "${raw_id:-unknown}" >&2
  printf '\e[31;1mSupported: alpine, arch, fedora, debian, ubuntu, opensuse.\e[0m\n' >&2
  exit 1
  ;;
esac

printf "\e[92minstalling \e[1m$APP\e[0m\n"
case $SYS_ID in
alpine)
  apk add --no-cache $APP
  ;;
arch)
  pacman -Sy --noconfirm $APP shadow
  ;;
fedora)
  dnf install -y $APP
  # fix shadow-utils
  rpm -V shadow-utils >/dev/null || dnf reinstall -y shadow-utils
  ;;
debian | ubuntu)
  export DEBIAN_FRONTEND=noninteractive
  apt-get update && apt-get install -y $APP
  ;;
opensuse)
  zypper --non-interactive in -y $APP
  ;;
*)
  # The caller (linux_setup.sh) has no ERR trap and its EXIT trap prints
  # nothing, so this message is all the user gets - spell out the diagnosis.
  # SYS_ID is empty by construction here (the arm only fires when the detection
  # sed matched nothing), so read the raw ID= field to name the actual distro.
  raw_id="$(sed -n 's/^ID=//p' /etc/os-release 2>/dev/null | tr -d '"' | head -1)" || true
  printf '\e[31;1m%s: unsupported distribution - detected ID "%s".\e[0m\n' "${0##*/}" "${raw_id:-unknown}" >&2
  printf '\e[31;1mSupported: alpine, arch, fedora, debian, ubuntu, opensuse.\e[0m\n' >&2
  exit 1
  ;;
esac
