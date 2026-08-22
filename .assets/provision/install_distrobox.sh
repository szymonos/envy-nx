#!/usr/bin/env bash
: '
sudo .assets/provision/install_distrobox.sh $(id -un)
'
set -euo pipefail

if [ $EUID -ne 0 ]; then
  printf '\e[31;1mRun the script as root.\e[0m\n' >&2
  exit 1
fi

# determine system id
SYS_ID="$(sed -En '/^ID.*(alpine|arch|fedora|debian|ubuntu|opensuse).*/{s//\1/;p;q}' /etc/os-release)"
# check if package installed already using package manager
APP='distrobox'
installed=false
case $SYS_ID in
alpine)
  apk -e info $APP &>/dev/null && installed=true || installed=false
  ;;
arch)
  pacman -Qqe $APP &>/dev/null && installed=true || installed=false
  ;;
fedora | opensuse)
  rpm -q $APP &>/dev/null && installed=true || installed=false
  ;;
debian | ubuntu)
  dpkg -s $APP &>/dev/null && installed=true || installed=false
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
if [ "$installed" = true ]; then
  printf "\e[32m$APP is already installed\e[0m\n"
  exit 0
else
  printf "\e[92minstalling \e[1m$APP\e[0m\n"
fi

case $SYS_ID in
alpine)
  apk add --no-cache $APP
  ;;
arch)
  if pacman -Qqe paru &>/dev/null; then
    user=${1:-$(id -un 1000 2>/dev/null || true)}
    if ! sudo -u $user true 2>/dev/null; then
      if [ -n "$user" ]; then
        printf "\e[31;1mUser does not exist ($user).\e[0m\n"
      else
        printf "\e[31;1mUser ID 1000 not found.\e[0m\n"
      fi
      exit 1
    fi
    sudo -u $user paru -Sy --needed --noconfirm $APP
  else
    printf '\e[33;1mWarning: paru not installed.\e[0m\n'
  fi
  ;;
fedora)
  dnf install -y $APP
  ;;
debian | ubuntu)
  export DEBIAN_FRONTEND=noninteractive
  apt-get update
  if apt-cache show $APP >/dev/null 2>&1; then
    # packaged in Debian 12+ and Ubuntu 23.04+ - no third-party source needed
    apt-get install -y $APP
  elif [ "$SYS_ID" = 'ubuntu' ] && command -v add-apt-repository >/dev/null 2>&1; then
    # Ubuntu-only: the PPA publishes no Debian suites, so adding it on Debian
    # writes a 404ing source that breaks every later `apt-get update`.
    # `command -v` guards software-properties-common, absent on minimal images.
    # add-apt-repository writes the source before it can fail, so it stays
    # inside the cleanup guard.
    if ! (add-apt-repository -y ppa:michel-slm/distrobox &&
      apt-get update && apt-get install -y $APP); then
      # drop the source we just added so the box is left usable
      add-apt-repository -y -r ppa:michel-slm/distrobox || true
      apt-get update || true
      printf '\e[31;1mFailed to install %s from the PPA; the added source was removed.\e[0m\n' "$APP" >&2
      exit 1
    fi
  else
    printf '\e[31;1m%s is not available in the configured apt sources.\e[0m\n' "$APP" >&2
    exit 1
  fi
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
