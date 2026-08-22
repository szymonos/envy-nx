#!/usr/bin/env bash
: '
sudo .assets/provision/install_docker.sh $(id -un)
'
set -euo pipefail

if [ $EUID -ne 0 ]; then
  printf '\e[31;1mRun the script as root.\e[0m\n' >&2
  exit 1
fi

# function to add user to docker group
add_docker_user() {
  local user="$1"
  if ! sudo -u "$user" true 2>/dev/null; then
    if [ -n "$user" ]; then
      printf "\e[31;1mUser does not exist ($user).\e[0m\n"
    else
      printf "\e[31;1mUser ID 1000 not found.\e[0m\n"
    fi
    return 1
  fi
  if grep -q "^docker:.*\b$user\b" /etc/group; then
    printf "\e[34;1m::info:: $user is already in docker group\e[0m\n"
  else
    usermod -aG docker "$user" && printf "\e[34;1m::info:: added $user to docker group\e[0m\n" || {
      printf "\e[31;1m::error:: failed to add $user to docker group\e[0m\n"
      return 1
    }
  fi
  return 0
}

# function to enable docker and containerd services
enable_docker_service() {
  local docker_service_failed=false
  local containerd_service_failed=false

  if systemctl is-active --quiet systemd-sysctl.service 2>/dev/null; then
    systemctl is-active --quiet docker.service || {
      systemctl enable --now docker.service || docker_service_failed=true
    }
    systemctl is-active --quiet containerd.service || {
      systemctl enable --now containerd.service || containerd_service_failed=true
    }
    if [ "$docker_service_failed" = true ] || [ "$containerd_service_failed" = true ]; then
      printf "\e[31;1m::error:: failed to start docker or containerd service\e[0m\n"
      return 1
    else
      printf "\e[34;1m::info:: docker and containerd services running\e[0m\n"
    fi
  else
    # Non-fatal: containers, Coder workspaces and CI runners are supported
    # targets that have no systemd (install_nix.sh probes for the same case).
    # The packages are installed and the user is in the docker group; only
    # service activation is unavailable, which the init system owns.
    printf '\e[33;1m::warning:: systemd is not running, skipping service activation\e[0m\n'
    return 0
  fi
  return 0
}

# set user variable
user=${1:-$(id -un 1000 2>/dev/null || true)}

# determine system id
SYS_ID="$(sed -En '/^ID.*(alpine|arch|fedora|debian|ubuntu|opensuse).*/{s//\1/;p;q}' /etc/os-release)"
# check if package installed already using package manager
case $SYS_ID in
alpine)
  exit 0
  ;;
arch)
  pacman -Qqe docker &>/dev/null && installed=true || installed=false
  ;;
fedora)
  rpm -q docker-ce &>/dev/null && installed=true || installed=false
  ;;
debian | ubuntu)
  dpkg -s docker-ce &>/dev/null && installed=true || installed=false
  ;;
opensuse)
  rpm -q docker &>/dev/null && installed=true || installed=false
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
  # Group membership first: it only needs usermod and must not be gated on
  # service activation. `set -e` still propagates a genuine failure of either.
  add_docker_user "$user"
  enable_docker_service
  exit 0
else
  printf "\e[92minstalling \e[1mdocker\e[0m\n"
fi

# install docker
case $SYS_ID in
arch)
  pacman -Sy --needed --noconfirm docker docker-compose
  ;;
debian)
  export DEBIAN_FRONTEND=noninteractive
  if dpkg -s docker &>/dev/null; then
    apt-get remove -y docker docker-engine docker.io containerd runc
  fi
  if [ ! -f /etc/apt/sources.list.d/docker.sources ]; then
    # add Docker's official GPG key
    install -m 0755 -d /etc/apt/keyrings
    curl --proto '=https' --proto-redir '=https' --tlsv1.2 -fsSL \
      https://download.docker.com/linux/debian/gpg -o /etc/apt/keyrings/docker.asc
    chmod a+r /etc/apt/keyrings/docker.asc
    # add the repository to Apt sources
    cat <<EOF >/etc/apt/sources.list.d/docker.sources
Types: deb
URIs: https://download.docker.com/linux/debian
Suites: $(. /etc/os-release && echo "$VERSION_CODENAME")
Components: stable
Signed-By: /etc/apt/keyrings/docker.asc
EOF
  fi
  apt-get update && apt-get install -y docker-ce docker-ce-cli containerd.io docker-buildx-plugin docker-compose-plugin
  ;;
fedora)
  if rpm -q docker &>/dev/null; then
    dnf remove -y docker docker-client docker-client-latest docker-common docker-latest docker-latest-logrotate docker-logrotate docker-selinux docker-engine-selinux docker-engine
  fi
  if [ ! -f /etc/yum.repos.d/docker-ce.repo ]; then
    if [ "$(readlink "$(which dnf)")" = 'dnf5' ]; then
      dnf config-manager addrepo --from-repofile https://download.docker.com/linux/fedora/docker-ce.repo
    else
      dnf config-manager --add-repo https://download.docker.com/linux/rhel/docker-ce.repo
    fi
  fi
  dnf install -y docker-ce docker-ce-cli containerd.io docker-buildx-plugin docker-compose-plugin
  ;;
ubuntu)
  export DEBIAN_FRONTEND=noninteractive
  if dpkg -s docker &>/dev/null; then
    apt-get remove -y docker docker-engine docker.io containerd runc
  fi
  if [ ! -f /etc/apt/sources.list.d/docker.sources ]; then
    # add Docker's official GPG key
    install -m 0755 -d /etc/apt/keyrings
    curl --proto '=https' --proto-redir '=https' --tlsv1.2 -fsSL \
      https://download.docker.com/linux/ubuntu/gpg -o /etc/apt/keyrings/docker.asc
    chmod a+r /etc/apt/keyrings/docker.asc
    # add the repository to Apt sources
    cat <<EOF >/etc/apt/sources.list.d/docker.sources
Types: deb
URIs: https://download.docker.com/linux/ubuntu
Suites: $(. /etc/os-release && echo "${UBUNTU_CODENAME:-$VERSION_CODENAME}")
Components: stable
Signed-By: /etc/apt/keyrings/docker.asc
EOF
  fi
  apt-get update && apt-get install -y docker-ce docker-ce-cli containerd.io docker-buildx-plugin docker-compose-plugin
  ;;
opensuse)
  zypper --non-interactive in -y docker containerd docker-compose
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

# add user to docker group, then start docker services (see the already-installed
# branch above - group membership must not depend on systemd being present)
add_docker_user "$user"
enable_docker_service
