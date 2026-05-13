: '
. .assets/config/shell_cfg/functions.sh
'

# *Function to display system information in a user-friendly format
function sysinfo() {
  # dot-source os-release file
  . /etc/os-release
  # get cpu info
  cpu_name="$(sed -En '/^model name[[:space:]]*: (.+)/{
    s//\1/;p;q
  }' /proc/cpuinfo)"
  cpu_cores="$(sed -En '/^cpu cores[[:space:]]*: ([0-9]+)/{
    s//\1/;p;q
  }' /proc/cpuinfo)"
  # calculate memory usage
  local mem_total mem_available
  read -r mem_total mem_available < <(awk -F ':|kB' \
    '/MemTotal:/ {t=$2} /MemAvailable:/ {a=$2} \
    END {gsub(/[[:space:]]/, "", t); gsub(/[[:space:]]/, "", a); print t, a}' /proc/meminfo)
  mem_used=$((mem_total - mem_available))
  mem_perc=$(awk '{printf "%.0f", $1 * $2 / $3}' <<<"$mem_used 100 $mem_total")
  mem_used=$(awk '{printf "%.2f", $1 / $2 / $3}' <<<"$mem_used 1024 1024")
  mem_total=$(awk '{printf "%.2f", $1 / $2 / $3}' <<<"$mem_total 1024 1024")

  # build system properties string
  SYS_PROP="\n\e[1;32mOS         :\e[1;37m $NAME $([ -n "$BUILD_ID" ] && printf "$BUILD_ID" || [ -n "$VERSION" ] && printf "$VERSION" || printf "$VERSION_ID") $(uname -m)\e[0m"
  SYS_PROP+="\n\e[1;32mKernel     :\e[0m $(uname -r)"
  SYS_PROP+="\n\e[1;32mUptime     :\e[0m $(uptime -p | sed 's/^up //')"
  [ -n "$WSL_DISTRO_NAME" ] && SYS_PROP+="\n\e[1;32mOS Host    :\e[0m Windows Subsystem for Linux" || true
  [ -n "$WSL_DISTRO_NAME" ] && SYS_PROP+="\n\e[1;32mWSL Distro :\e[0m $WSL_DISTRO_NAME" || true
  [ -n "$CONTAINER_ID" ] && SYS_PROP+="\n\e[1;32mDistroBox  :\e[0m $CONTAINER_ID" || true
  [ -n "$TERM_PROGRAM" ] && SYS_PROP+="\n\e[1;32mTerminal   :\e[0m $TERM_PROGRAM" || true
  type bash &>/dev/null && SYS_PROP+="\n\e[1;32mShell      :\e[0m $(bash --version | head -n1 | sed 's/ (.*//')" || true
  SYS_PROP+="\n\e[1;32mCPU        :\e[0m $cpu_name ($cpu_cores)"
  SYS_PROP+="\n\e[1;32mMemory     :\e[0m ${mem_used} GiB / ${mem_total} GiB (${mem_perc} %%)"
  [ -n "$LANG" ] && SYS_PROP+="\n\e[1;32mLocale     :\e[0m $LANG" || true

  # print user@host header
  printf "\e[1;34m$(id -un)\e[0m@\e[1;34m$([ -n "$HOSTNAME" ] && printf "$HOSTNAME" || printf "$NAME")\e[0m\n"
  USER_HOST="$(id -un)@$([ -n "$HOSTNAME" ] && printf "$HOSTNAME" || printf "$NAME")"
  printf '%0.s-' $(seq 1 ${#USER_HOST})
  # print system properties
  printf "$SYS_PROP\n"
}
# set alias
alias gsi='sysinfo'

# *Function for fixing Python SSL certificate issues by adding custom certificates to certifi's cacert.pem
# Usage: fixcertpy [path ...]
#   If paths are provided, patches only those cacert.pem files.
#   If no paths are given, auto-discovers Python certifi bundles (venv, pip).
function fixcertpy() {
  # openssl is always needed for serial/fingerprint extraction
  type openssl &>/dev/null || return 1

  # load custom certificates into in-memory PEM array
  local cert_pems=()
  local CERT_BUNDLE="$HOME/.config/certs/ca-custom.crt"
  if [ -f "$CERT_BUNDLE" ]; then
    # parse individual PEM certs from bundle into array
    local current_pem=""
    while IFS= read -r line; do
      if [[ "$line" == "-----BEGIN CERTIFICATE-----" ]]; then
        current_pem="$line"
      elif [[ "$line" == "-----END CERTIFICATE-----" ]]; then
        current_pem+=$'\n'"$line"
        cert_pems+=("$current_pem")
        current_pem=""
      elif [[ -n "$current_pem" ]]; then
        current_pem+=$'\n'"$line"
      fi
    done <"$CERT_BUNDLE"
  else
    # fall back to distro-specific cert paths
    local SYS_ID
    SYS_ID="$(sed -En '/^ID.*(alpine|fedora|debian|ubuntu|opensuse).*/{
      s//\1/;p;q
    }' /etc/os-release 2>/dev/null)"
    local CERT_PATH
    case ${SYS_ID:-} in
    alpine)
      return 0
      ;;
    fedora)
      CERT_PATH='/etc/pki/ca-trust/source/anchors'
      ;;
    debian | ubuntu)
      CERT_PATH='/usr/local/share/ca-certificates'
      ;;
    opensuse)
      CERT_PATH='/usr/share/pki/trust/anchors'
      ;;
    *)
      return 0
      ;;
    esac
    # read each .crt file into the PEM array; `find` instead of glob
    # so zsh doesn't abort with NOMATCH when the dir is empty
    while IFS= read -r f; do
      [ -n "$f" ] && cert_pems+=("$(cat "$f")")
    done < <(find "$CERT_PATH" -maxdepth 1 -type f -name '*.crt' 2>/dev/null)
  fi

  if [ "${#cert_pems[@]}" -eq 0 ]; then
    printf '\033[36mno custom certificates found\033[0m\n' >&2
    return 0
  fi

  # discover certifi cacert.pem bundles
  local certifi_paths=()
  if [ $# -gt 0 ]; then
    # use explicitly provided paths
    for p in "$@"; do
      [ -f "$p" ] && certifi_paths+=("$p")
    done
  else
    # auto-discover Python certifi bundles
    type pip &>/dev/null || return 1
    local SHOW location cacert
    # check venv certifi
    if . .venv/bin/activate 2>/dev/null; then
      SHOW=""
      { [ -x "$HOME/.local/bin/uv" ] || [ -x "$HOME/.nix-profile/bin/uv" ]; } && SHOW=$(uv pip show -f certifi 2>/dev/null) || true
      [ -n "$SHOW" ] || SHOW=$(pip show -f certifi 2>/dev/null) || true
      if [ -n "$SHOW" ]; then
        location=$(echo "$SHOW" | sed -n 's/^Location: //p')
        if [ -n "$location" ]; then
          cacert=$(echo "$SHOW" | grep -oE '[^[:space:]]+cacert\.pem$')
          [ -n "$cacert" ] && certifi_paths+=("${location}/${cacert}")
        fi
      fi
    fi
    # check pip certifi
    SHOW=$(pip show -f certifi 2>/dev/null) || true
    if [ -n "$SHOW" ]; then
      location=$(echo "$SHOW" | sed -n 's/^Location: //p')
      if [ -n "$location" ]; then
        cacert=$(echo "$SHOW" | grep -oE '[^[:space:]]+cacert\.pem$')
        [ -n "$cacert" ] && certifi_paths+=("${location}/${cacert}")
      fi
    fi
    # check pip's own cacert.pem
    SHOW=$(pip show -f pip 2>/dev/null) || true
    if [ -n "$SHOW" ]; then
      location=$(echo "$SHOW" | sed -n 's/^Location: //p')
      if [ -n "$location" ]; then
        cacert=$(echo "$SHOW" | grep -oE '[^[:space:]]+cacert\.pem$')
        [ -n "$cacert" ] && certifi_paths+=("${location}/${cacert}")
      fi
    fi
  fi

  # exit if no target bundles found
  if [ ${#certifi_paths[@]} -eq 0 ]; then
    printf '\e[33mno certifi/cacert.pem bundles found\e[0m\n' >&2
    return 0
  fi

  # append custom certificates to each target bundle
  local cert_count=0
  local _added_serials=" "
  local certifi pem serial CERT
  for certifi in "${certifi_paths[@]}"; do
    echo "${certifi//$HOME/\~}" >&2
    for pem in "${cert_pems[@]}"; do
      serial=$(openssl x509 -noout -serial -nameopt RFC2253 <<<"$pem" 2>/dev/null | cut -d= -f2)
      [ -n "$serial" ] || continue
      if ! grep -qw "$serial" "$certifi"; then
        echo " - $(openssl x509 -noout -subject -nameopt RFC2253 <<<"$pem" | sed 's/\\//g')" >&2
        # _emit_cert_header is provided by certs.sh, sourced at the top of
        # this file via $HOME/.config/shell/certs.sh. Single source of truth
        # for the # Issuer:/# Subject:/... bundle marker format - see F-015.
        CERT="
$(_emit_cert_header <<<"$pem")
$(openssl x509 -outform PEM <<<"$pem")"
        if [ -w "$certifi" ]; then
          echo "$CERT" >>"$certifi"
        else
          printf '\e[33minsufficient permissions to write to %s, run the script as root.\e[0m\n' "$certifi" >&2
          break
        fi
        if [[ " $_added_serials " != *" $serial "* ]]; then
          _added_serials+="$serial "
          cert_count=$((cert_count + 1))
        fi
      fi
    done
  done
  if [ $cert_count -gt 0 ]; then
    printf "\e[34madded $cert_count certificate(s) to certifi bundle(s)\e[0m\n" >&2
  else
    printf '\e[34mno new certificates to add\e[0m\n' >&2
  fi
}

# alias for backward compatibility
alias fxcertpy='fixcertpy'

# cert_intercept used to live here. Moved to .assets/lib/certs.sh - search
# `cert_intercept()` in that file. Source the deployed copy at the durable
# shell-config location so the user-shell alias still works after a fresh
# shell start. nix/configure/profiles.sh installs certs.sh alongside
# functions.sh, and that step runs before the user re-sources their rc file.
# Silent skip when missing - a user whose certs.sh deploy didn't run gets
# "command not found: cert_intercept" at invocation time (with a clear
# remediation: re-run nix/setup.sh).
if [ -f "$HOME/.config/shell/certs.sh" ]; then
  # shellcheck source=../../lib/certs.sh
  . "$HOME/.config/shell/certs.sh"
fi
