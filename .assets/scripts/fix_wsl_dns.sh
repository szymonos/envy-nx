#!/usr/bin/env bash
: '
# :fix DNS resolution on Debian/Ubuntu WSL2 (systemd-resolved, IPv6 disable, resolv.conf options)
.assets/scripts/fix_wsl_dns.sh
# :revert all DNS fixes and restore WSL-managed DNS
.assets/scripts/fix_wsl_dns.sh revert
# :show current DNS stack status (resolved, nsswitch, IPv6, port 53, timing test)
.assets/scripts/fix_wsl_dns.sh status
'
# Fix flaky DNS resolution on Debian/Ubuntu WSL2 distros.
#
# On Fedora WSL2, systemd-resolved starts early enough to grab port 53 before
# the WSL2 kernel DNS proxy, so it caches queries and absorbs dropped packets.
# On Debian/Ubuntu, the WSL2 proxy wins the race for 127.0.0.53:53, leaving
# systemd-resolved in a degraded state. Without a local cache, glibc talks
# directly to the flaky WSL2 proxy, causing 10-18s timeouts and intermittent
# "Could not resolve host" errors.
#
# This script applies four fixes that together match Fedora behavior:
#   1. Install systemd-resolved + libnss-resolve (D-Bus DNS path)
#   2. Configure resolved with DNSStubListener=no (yield port 53 to WSL2)
#   3. Disable IPv6 (WSL2 NAT proxy mishandles AAAA queries)
#   4. Patch resolv.conf with single-request-reopen (prevent A+AAAA socket
#      multiplexing that the WSL2 proxy drops)
set -euo pipefail

# region constants
readonly RESOLVED_DROP_IN=/etc/systemd/resolved.conf.d/wsl.conf
readonly SYSCTL_IPV6=/etc/sysctl.d/99-disable-ipv6.conf
readonly NSSWITCH=/etc/nsswitch.conf
readonly RESOLV=/etc/resolv.conf
readonly HOSTS_LINE='files myhostname resolve [!UNAVAIL=return] dns'
# endregion

# region helpers
print_info() { printf '\e[96m%s\e[0m\n' "$1"; }
print_ok() { printf '\e[32m%s\e[0m\n' "$1"; }
print_warn() { printf '\e[33m%s\e[0m\n' "$1"; }
print_err() { printf '\e[31;1m%s\e[0m\n' "$1" >&2; }

check_wsl() {
  if [ ! -f /proc/sys/fs/binfmt_misc/WSLInterop ] && [ -z "${WSL_DISTRO_NAME:-}" ]; then
    print_err "This script is intended for WSL2 only."
    exit 1
  fi
}

check_debian_family() {
  local sys_id
  sys_id="$(sed -En '/^ID.*(debian|ubuntu).*/{s//\1/;p;q}' /etc/os-release 2>/dev/null || true)"
  if [ -z "$sys_id" ]; then
    print_err "This script targets Debian/Ubuntu. Detected: $(. /etc/os-release && echo "$ID")"
    exit 1
  fi
}

parse_resolv_conf() {
  nameserver=""
  if [ -f "$RESOLV" ]; then
    nameserver="$(grep -m1 '^nameserver' "$RESOLV" | awk '{print $2}')" || true
  fi
  nameserver="${nameserver:-10.255.255.254}"
}

unlock_resolv_conf() {
  if lsattr "$RESOLV" 2>/dev/null | grep -q 'i'; then
    sudo chattr -i "$RESOLV"
  fi
}
# endregion

# region status
cmd_status() {
  printf '\e[95m--- DNS configuration status ---\e[0m\n'

  printf '\n\e[1mresolv.conf:\e[0m\n'
  cat "$RESOLV" 2>/dev/null || print_warn "  not found"
  if lsattr "$RESOLV" 2>/dev/null | grep -q 'i'; then
    print_ok "  (immutable flag set)"
  else
    print_warn "  (immutable flag NOT set)"
  fi

  printf '\n\e[1msystemd-resolved:\e[0m\n'
  if systemctl is-active --quiet systemd-resolved 2>/dev/null; then
    print_ok "  active"
    resolvectl status 2>&1 | sed 's/^/  /'
  else
    print_warn "  inactive"
  fi

  printf '\n\e[1mnsswitch.conf hosts:\e[0m\n'
  printf '  %s\n' "$(grep '^hosts:' "$NSSWITCH" 2>/dev/null || echo 'not found')"

  printf '\n\e[1mIPv6:\e[0m\n'
  local ipv6_val
  ipv6_val="$(sysctl -n net.ipv6.conf.all.disable_ipv6 2>/dev/null || echo '?')"
  if [ "$ipv6_val" = "1" ]; then
    print_ok "  disabled (net.ipv6.conf.all.disable_ipv6 = 1)"
  else
    print_warn "  enabled (net.ipv6.conf.all.disable_ipv6 = $ipv6_val)"
  fi

  printf '\n\e[1mport 53 listeners:\e[0m\n'
  ss -tulnp 2>/dev/null | grep '[: ]53 ' | sed 's/^/  /' || print_warn "  none"

  printf '\n\e[1mDNS test:\e[0m\n'
  local result
  if result="$(curl -w 'dns:%{time_namelookup}s total:%{time_total}s' -s -o /dev/null https://google.com 2>&1)"; then
    print_ok "  google.com -> $result"
  else
    print_err "  google.com -> FAILED"
  fi
}
# endregion

# region revert
cmd_revert() {
  print_info "Reverting DNS fixes..."

  # remove resolved drop-in
  if [ -f "$RESOLVED_DROP_IN" ]; then
    sudo rm -f "$RESOLVED_DROP_IN"
    print_ok "removed $RESOLVED_DROP_IN"
  fi

  # disable systemd-resolved (WSL auto-generates resolv.conf without it)
  if systemctl is-enabled --quiet systemd-resolved 2>/dev/null; then
    sudo systemctl disable --now systemd-resolved
    print_ok "disabled systemd-resolved"
  fi

  # remove IPv6 sysctl
  if [ -f "$SYSCTL_IPV6" ]; then
    sudo rm -f "$SYSCTL_IPV6"
    sudo sysctl -w net.ipv6.conf.all.disable_ipv6=0 net.ipv6.conf.default.disable_ipv6=0 >/dev/null
    print_ok "re-enabled IPv6"
  fi

  # restore nsswitch to default (remove resolve module)
  if grep -q 'resolve' "$NSSWITCH" 2>/dev/null; then
    sudo sed -i 's/^hosts:.*/hosts:          files dns/' "$NSSWITCH"
    print_ok "restored nsswitch.conf to default"
  fi

  # unlock and let WSL regenerate resolv.conf
  unlock_resolv_conf
  sudo rm -f "$RESOLV"
  print_ok "removed resolv.conf (WSL will regenerate on next boot)"

  # ensure WSL generates resolv.conf
  if grep -q 'generateResolvConf.*false' /etc/wsl.conf 2>/dev/null; then
    sudo sed -i 's/generateResolvConf.*/generateResolvConf = true/' /etc/wsl.conf
    print_ok "set generateResolvConf = true in wsl.conf"
  fi

  print_info "Revert complete. Restart the WSL distro for full effect."
}
# endregion

# region apply
cmd_apply() {
  print_info "Fixing DNS resolution for WSL2..."

  # capture current DNS config before making changes
  parse_resolv_conf
  print_info "detected nameserver: $nameserver"

  # 1. install systemd-resolved + NSS module
  local pkgs_needed=()
  dpkg -l systemd-resolved >/dev/null 2>&1 || pkgs_needed+=(systemd-resolved)
  dpkg -l libnss-resolve >/dev/null 2>&1 || pkgs_needed+=(libnss-resolve)
  if [ ${#pkgs_needed[@]} -gt 0 ]; then
    print_info "installing ${pkgs_needed[*]}..."
    sudo apt-get update -qq
    sudo apt-get install -y -qq "${pkgs_needed[@]}"
    print_ok "installed ${pkgs_needed[*]}"
  else
    print_ok "systemd-resolved and libnss-resolve already installed"
  fi

  # 2. configure systemd-resolved for WSL2
  #    DNSStubListener=no: WSL2's kernel DNS proxy already occupies 127.0.0.53:53
  #    serve via D-Bus only (same as Fedora's effective behavior)
  sudo mkdir -p /etc/systemd/resolved.conf.d
  sudo tee "$RESOLVED_DROP_IN" >/dev/null <<EOF
[Resolve]
DNSStubListener=no
DNS=$nameserver
FallbackDNS=
LLMNR=no
EOF
  print_ok "configured systemd-resolved (D-Bus only, upstream=$nameserver)"

  # 3. update nsswitch.conf to use resolve module
  local current_hosts
  current_hosts="$(grep '^hosts:' "$NSSWITCH" | sed 's/^hosts:[[:space:]]*//')" || true
  if [ "$current_hosts" != "$HOSTS_LINE" ]; then
    sudo sed -i "s/^hosts:.*/hosts:          $HOSTS_LINE/" "$NSSWITCH"
    print_ok "updated nsswitch.conf hosts line"
  else
    print_ok "nsswitch.conf already correct"
  fi

  # 4. disable IPv6 (WSL2's NAT proxy mishandles AAAA queries)
  sudo tee "$SYSCTL_IPV6" >/dev/null <<'EOF'
net.ipv6.conf.all.disable_ipv6 = 1
net.ipv6.conf.default.disable_ipv6 = 1
EOF
  sudo sysctl -p "$SYSCTL_IPV6" >/dev/null
  print_ok "disabled IPv6"

  # 5. stop WSL from regenerating resolv.conf on boot
  if grep -q 'generateResolvConf' /etc/wsl.conf 2>/dev/null; then
    sudo sed -i 's/generateResolvConf.*/generateResolvConf = false/' /etc/wsl.conf
  elif grep -q '^\[network\]' /etc/wsl.conf 2>/dev/null; then
    sudo sed -i '/^\[network\]/a generateResolvConf = false' /etc/wsl.conf
  else
    printf '\n[network]\ngenerateResolvConf = false\n' | sudo tee -a /etc/wsl.conf >/dev/null
  fi
  print_ok "set generateResolvConf = false in wsl.conf"

  # 6. patch resolv.conf: ensure glibc workaround options are present
  #    single-request-reopen: prevents A+AAAA query multiplexing on one socket
  #    (WSL2's DNS proxy drops the second query when both share a socket)
  unlock_resolv_conf
  if [ ! -f "$RESOLV" ] || ! grep -q '^nameserver' "$RESOLV" 2>/dev/null; then
    echo "nameserver $nameserver" | sudo tee "$RESOLV" >/dev/null
  fi
  local options_line="options single-request-reopen timeout:2 attempts:2"
  if grep -q '^options' "$RESOLV" 2>/dev/null; then
    sudo sed -i "s/^options.*/$options_line/" "$RESOLV"
  else
    echo "$options_line" | sudo tee -a "$RESOLV" >/dev/null
  fi
  sudo chattr +i "$RESOLV"
  print_ok "patched resolv.conf options (immutable)"

  # 7. enable and start systemd-resolved
  sudo systemctl enable --now systemd-resolved
  print_ok "systemd-resolved enabled"

  # 8. verify
  printf '\n'
  print_info "verifying DNS resolution..."
  local result
  if result="$(curl -w 'dns:%{time_namelookup}s total:%{time_total}s' -s -o /dev/null https://google.com 2>&1)"; then
    print_ok "google.com -> $result"
  else
    print_warn "first attempt slow/failed, retrying..."
    if result="$(curl -w 'dns:%{time_namelookup}s total:%{time_total}s' -s -o /dev/null https://google.com 2>&1)"; then
      print_ok "google.com -> $result"
    else
      print_err "DNS resolution still failing. Run '.assets/scripts/fix_wsl_dns.sh status' to diagnose."
      exit 1
    fi
  fi

  printf '\n'
  print_ok "DNS fix applied successfully."
}
# endregion

# -- main ----------------------------------------------------------------------
check_wsl
check_debian_family

case "${1:-}" in
revert) cmd_revert ;;
status) cmd_status ;;
*) cmd_apply ;;
esac
