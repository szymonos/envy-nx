# Charter - `certs` shard (certificate / proxy path)

The cert/proxy path is the highest-blast-radius surface in this repo. A regression here breaks every HTTPS-dependent tool (git, curl, pip, npm, az, terraform, nix builds) on a corporate MITM network - exactly the failure mode this tool exists to prevent. Reviewers should weight findings accordingly.

## Scope

| File                                   | Role                                                                                                                |
| -------------------------------------- | ------------------------------------------------------------------------------------------------------------------- |
| `.assets/lib/certs.sh`                 | Core cert bundle assembly. `build_ca_bundle` (atomic, content-addressed); `merge_local_certs` (serial-dedup)        |
| `.assets/fix/fix_azcli_certs.sh`       | Patches azure-cli's certifi bundle with custom CAs                                                                  |
| `.assets/fix/fix_gcloud_certs.sh`      | Patches gcloud SDK's certifi bundle                                                                                 |
| `.assets/fix/fix_nodejs_certs.sh`      | Configures npm's `cafile` (system-wide if root, user-scope otherwise)                                               |
| `nix/lib/phases/nix_profile.sh`        | MITM detection via `openssl s_client`; cert extraction on TLS failure; `NIX_SSL_CERT_FILE` / `SSL_CERT_FILE` export |
| `nix/configure/nodejs.sh`              | `NODE_EXTRA_CA_CERTS` env wiring; npm cafile pinning post-install                                                   |
| `.assets/lib/nx_profile.sh`            | CA bundle render in user shell profile; `ca-custom.crt` managed-block injection                                     |
| `.assets/lib/env_block.sh`             | Per-tool env exports (`CURL_CA_BUNDLE`, `PIP_CERT`, `REQUESTS_CA_BUNDLE`, `NODE_EXTRA_CA_CERTS`, etc.)              |
| `.assets/lib/nx_doctor.sh`             | Health check for cert managed-block presence                                                                        |
| `.assets/setup/setup_profile_user.ps1` | WSL-side cert injection hook into PowerShell profile                                                                |
| `wsl/wsl_certs_add.ps1`                | Windows-host extraction of certs from Windows trust store; serial-format headers (matches certs.sh dedup)           |

**Out of scope** (reviewed by other shards): generic shell-profile rendering (→ `nx-cli` shard), the broader `nix/setup.sh` orchestration (→ `orchestration` shard), system-scope installers under `.assets/provision/install_*.sh` (→ `system-installers` shard).

**Cross-shard interactions to be aware of (but don't flag here):** the cert path reads from system trust stores populated by `install_base.sh` (system-installers shard) and writes managed blocks consumed by `nx_profile.sh` (nx-cli shard). Findings about those interactions belong in the cross-cutting "interaction review" if/when one is added - for now, in-scope only.

## What "good" looks like

- **The CA bundle is content-addressed and rebuilt atomically.** `~/.config/certs/ca-bundle.crt` is written via temp-file + rename so a partial write never poisons the trust store. Every rebuild is idempotent - running setup twice produces a byte-identical bundle.
- **MITM detection is non-fatal and correctly scoped.** A failed `openssl s_client` probe means "we may be behind a MITM proxy and need to extract the chain", not "exit the script." The detection runs once per setup, recorded in install state, and informs a single decision (whether to extract certs from the proxy).
- **Per-tool patching is reversible.** Every framework patcher (`fix_azcli_certs.sh`, `fix_gcloud_certs.sh`, `fix_nodejs_certs.sh`) writes to a known location with a known marker, and uninstall paths can undo it cleanly. No silent in-place mutation of vendor files without a way back.
- **Cross-platform parity is consistent.** macOS sources from Keychain via `security export`; Linux sources from `/etc/ssl/certs/ca-certificates.crt` (Debian/Ubuntu) or `/etc/pki/tls/certs/ca-bundle.crt` (Fedora/RHEL). The two paths produce equivalent bundles for downstream tools - a Mac on the same network gets the same trust as a Linux box.
- **Serial-based dedup prevents double-counting.** `merge_local_certs` extracts the cert serial via `openssl x509` and skips entries already present. WSL extraction (`wsl_certs_add.ps1`) writes the same serial-format header so dedup works across both code paths.
- **Trust-store env vars are exported in every shell.** `CURL_CA_BUNDLE`, `SSL_CERT_FILE`, `NIX_SSL_CERT_FILE`, `PIP_CERT`, `REQUESTS_CA_BUNDLE`, `NODE_EXTRA_CA_CERTS`, `AWS_CA_BUNDLE` etc. - populated identically in bash, zsh, and PowerShell profile blocks. Missing one means the corresponding tool sees a broken cert chain on the next invocation.
- **`nx doctor` catches drift.** If the managed cert block is missing from a profile or the bundle is stale, doctor emits a fixable warning. Silent breakage is the worst possible failure mode here - every degraded state should be detectable.

## What NOT to flag (de-noise list)

These are intentional design decisions documented elsewhere. Re-flagging them just produces noise.

- **Managed-block sentinels (`# >>> ... >>>` / `# <<< ... <<<`) are intentional.** See [`docs/decisions.md` → "Why managed blocks"](../../../docs/decisions.md#why-managed-blocks-not-append-style-profile-injection). Anything suggesting "use a separate file instead" or "this is fragile, just append" is out of scope.
- **`curl | sh` for nix bootstrap is intentional.** See [`docs/decisions.md` → "Why not checksum-pin the Nix installer"](../../../docs/decisions.md#why-not-checksum-pin-the-nix-installer). Findings about adding hash verification on the installer download will not be acted on.
- **No GNU extensions in `sed`/`grep`.** The cert path runs on macOS bash 3.2 with BSD utilities. `\s`, `\w`, `-P`, `-r` are unavailable. See [`docs/decisions.md` → "Why bash 3.2 compatibility"](../../../docs/decisions.md#why-bash-32-compatibility). Don't flag the verbose POSIX equivalents as "should use modern regex."
- **`NIX_SSL_CERT_FILE` set early is intentional.** It must be exported before any nix subprocess starts. Findings about "this is set in two places" are usually misreading the call order.
- **The bundle path `~/.config/certs/ca-bundle.crt` is a public contract.** Other tools, including third-party scripts, may read it. Don't suggest renaming or relocating without strong cross-platform reasoning.
- **Anything already in `design/reviews/accepted.md`.** Cross-check before flagging. New context can justify revisiting an accepted decision, but you must cite the `A-NNN` ID and explain what's new.

## Severity rubric

| Level    | Definition                                                                                                                                  | Examples                                                                                                                       |
| -------- | ------------------------------------------------------------------------------------------------------------------------------------------- | ------------------------------------------------------------------------------------------------------------------------------ |
| critical | Data loss, security breach, unrecoverable trust-store state, silent acceptance of an attacker's cert.                                       | `verify=False` snuck into a TLS context; trust store wiped without backup; cert extraction trusts arbitrary input.             |
| high     | Incorrect cert behavior under MITM, breaks reproducibility across runs, silent fallback to insecure path, missing exports for a major tool. | `CURL_CA_BUNDLE` not exported in zsh profile; `merge_local_certs` writes a corrupt bundle on partial input.                    |
| medium   | Degraded UX, surprising error, missing error handling at internal boundary, fragile assumption that works today but breaks easily.          | `openssl x509` failure swallowed without `warn`; brittle path lookup that depends on distro-specific layout.                   |
| low      | Docs gap, naming inconsistency, dead code, comment rot, minor refactor opportunity that doesn't change behavior.                            | Stale comment referencing a removed function; inconsistent variable naming between `_ca_bundle` and `caBundle`; orphan helper. |

The fixer prioritizes by severity but processes in the order the human approves during `/review act`. Don't optimize "fixability" into severity - a one-line `low` finding stays `low` even if fixing it takes ten seconds.

## Categories

| Category        | Use for                                                                                                             |
| --------------- | ------------------------------------------------------------------------------------------------------------------- |
| correctness     | The code does the wrong thing under some input or condition.                                                        |
| security        | Trust boundary violation, weakened verification, exposed credential.                                                |
| maintainability | Code is correct but will be hard to change safely; hidden coupling; missing abstraction at a real seam.             |
| testability     | Behavior cannot be verified by the test suite; missing test for a non-obvious code path; mock divergence from prod. |
| docs            | Comment, runnable-examples block, or referenced doc is wrong, missing, or out of date.                              |

A finding has exactly one category. If genuinely cross-cutting, pick the one that drives the fix.

## References

- [`docs/decisions.md` → "Why managed blocks"](../../../docs/decisions.md#why-managed-blocks-not-append-style-profile-injection)
- [`docs/decisions.md` → "Why not checksum-pin the Nix installer"](../../../docs/decisions.md#why-not-checksum-pin-the-nix-installer)
- [`docs/decisions.md` → "Why bash 3.2 compatibility"](../../../docs/decisions.md#why-bash-32-compatibility)
- [`docs/proxy.md`](../../../docs/proxy.md) - user-facing flow for the cert/proxy path; useful to understand the public contract you're reviewing against
- `ARCHITECTURE.md` - search for `certs` / `proxy` sections (do NOT read the whole file; grep for the relevant headers)
- [`design/reviews/accepted.md`](../accepted.md) - defers and disputes; consult before emitting any finding

## Charter version

Increment this when the charter changes substantively (scope edit, severity rubric tweak, new de-noise entry). Bump invalidates the `charter_sha` in any in-flight findings JSON, prompting a re-review at `/review act` time.

- v1 (2026-05-09) - initial charter; framework bootstrap.
