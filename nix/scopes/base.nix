# Base packages - always installed
{ pkgs }: with pkgs; [
  bash-completion
  cacert
  gnupg
  git
  gh
  bind          # provides dig, nslookup, host
  less
  man-db
  openssl
  tree
  unzip
  vim
  wget
]
# GNU coreutils/findutils/gawk reimplement macOS's BSD userland with divergent
# flags/semantics; with ~/.nix-profile/bin prepended to PATH they shadow the system
# tools every macOS script relies on (see design/decisions/0009-macos-bsd-userland).
# Off-Darwin (Linux/containers, where the base may be busybox/minimal) always add
# them. On macOS they are opt-in: nx install coreutils findutils gawk
++ lib.optionals (!stdenv.hostPlatform.isDarwin) [
  coreutils
  findutils
  gawk
]
