# Kubernetes dev - argo rollouts, cilium, flux, helm, hubble, humio, kustomize, trivy
# bins: kubectl-argo-rollouts cilium flux helm hubble humioctl kustomize trivy
{ pkgs }: with pkgs; [
  argo-rollouts
  cilium-cli
  crane
  fluxcd
  hubble
  humioctl
  kubernetes-helm
  kustomize
  kyverno
  trivy
]
