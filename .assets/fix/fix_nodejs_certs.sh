#!/usr/bin/env bash
: '
# set user-scope npm cafile
.assets/fix/fix_nodejs_certs.sh
# set system-wide npm cafile (requires root)
sudo .assets/fix/fix_nodejs_certs.sh
'
set -euo pipefail

if [ $EUID -eq 0 ]; then
  # *root: set global cafile to the system CA bundle
  SYS_ID="$(sed -En '/^ID.*(alpine|arch|fedora|debian|ubuntu|opensuse).*/{s//\1/;p;q}' /etc/os-release)"
  case $SYS_ID in
  alpine | arch)
    # alpine ships busybox npm shim only; arch users typically install npm
    # via nvm/fnm where global cafile is meaningless. Skip silently.
    exit 0
    ;;
  debian | ubuntu)
    CERT_PATH='/etc/ssl/certs/ca-certificates.crt'
    ;;
  fedora)
    CERT_PATH='/etc/pki/tls/certs/ca-bundle.crt'
    ;;
  opensuse)
    CERT_PATH='/etc/ssl/ca-bundle.pem'
    ;;
  *)
    printf '\e[1;33mWarning: Unsupported system id (%s).\e[0m\n' "$SYS_ID" >&2
    exit 0
    ;;
  esac
  # `npm config get cafile` returns the value directly (`null` for unset).
  # The previous `npm config get | grep -q 'cafile'` substring-matched the
  # full listing - which always contains `cafile=null` even when unset, so
  # the condition was always true and the body never ran. Match the same
  # pattern used in nix/configure/nodejs.sh:107-108. Also gate on CERT_PATH
  # actually existing - ships-with-distro paths can be missing on minimal
  # container images.
  _existing_cafile="$(npm config get cafile 2>/dev/null || echo null)"
  if { [ "$_existing_cafile" = "null" ] || [ -z "$_existing_cafile" ]; } && [ -f "$CERT_PATH" ]; then
    npm config set -g cafile "$CERT_PATH"
  fi
else
  # *non-root: set user-scope cafile to the full trust store bundle
  CERT_BUNDLE="$HOME/.config/certs/ca-bundle.crt"
  if [ -f "$CERT_BUNDLE" ]; then
    _existing_cafile="$(npm config get cafile 2>/dev/null || echo null)"
    if [ "$_existing_cafile" = "null" ] || [ -z "$_existing_cafile" ]; then
      npm config set cafile "$CERT_BUNDLE"
    fi
  fi
fi
