# Kubernetes ext - local cluster tools
# bins: minikube k3d kind
# minikube ships `bin/kubectl` as a symlink to itself, which collides with the
# real kubectl - see `collisionLowPrio` in flake.nix.
{ pkgs }: with pkgs; [
  minikube
  k3d
  kind
]
