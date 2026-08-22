#!/usr/bin/env sh
: '
sudo .assets/provision/upgrade_system.sh
'
set -eu

if [ "$(id -u)" -ne 0 ]; then
  printf '\e[31;1mRun the script as root.\e[0m\n' >&2
  exit 1
fi

SYS_ID="$(sed -En '/^ID.*(alpine|arch|fedora|debian|ubuntu|opensuse).*/{s//\1/;p;q}' /etc/os-release)"
case $SYS_ID in
alpine)
  apk upgrade --available
  ;;
arch)
  # ArchWSL fix for WSL2. Default-expand: `set -eu` is on, the variable is
  # unset on native Arch, and sudo scrubs it even on ArchWSL (it is not in
  # sudoers' default env_keep), so a bare read aborts the whole upgrade.
  if [ -n "${WSL_DISTRO_NAME:-}" ]; then
    sed -i '/\bfakeroot\b/d' /etc/pacman.conf
    pacman -R --noconfirm fakeroot-tcp 2>/dev/null || true
  fi
  pacman -Sy --needed --noconfirm archlinux-keyring 2>/dev/null
  pacman -Syu --noconfirm
  ;;
fedora)
  dnf upgrade -y
  ;;
debian | ubuntu)
  export DEBIAN_FRONTEND=noninteractive
  apt-get update -qq && apt-get dist-upgrade -qqy --allow-downgrades --allow-remove-essential --allow-change-held-packages
  ;;
opensuse)
  zypper --gpg-auto-import-keys refresh && zypper --non-interactive dup -y
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
