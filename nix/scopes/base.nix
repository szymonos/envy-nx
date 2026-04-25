# Base packages - always installed
{ pkgs }: with pkgs; [
  bash-completion
  cacert
  coreutils
  findutils
  gawk
  gnupg
  git
  gh
  bind          # provides dig, nslookup, host
  less
  openssl
  tree
  unzip
  vim
  wget
]
