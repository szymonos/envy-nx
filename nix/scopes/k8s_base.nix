# Kubernetes base - kubectl, kubelogin, helm, k9s, kubecolor, kubectx/kubens
# bins: kubectl kubelogin helm k9s kubecolor kubectx kubens
{ pkgs }: with pkgs; [
  kubectl
  kubelogin
  kubernetes-helm
  k9s
  kubecolor
  kubectx
]
