#!/usr/bin/env bash
: '
sudo .assets/check/check_ssl.sh
'

# install curl if not available
if ! command -v curl >/dev/null 2>&1; then
  printf '\e[3minstalling curl for SSL check...\e[0m\n' >&2
  SYS_ID="$(sed -En '/^ID.*(alpine|arch|fedora|debian|ubuntu|opensuse).*/{s//\1/;p;q}' /etc/os-release)"
  # No `*)` arm on purpose: an unknown distro simply gets no curl, and the
  # probe ladder below degrades to wget, then python3, then `echo unknown`.
  # The consumer (wsl/wsl_phases.ps1) parses that printed word, so a hard exit
  # here would turn graceful degradation into a failed WSL setup.
  case $SYS_ID in # distro-case-ok: falls through to the wget/python3 probe ladder below
  alpine)
    apk add --no-cache --no-check-certificate curl >/dev/null 2>&1
    ;;
  arch)
    pacman -Sy --needed --noconfirm curl >/dev/null 2>&1
    ;;
  fedora)
    dnf install -y --setopt=sslverify=0 curl >/dev/null 2>&1
    ;;
  debian | ubuntu)
    apt-get update >/dev/null 2>&1 && apt-get install -y curl >/dev/null 2>&1
    ;;
  opensuse)
    zypper --non-interactive in -y curl >/dev/null 2>&1
    ;;
  esac
fi

# check SSL connectivity
: "${NIX_ENV_TLS_PROBE_URL:=https://www.google.com}"
# The two probes below deliberately carry no --proto/--tlsv1.2: they answer
# "can this box reach the internet at all", NIX_ENV_TLS_PROBE_URL is
# user-overridable (possibly http://), and the caller treats any non-`true`
# answer as a connectivity problem rather than a protocol one.
if command -v curl >/dev/null 2>&1; then
  curl -sS "$NIX_ENV_TLS_PROBE_URL" >/dev/null 2>&1 && echo true || echo false # tls-probe-ok: connectivity probe
elif command -v wget >/dev/null 2>&1; then
  wget -q --spider "$NIX_ENV_TLS_PROBE_URL" 2>&1 && echo true || echo false # tls-probe-ok: connectivity probe
elif command -v python3 >/dev/null 2>&1; then
  python3 -c "import urllib.request; urllib.request.urlopen('$NIX_ENV_TLS_PROBE_URL')" 2>/dev/null && echo true || echo false
else
  echo unknown
fi
