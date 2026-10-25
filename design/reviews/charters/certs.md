# Charter - `certs`

The certificate and proxy path. A regression breaks every HTTPS tool - git, curl, pip, npm, az, nix builds - on a corporate MITM network, which is exactly the failure this tool exists to prevent. The shard owns the bundle builder, the probe, the per-tool fixers and WSL cert extraction; it reads the cert parts of the profile renderers and the MITM probe phase as context.

## What good looks like

- **The CA bundle is rebuilt atomically and idempotently.** `~/.config/certs/ca-bundle.crt` is written temp-file-then-rename; two runs produce identical bytes.
- **MITM detection is non-fatal.** A failed probe means "extract the chain", never "exit".
- **Per-tool fixers are reversible** - known location, known marker, an uninstall path back.
- **macOS and Linux produce equivalent bundles** (Keychain export vs the distro CA file).
- **Dedup by serial works across paths.** `merge_local_certs` and `wsl/wsl_certs_add.ps1` write the same serial header.
- **Every trust-store variable is exported in every shell** - `SSL_CERT_FILE`, `NIX_SSL_CERT_FILE`, `REQUESTS_CA_BUNDLE`, `CURL_CA_BUNDLE`, `PIP_CERT`, `AWS_CA_BUNDLE`, `NODE_EXTRA_CA_CERTS` - identically in bash, zsh and PowerShell.
- **Tests** cover dedup, a missing or empty system bundle, and the probe's failure path.

## What NOT to flag

- **`curl | sh` for the Nix installer** - see "Why not checksum-pin the Nix installer".
- **BSD-only `sed`/`grep`** - the path runs on macOS bash 3.2.
- **`NIX_SSL_CERT_FILE` set early** - it must be exported before any nix subprocess.
- **The bundle path `~/.config/certs/ca-bundle.crt`** - a public contract other tools read.
- **A PowerShell `clean {}` block as temp-file cleanup**, and **`.assets/fix/*.sh` as execution-only** - `REVIEW.md` Author decisions.
- **Directories, symlinks or hand-edited content planted in `~/.config/certs/`** - the tool writes every file there itself (newline-terminated PEM, `ca-custom.crt` never aliasing `ca-bundle.crt`).
- **The Linux `ca-bundle.crt` symlink leaving out `ca-custom.crt`** - WSL users have root and install the proxy CA into the system store, Coder runs without a proxy; a rootless container behind a proxy handles its system certs itself.
- **No hostname check in `_cert_probe_pinned`** - the probe only asks whether the chain verifies against the Mozilla roots; a MITM proxy fails that whatever name it presents.

## References

- `ARCHITECTURE.md` sections 3g and 13.7
- `docs/proxy.md`
