# Kubernetes dev - argo rollouts, cilium, flux, hubble, humio, kustomize, trivy
# bins: kubectl-argo-rollouts cilium flux hubble humioctl kustomize trivy
{ pkgs }: with pkgs; [
  argo-rollouts
  cilium-cli
  crane
  fluxcd
  hubble
  humioctl
  kustomize
  kyverno
  trivy
]
