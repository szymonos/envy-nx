# Generic managed-env block for shell rc files.
# Contains user-scope PATH and cert env vars that are not nix-specific.
# Shared by nix and legacy setup paths.
# Compatible with bash 3.2 and zsh (sourced by both).
#
# Usage:
#   source .assets/lib/env_block.sh
#   render_env_block   # prints block content to stdout
#
# Requires: profile_block.sh must be sourced first (for manage_block).

# shellcheck disable=SC2034  # used by sourcing scripts
ENV_BLOCK_MARKER="env:managed"
# MIGRATION: legacy marker name from <= 1.4.x. Sourcing scripts can use
# this constant to strip the old block before upserting the new one.
# Safe to delete after the next major release.
# shellcheck disable=SC2034
ENV_BLOCK_LEGACY_MARKER="managed env"

# render_env_block
# Prints the managed env block content to stdout.
# Two sections: local path and cert env vars.
# Caller writes output to a temp file and passes to manage_block.
#
# NOTE: this function is ~95% byte-identical to `_nx_render_env_block` in
# .assets/lib/nx_profile.sh (only structural difference: the `function `
# keyword). The nix-managed path uses that copy; this one is consumed by
# the legacy zsh setup path. Any change to the rendered :certs / :gcloud /
# :aliases sections here MUST be mirrored to nx_profile.sh byte-for-byte,
# or zsh-only installs drift from bash-managed installs. Consolidation is
# tracked in design/follow-ups (cycle 2026-05-13).
render_env_block() {
  # :local path
  printf '# :local path\n'
  printf 'case ":$PATH:" in *":$HOME/.local/bin:"*) ;; *)\n'
  printf '  [ -d "$HOME/.local/bin" ] && export PATH="$HOME/.local/bin:$PATH"\n'
  printf 'esac\n'

  # :locale - silence "can't set the locale" from nix-glibc binaries (e.g.
  # ~/.nix-profile/bin/man) on non-NixOS Linux. The branches are MUTUALLY
  # EXCLUSIVE - LOCPATH and LOCALE_ARCHIVE are not additive in glibc:
  # if LOCPATH is set, glibc uses per-directory lookup ONLY and never
  # falls back to the archive (verified in a Debian 13 container with the
  # `locales` apt package installed - LOCPATH alone reproduces the warning,
  # LOCALE_ARCHIVE alone fixes it, both-set re-introduces the warning).
  #
  #   - /usr/lib/locale/locale-archive present  (Debian, RHEL, Ubuntu
  #     with `locales` package installed): set LOCALE_ARCHIVE +
  #     LOCALE_ARCHIVE_2_27 to point at the archive. The "2_27" suffix
  #     is a nixpkgs patch; some nix-glibc builds honor only the
  #     suffixed form, others only plain. Setting both is harmless -
  #     plain is ignored when the suffixed form is set.
  #   - else if /usr/lib/locale/ is a per-directory store  (Fedora,
  #     Alpine, minimal Ubuntu): set LOCPATH so glibc finds the per-dir
  #     locales it would otherwise miss.
  #   - else  (macOS, container without locale data): no-op.
  #
  # WATCHOUT: do NOT set LOCPATH when the archive exists - it breaks
  # the archive lookup. This is exactly the failure shape that hit
  # Debian 13 users in the v1.10.3 single-export attempt.
  printf '\n# :locale\n'
  printf 'if [ -f /usr/lib/locale/locale-archive ]; then\n'
  printf '  export LOCALE_ARCHIVE=/usr/lib/locale/locale-archive\n'
  printf '  export LOCALE_ARCHIVE_2_27=/usr/lib/locale/locale-archive\n'
  printf 'elif [ -d /usr/lib/locale ]; then\n'
  printf '  export LOCPATH=/usr/lib/locale\n'
  printf 'fi\n'

  # :aliases (generic - nix-installed tools have their aliases in the nix block)
  if [ -f "$HOME/.config/shell/functions.sh" ]; then
    printf '\n# :aliases\n'
    printf '[ -f "$HOME/.config/shell/functions.sh" ] && . "$HOME/.config/shell/functions.sh"\n'
  fi
  if [ -f "$HOME/.config/shell/aliases_git.sh" ] && command -v git &>/dev/null && [ ! -x "$HOME/.nix-profile/bin/git" ]; then
    printf '[ -f "$HOME/.config/shell/aliases_git.sh" ] && . "$HOME/.config/shell/aliases_git.sh"\n'
  fi
  if [ -f "$HOME/.config/shell/aliases_kubectl.sh" ] && command -v kubectl &>/dev/null && [ ! -x "$HOME/.nix-profile/bin/kubectl" ]; then
    printf '[ -f "$HOME/.config/shell/aliases_kubectl.sh" ] && . "$HOME/.config/shell/aliases_kubectl.sh"\n'
  fi

  # :certs
  local cert_dir="$HOME/.config/certs"
  # `-f` for ca-custom.crt (always a regular file written by cert_intercept /
  # merge_local_certs); `-e` for ca-bundle.crt (a symlink to the system store
  # on Linux, a regular file on macOS - `-f` would skip valid symlinks).
  # The asymmetry is intentional; do not "normalize" it.
  if [ -f "$cert_dir/ca-custom.crt" ] || [ -e "$cert_dir/ca-bundle.crt" ]; then
    printf '\n# :certs\n'
  fi
  if [ -f "$cert_dir/ca-custom.crt" ]; then
    printf 'if [ -f "$HOME/.config/certs/ca-custom.crt" ]; then\n'
    printf '  export NODE_EXTRA_CA_CERTS="$HOME/.config/certs/ca-custom.crt"\n'
    printf 'fi\n'
  fi
  if [ -e "$cert_dir/ca-bundle.crt" ]; then
    printf 'if [ -f "$HOME/.config/certs/ca-bundle.crt" ]; then\n'
    printf '  export REQUESTS_CA_BUNDLE="$HOME/.config/certs/ca-bundle.crt"\n'
    printf '  export SSL_CERT_FILE="$HOME/.config/certs/ca-bundle.crt"\n'
    # CURL_CA_BUNDLE / PIP_CERT / AWS_CA_BUNDLE complement REQUESTS_CA_BUNDLE
    # for tools that read their own env var (curl, pip, AWS SDKs/CLI). All
    # point at the full ca-bundle.crt so corp-network users invoking those
    # CLIs directly outside an env-aware tool wrapper get cert verification.
    printf '  export CURL_CA_BUNDLE="$HOME/.config/certs/ca-bundle.crt"\n'
    printf '  export PIP_CERT="$HOME/.config/certs/ca-bundle.crt"\n'
    printf '  export AWS_CA_BUNDLE="$HOME/.config/certs/ca-bundle.crt"\n'
    printf 'fi\n'
    # Predicate accepts both nix-profile gcloud and the tarball install at
    # $HOME/google-cloud-sdk; the latter is on PATH only after the :gcloud
    # block runs in a new shell, so the bare directory check is the right
    # render-time signal during a fresh setup pass.
    if [ -d "$HOME/google-cloud-sdk/bin" ] || command -v gcloud &>/dev/null; then
      printf 'if [ -f "$HOME/.config/certs/ca-bundle.crt" ]; then\n'
      printf '  export CLOUDSDK_CORE_CUSTOM_CA_CERTS_FILE="$HOME/.config/certs/ca-bundle.crt"\n'
      printf 'fi\n'
    fi
  fi

  # :gcloud - tarball install at $HOME/google-cloud-sdk (see
  # nix/configure/gcloud.sh). Adds bin/ to PATH and sources the bundled
  # completion script (bash/zsh branched at runtime).
  if [ -d "$HOME/google-cloud-sdk/bin" ]; then
    printf '\n# :gcloud\n'
    printf 'if [ -d "$HOME/google-cloud-sdk/bin" ]; then\n'
    printf '  case ":$PATH:" in *":$HOME/google-cloud-sdk/bin:"*) ;; *)\n'
    printf '    export PATH="$HOME/google-cloud-sdk/bin:$PATH"\n'
    printf '  esac\n'
    printf '  if [ -n "${BASH_VERSION:-}" ] && [ -f "$HOME/google-cloud-sdk/completion.bash.inc" ]; then\n'
    printf '    . "$HOME/google-cloud-sdk/completion.bash.inc"\n'
    printf '  elif [ -n "${ZSH_VERSION:-}" ] && [ -f "$HOME/google-cloud-sdk/completion.zsh.inc" ]; then\n'
    printf '    . "$HOME/google-cloud-sdk/completion.zsh.inc"\n'
    printf '  fi\n'
    printf 'fi\n'
  fi
}
