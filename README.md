# envy-nx

Universal, cross-platform developer environment provisioning with Nix. One command to setup, upgrade, rollback, or cleanly uninstall - on macOS, Linux, WSL, and Coder.

## Quick start

```bash
# macOS / Linux (git)
git clone https://github.com/szymonos/envy-nx.git
cd envy-nx
nix/setup.sh --shell --python --pwsh

# macOS / Linux (tarball - no git required)
curl -LO https://github.com/szymonos/envy-nx/releases/latest/download/envy-nx.tar.gz
tar xzf envy-nx.tar.gz && cd envy-nx-*
nix/setup.sh --shell --python --pwsh
```

```powershell
# WSL (from PowerShell on Windows host)
git clone https://github.com/szymonos/envy-nx.git
cd envy-nx
wsl/wsl_setup.ps1 'Ubuntu' -s @('shell', 'python', 'pwsh')
```

After setup, the repo clone is disposable. All state lives in `~/.config/nix-env/`, managed by the `nx` CLI:

```bash
nx install httpie       # add a package
nx upgrade              # upgrade all packages
nx rollback             # revert if something breaks
nx doctor               # run health checks
```

## Why envy-nx

- **One command** provisions a complete, standards-compliant workstation - no manual steps, no prerequisites beyond git
- **Cross-platform** - identical experience on macOS, Linux, WSL, and rootless containers
- **Corporate proxy handling** - MITM certificates detected and resolved automatically across Nix, Python, Node.js, and all other framework trust stores
- **Composable scopes** - pick what you need (`--shell --k8s-dev --terraform`), skip what you don't
- **Full lifecycle** - install, upgrade, rollback, and clean uninstall with `--dry-run` preview
- **Extensible without forking** - team overlays, custom scopes, and setup hooks via `NIX_ENV_OVERLAY_DIR`
- **Comprehensive test suites** (bats + Pester), custom pre-commit hooks, CI-validated on macOS and Linux on every PR

## Available scopes

| Scope       | Packages                                    |
| ----------- | ------------------------------------------- |
| `shell`     | fzf, eza, bat, ripgrep, yq                  |
| `python`    | uv, prek                                    |
| `pwsh`      | PowerShell 7                                |
| `k8s-base`  | kubectl, kubelogin, k9s, kubecolor, kubectx |
| `k8s-dev`   | helm, flux, kustomize, trivy, argo, cilium  |
| `az`        | Azure CLI, azcopy                           |
| `terraform` | terraform, tflint                           |
| `nodejs`    | Node.js                                     |
| `conda`     | Miniforge                                   |
| `docker`    | Docker post-install configuration           |

Prompt engines (oh-my-posh, starship) and additional scopes (gcloud, bun, rice, zsh) are also available. Run `nix/setup.sh --help` for the full list.

## Documentation

Full documentation is available at [szymonos.github.io/envy-nx](https://szymonos.github.io/envy-nx/).

## License

[MIT](LICENSE)
