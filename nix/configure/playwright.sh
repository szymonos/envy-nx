#!/usr/bin/env bash
# Install the playwright CLI as a uv tool. On Linux it is pinned to the version
# of the nix-built browsers from the playwright scope, so `playwright --version`
# names the version a project must pin. On macOS the scope installs no browsers:
# take the latest release and let it download its own Chromium.
: '
nix/configure/playwright.sh
'
set -eo pipefail

for _p in "$HOME/.local/bin" "$HOME/.nix-profile/bin"; do
  case ":$PATH:" in *":$_p:"*) ;; *) PATH="$_p:$PATH" ;; esac
done
command -v uv &>/dev/null || {
  printf '\e[31;1muv not found - the playwright scope needs the python scope\e[0m\n' >&2
  exit 1
}

ver_file="$HOME/.nix-profile/share/playwright-browsers.version"
spec='playwright'
[ -f "$ver_file" ] && spec="playwright==$(cat "$ver_file")"

# stdout, not stderr: _io_run replays stderr only on failure
printf '\e[96minstalling %s via uv tool...\e[0m\n' "$spec"
UV_SYSTEM_CERTS=true uv tool install --quiet --upgrade "$spec"

if [ "$(uname -s)" = 'Darwin' ]; then
  "$(uv tool dir --bin)/playwright" install chromium
fi
