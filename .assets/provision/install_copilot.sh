#!/usr/bin/env bash
: '
.assets/provision/install_copilot.sh
'
set -euo pipefail

if [ $EUID -eq 0 ]; then
  printf '\e[31;1mDo not run the script as root.\e[0m\n' >&2
  exit 1
fi

# user specific environment
if ! [[ "$PATH" =~ $HOME/.local/bin: ]]; then
  PATH="$HOME/.local/bin:$PATH"
fi
export PATH

# Announce on stdout (not stderr): _io_run captures stderr and only surfaces it
# on failure, so a stderr label would be swallowed on the normal success path,
# leaving the tool's own "Checking for updates..." output unattributed in logs.
if [ -x "$HOME/.local/bin/copilot" ]; then
  printf "\e[92mupdating \e[1mcopilot-cli\e[22m\e[0m\n"
  # Non-fatal: setup_common.sh calls this script first and unguarded under its
  # own `set -euo pipefail`, so a transient updater failure (offline, GitHub
  # outage, expired auth) would abort the zsh plugin setup, pwsh module install
  # and user-profile rendering that follow. Refreshing an already-installed
  # optional tool must not take those down. The install branch stays fatal.
  copilot update || printf '\e[33;1m::warning:: copilot update failed, keeping the installed version\e[0m\n'
else
  printf "\e[92minstalling \e[1mcopilot-cli\e[22m\e[0m\n"
  # gh.io is a URL shortener, so the payload piped into bash arrives from the
  # redirect target; --proto '=https' already denies a non-https hop there.
  curl --proto '=https' --proto-redir '=https' --tlsv1.2 -fsSL https://gh.io/copilot-install | bash
fi
