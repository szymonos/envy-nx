# macOS: colima provides the Linux VM, docker-client + plugins provide the CLI.
# Linux: docker-ce installs via `install_docker.sh` (requires root, not via nix).
#
# `# bins: (external-installer)` sentinel: docker's binary location varies by
# platform - Linux has `docker` under /usr/bin (root-installed by docker-ce),
# macOS gets `colima` / `docker` / `docker-compose` / `docker-buildx` via nix
# but they may not be on the doctor's PATH until a new shell reloads. Skipping
# both nx doctor checks (PATH probe + ~/.nix-profile/bin/ probe) is correct
# here; functional verification belongs in `nix/configure/docker.sh` and the
# bats tests under `tests/bats/test_docker_configure.bats`.
# bins: (external-installer)
{ pkgs }: with pkgs; lib.optionals stdenv.isDarwin [
  colima
  docker-client
  docker-compose
  docker-buildx
]
