# Kubernetes ext - local cluster tools
# bins: minikube k3d kind
{ pkgs }: with pkgs; [
  # lowPrio so standalone kubectl (from k8s_base) wins over minikube's bundled kubectl in buildEnv
  (lib.lowPrio minikube)
  k3d
  kind
]
