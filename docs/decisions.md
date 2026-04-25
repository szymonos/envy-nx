# Design Decisions

Every tool makes architectural choices that shape what it can and cannot do. This page explains the reasoning behind the key decisions in this project - not just what was chosen, but why the obvious alternatives were rejected.

## Architecture decisions

### Why Nix, not Homebrew

**The objection:** "Homebrew works fine, everyone knows it, and it's already installed on most Macs."

Homebrew is an excellent macOS package manager. It is not a cross-platform environment provisioning tool. The differences matter at scale:

| Capability               | Homebrew                         | Nix                                       |
| ------------------------ | -------------------------------- | ----------------------------------------- |
| Atomic rollback          | No                               | Yes (`nix profile rollback`)              |
| Reproducible pins        | No lock file, no version pinning | `flake.lock` + `nx pin set <rev>`         |
| Cross-platform           | macOS-first, Linux second-class  | macOS, Linux, WSL, containers - identical |
| User-scope after install | Requires sudo for updates        | No root after initial install             |
| Package composition      | Flat list, no grouping           | `buildEnv` merges scopes atomically       |
| Binary cache             | Bottles (limited arch coverage)  | 100k+ cached packages, multi-arch         |

Beyond the feature comparison, Nix provides a structural advantage: **store-based isolation**. Every package is installed into a content-addressed path (`/nix/store/<hash>-<name>-<version>/`), so multiple versions of the same tool coexist without conflict and upgrades never leave the system in a half-updated state. Homebrew mutates shared prefixes in-place - an interrupted `brew upgrade` can leave broken symlinks that require manual cleanup. Nix's immutable store makes rollback a pointer swap, not a repair job.

The runtime characteristics reflect the architectural gap. Nix's core is C++ with a purpose-built functional evaluation language - every invocation resolves a dependency graph declaratively and applies the result atomically. Homebrew is a cohesive Ruby codebase, but every `brew` invocation pays Ruby interpreter startup cost, formula evaluation is interpreted, and `brew upgrade` processes packages sequentially with per-package overhead. At scale - dozens of packages across scopes - the difference compounds.

Homebrew installs packages. Nix provisions environments - declaratively, atomically, and reproducibly.

**The enterprise off-ramp:** Nix adoption carries organizational risk. [Determinate Systems](https://determinate.systems/nix/macos/mdm/) provides a commercially supported Nix installer with MDM integration (Jamf, Intune), enterprise support contracts, and managed fleet deployment. If the organization decides to formalize Nix adoption, the transition from the open-source installer to the enterprise offering is a configuration change, not a rewrite. The tool is already built on the Determinate Systems installer as its recommended installation method.

### Why not golden images

**The objection:** "Just bake a VM image or container with everything pre-installed, push it to developers."

Golden images are the default enterprise answer to environment standardization. They fail in developer workstation contexts for several reasons:

**WSL golden images require disproportionate effort.** Building a custom WSL disk image is technically possible, but it demands a custom build pipeline, manual distribution, and ongoing maintenance - significantly more effort than a bootstrapper that provisions WSL in minutes from a single PowerShell command. WSL is the most popular development environment on enterprise Windows; any solution that cannot provision it easily is incomplete in practice.

**Images go stale immediately.** A golden image is a snapshot. The day after distribution, packages are outdated. Every update requires a new build-test-distribute cycle through the MDM pipeline. Developers either wait for the next image refresh or install tools manually on top - re-creating the inconsistency the image was supposed to prevent.

**Images solve certificates at the wrong layer.** A golden image can ship with corporate CA certificates pre-installed, covering the OS trust store and some frameworks. But certificates expire - when they do, every deployed image needs a rebuild or a separate automation to rotate certs, which is exactly the tooling this solution already provides. More fundamentally, golden images resolve certificate trust at the system level and for some framework-level paths, but not all execution paths. An application not launched via bash will not see environment variables set in a bash profile. Different frameworks consult different certificate stores. This tool resolves MITM certificate issues at runtime, independently of how each framework is launched, covering execution paths that images cannot reach.

**Images cannot handle diverse network environments.** Vendors and contractors typically cannot receive golden images - they work on their own hardware. This solution is far more accessible: clone the repo, run the setup. Additionally, contractors connecting through external networks often encounter different MITM certificate chains than internal employees. A golden image baked against the internal proxy will fail on a contractor's network. Runtime certificate interception handles both scenarios transparently.

**Images are all-or-nothing.** A data scientist and a platform engineer need different toolchains. Golden images either ship everything (bloated, slow to distribute) or require multiple image variants (multiplied maintenance). Scopes solve this: `--shell --python` for the data scientist, `--shell --k8s-dev --terraform` for the platform engineer, from the same base.

This tool takes the opposite approach: a lightweight bootstrapper that runs on the developer's actual machine, detects the actual network environment, installs exactly what's needed, and stays current via `nx upgrade`. It works on every platform - including WSL - because it provisions rather than snapshots.

### Why a bootstrapper, not a configuration management agent

**The objection:** "Use Ansible, Chef, or Puppet - that's what configuration management tools are for."

Configuration management tools are designed for servers: homogeneous fleets, root access, persistent agents, central control planes. Developer workstations are the opposite:

| Server fleet            | Developer workstation            |
| ----------------------- | -------------------------------- |
| Homogeneous OS          | macOS + WSL + Linux + Coder      |
| Root access guaranteed  | Managed machines restrict root   |
| Agent runs continuously | No daemon, no background process |
| Central server required | Works offline after setup        |
| IT-managed              | Developer-managed                |

Ansible requires Python and SSH. Chef requires a server and a Ruby agent. Puppet requires a daemon and a control plane. All three assume root access and target a single OS distribution per playbook/recipe/manifest. None handle the cross-platform, user-scope, rootless requirements of developer workstations.

This tool is a **bootstrapper**: it runs once, provisions a self-contained environment in `~/.config/nix-env/`, and exits. No daemon, no server, no runtime dependency. After setup:

- `nx upgrade` updates packages - no central server needed
- `nx rollback` reverts if something breaks - no IT ticket needed
- `nx doctor` runs health checks - no monitoring agent needed
- The repository clone is disposable - all state is local

The bootstrapper model means zero operational overhead: no agent to monitor, no server to maintain, no network dependency for day-to-day use. The tool provisions the environment and gets out of the way. From there, developers can continue using the repo individually to manage their environment, or teams and organizations can distribute overlays to extend and customize capabilities - without contributing to the upstream repository.

### Why three package tiers, not "everything via nix"

**The objection:** "Nix can install anything. Just put every package in the flake and stop maintaining system-level install scripts."

Nix is a user-scope package manager. It runs without root after the one-time install. That is its greatest strength - and it creates a hard boundary around what it can provide. Some packages require root, setuid, or must exist before nix is available. Others need to live in system paths for `sudo`, `chsh`, or AllUsers profile setup to work. Forcing these into nix creates fragile workarounds that break under real-world conditions.

Every package in this project belongs to exactly one of three tiers:

| Tier          | Installed by                  | Managed by     | Example packages                         |
| ------------- | ----------------------------- | -------------- | ---------------------------------------- |
| System-only   | `install_base.sh` (root)      | System pkg mgr | ca-certificates, curl, sudo, build tools |
| System-prefer | System on Linux, nix on macOS | Conditional    | vim, pwsh, zsh                           |
| Always nix    | `nix/setup.sh` (user-scope)   | Nix flake      | git, ripgrep, fzf, kubectl, uv           |

**System-only** packages cannot be user-scoped by definition. `ca-certificates` populates the system TLS trust store read by every process. `sudo` requires setuid root. `curl` must exist before nix is available - it downloads the nix installer. `build-essential` provides the C compiler nix needs for flake builds. These are installed once by `install_base.sh` and never touched by nix.

**System-prefer** packages need to exist in system paths (`/usr/bin/`) on Linux but have no system package manager on macOS. The detection is platform-based, not host-introspection: on Linux, if `/usr/bin/pwsh` exists, `nix/setup.sh` skips the nix pwsh scope automatically. On macOS (`uname -s == Darwin`), the check is skipped entirely and nix provides the package. This logic lives in `phase_scopes_skip_system_prefer()` in the scopes phase - centralized in `nix/setup.sh`, not scattered across callers.

The three system-prefer packages each have a concrete reason they cannot be nix-only on Linux:

- **vim** - `sudo vim /etc/fstab` requires a vim binary accessible to root. Nix vim lives in `~/.nix-profile/bin/vim`, invisible to `sudo` without `env_keep` or explicit PATH forwarding. Every Linux distro ships vim - there is no version consistency benefit to justify the workaround.
- **pwsh** - PowerShell's AllUsers profile (`/opt/microsoft/powershell/7/profile.ps1`) and system-wide module paths require a system-installed `/usr/bin/pwsh`. The nix pwsh would install a second copy that cannot serve these roles. On macOS, there is no system pwsh and no AllUsers profile convention, so nix is the correct provider.
- **zsh** - `chsh -s /usr/bin/zsh` requires the shell path to exist in `/etc/shells`. Nix zsh lives in `~/.nix-profile/bin/zsh`, which is user-specific, may change on upgrades, and is rejected by PAM on some distributions. The nix `zsh.nix` scope ships only plugins (autosuggestions, syntax highlighting, completions) - not the zsh binary itself.

**Always nix** is everything else. These packages benefit from cross-platform version consistency (same git version on macOS Sonoma and Ubuntu 22.04), atomic upgrades via `nx upgrade`, and user-scope installation without root. The flake output is deterministic per platform - same scopes produce the same packages.

**How the tiers interact at runtime:**

```text
linux_setup.sh / wsl_setup.ps1 (requires root)
  ├── sudo install_base.sh          # system-only tier
  ├── sudo install_nix.sh           # one-time nix bootstrap
  ├── sudo install_pwsh.sh          # system-prefer: pwsh on Linux
  ├── sudo install_zsh.sh           # system-prefer: zsh on Linux
  └── nix/setup.sh --pwsh --zsh ... # always-nix tier
        └── phase_scopes_skip_system_prefer()
              ├── pwsh exists at /usr/bin/pwsh → skip nix pwsh scope
              └── zsh exists at /usr/bin/zsh  → skip nix zsh scope

nix/setup.sh on macOS (no root available)
  └── phase_scopes_skip_system_prefer()
        └── uname == Darwin → skip all checks, nix provides everything
```

The callers (`linux_setup.sh`, `wsl_setup.ps1`) handle the system-wide installs with `sudo`. They pass all scope flags through to `nix/setup.sh`, which decides whether to install or skip the nix scope based on platform detection. This keeps the decision centralized - a new entry point does not need to know which scopes are system-prefer.

### Why unfree packages are opt-in, not default

**The objection:** "Nix already has `allowUnfree`. Just set it to `true` globally and stop worrying about it."

Setting `allowUnfree = true` silently permits installation of proprietary-licensed packages. For a tool targeting enterprise adoption, this creates three concrete risks:

1. **License compliance exposure.** Enterprise software policies typically require explicit approval before deploying proprietary-licensed binaries. A tool that silently permits unfree packages shifts the compliance burden to the user - who may not realize a package is proprietary until an audit flags it.

2. **Binary cache misses.** Unfree packages are excluded from the public NixOS binary cache. Every unfree package must be built from source on the user's machine, adding minutes to setup and upgrade times. Users experience degraded performance without understanding why.

3. **Reproducibility gap.** Some unfree packages have license-restricted source that cannot be redistributed. If a nixpkgs commit removes or restricts an unfree package, pinned flake revisions may fail to build, breaking the reproducibility guarantee that justifies using Nix in the first place.

The default scope set contains **zero unfree packages**. Terraform - the most common unfree package in developer environments - is handled via `tfswitch` (MIT-licensed), which downloads the terraform binary to `~/.local/bin` outside the nix store. This provides the same end result (terraform available in PATH) without requiring unfree in the flake.

The `--allow-unfree` flag exists for justified use cases:

- **`nx install <pkg>`** lets users add ad-hoc packages to `packages.nix`. Some of these (e.g., `vault`, `1password-cli`) are unfree. Without the flag, nix rejects them with a cryptic evaluation error. The flag makes the opt-in explicit and the error message actionable.
- **Team overlays** may include proprietary tooling specific to a team's stack. Blocking unfree at the flake level would force teams to maintain a separate flake fork rather than extending the standard one.
- **Enterprise contexts** where proprietary packages have been explicitly approved by legal or procurement.

The flag is **sticky** - once set, it persists in `config.nix` across reruns. This means a team lead can set `--allow-unfree` once and all subsequent `nx upgrade` invocations preserve the setting without repeating the flag. The value is readable in `config.nix` (`allowUnfree = true;`) for audit visibility.

The design follows the principle of least surprise for enterprise environments: the default is restrictive, the override is explicit and auditable, and the mechanism is the same `config.nix` persistence used for all other configuration.

## Implementation decisions

### Why nixpkgs-unstable, not a stable channel

**The objection:** "The word 'unstable' is right there in the name. Use a stable release for production tooling."

The name is misleading. `nixpkgs-unstable` is not raw `main` - every commit is validated by Hydra (NixOS's CI system) through build tests before being promoted to the channel. It is a rolling release with quality gates, not a bleeding-edge feed. Compared to Arch Linux (daily builds, minimal testing) or Fedora Rawhide (nightly composes), nixpkgs-unstable is more conservative - updates land days after upstream release, not hours.

Stable nixpkgs channels (e.g., `nixos-24.11`) exist but serve a different purpose: they hold back major version updates and apply only security and critical bug fixes. For developer workstations, this creates a maintenance problem. Developers expect reasonably current versions of kubectl, terraform, ripgrep, and Node.js - not versions frozen six months ago. A stable channel means either accepting outdated tools or manually overriding package versions, which defeats the purpose of a curated package set.

Using `nixpkgs-unstable` eliminates this version chasing entirely. The channel tracks upstream releases through a validated pipeline of 120,000+ packages, so `nx upgrade` pulls current, CI-tested versions without per-package version management. The trade-off is explicit: upgrades are never automatic. `nix/setup.sh` without `--upgrade` re-applies configuration using existing package versions. `nx upgrade` is the deliberate action that pulls new versions, and `nx rollback` reverts if something breaks.

For teams that need coordinated versions, `nx pin set` locks the entire nixpkgs input to a specific commit SHA. Everyone on the team resolves the same package versions until the pin is updated. This provides reproducibility without the staleness of a stable channel - the team controls when to advance, and the pin is a single value rather than per-package version overrides.

**The supply-chain objection:** "But what about poisoned nixpkgs commits? Ship a pinned rev by default and require `--unstable` to opt out."

A repo-maintained default pin was considered and rejected. The supply-chain concern is real but the mitigation creates more problems than it solves:

- **Hydra is the quality gate.** Every nixpkgs commit builds ~120,000 packages across platforms before promotion to the unstable channel. A targeted supply-chain attack would need to survive that CI pipeline undetected. The canonical recent attack (xz-utils, 2024) compromised upstream source tarballs, not nixpkgs itself - pinning nixpkgs to an older rev would not have prevented it, because the compromised tarball was what nixpkgs fetched regardless of revision.
- **Stale pins cause real user pain.** A 3-week-old pin means `nx install <pkg>` fails when the package was added or fixed after the pin date. Users file issues, get told to unpin, and the default becomes a support burden rather than a safety net.
- **It contradicts `nx upgrade`.** The upgrade story is "pull current versions deliberately." A default pin means `nx upgrade` upgrades to... the same stale pin. Separating "upgrade packages" from "advance the pin" creates two upgrade concepts where one existed before.
- **Maintenance cost is ongoing.** Monthly scheduled PRs to bump the pin require running the full scope matrix (all scopes, Linux + macOS) against the candidate rev. That CI cost recurs indefinitely, and every upstream release blocks users until the bump merges.

The existing `nx pin set` mechanism serves the users who actually need coordinated versions - team leads pin a rev, distribute it via overlay, and advance it on their schedule. Making pinning the default for solo developers who benefit from current packages solves a problem they don't have while creating one they will notice.

### Why bash 3.2 compatibility

**The objection:** "It's 2026. Just require bash 5 and use modern features."

macOS ships bash 3.2 as the system default. Apple will not update it due to GPLv3 licensing. This creates a bootstrapping paradox: **the tool that sets up your environment cannot require you to already have a setup environment.**

If the setup script required bash 5, users would need to install it first - via Homebrew, Nix, or manual compilation. That prerequisite defeats the purpose of a one-command setup tool. The script must work with what the operating system provides out of the box.

The constraint is real and affects daily development:

- No `mapfile` or `readarray` - use `while IFS= read -r` loops
- No associative arrays (`declare -A`) - use space-delimited strings with helper functions
- No case modification (`${var,,}`) - use `tr`
- No namerefs (`declare -n`) - pass variable names as strings
- BSD `sed` and `grep` - no GNU extensions (`\s`, `\w`, `-P`, `-r`)

This is not enforced by convention. A custom pre-commit hook (`check_bash32.py`) scans every nix-path file for bash 4+ constructs and blocks the commit if any are found. The macOS CI workflow validates the constraint on every pull request by running the full setup on a macOS runner with the system bash.

Linux-only scripts (provisioning, system checks) use bash 5 features freely - the constraint applies only to files that run on macOS.

### Why oh-my-posh and starship, not oh-my-zsh

**The objection:** "Oh-my-zsh works great for me - it has hundreds of themes and plugins."

Oh-my-zsh is a zsh framework. That is exactly the problem:

| Capability          | oh-my-zsh          | oh-my-posh / starship                    |
| ------------------- | ------------------ | ---------------------------------------- |
| Shell support       | zsh only           | bash, zsh, PowerShell, fish, cmd, nu     |
| Platform parity     | Requires zsh setup | Works on any shell the platform ships    |
| Startup performance | Plugin-dependent   | Single binary, sub-50ms prompt render    |
| Configuration       | ~/.zshrc framework | Standalone config file, no shell lock-in |

A cross-platform tool that standardizes the developer experience cannot anchor its prompt to a single shell. Developers on this tool use bash on Coder, zsh on macOS, and PowerShell on Windows - often all three in the same week. Oh-my-posh and starship render an identical prompt across all of them from a single theme file.

Both engines are offered as opt-in scopes rather than forcing one choice:

- **oh-my-posh** (Go, mature ecosystem, rich themes) - default recommendation for macOS and WSL where startup latency is less critical
- **starship** (Rust, faster cold-start) - preferred on Coder where container startup time matters and resource budgets are tighter

The scopes are mutually exclusive at runtime (`--omp-theme` removes starship and vice versa) but both remain available. This lets teams standardize on a prompt engine while respecting environment-specific trade-offs.

### Why managed blocks, not append-style profile injection

**The objection:** "Just append a line to `.bashrc` - it's simpler."

The `grep -q 'pattern' || echo 'line' >> ~/.bashrc` pattern is the most common approach to shell profile configuration. It is also the most fragile:

- Running setup twice appends duplicate entries unless the grep is perfectly maintained
- Removing configuration requires manual editing or fragile `sed` deletion
- Uninstallation leaves orphaned lines that can cause errors after the tool is removed
- There is no way to update configuration in place - only append more

This tool uses a **managed block** pattern instead. Configuration is written between sentinel markers (`# >>> nix-env managed >>>` / `# <<< nix-env managed <<<`) and fully regenerated on each run:

- **Idempotent** - running setup any number of times produces identical results, validated by CI on every PR
- **Updatable** - the block is replaced atomically, not appended to
- **Removable** - `nix/uninstall.sh` deletes the block cleanly, leaving the rest of the profile intact
- **Diagnosable** - `nx doctor` detects duplicate or missing blocks

The same pattern is implemented for PowerShell via `#region`/`#endregion` markers and `Update-ProfileRegion`. Two block types separate nix-specific config (removed on uninstall) from generic config (certs, local PATH - preserved after uninstall).

### Why phase-based orchestration with side-effect stubs

**The objection:** "It's a setup script - just write it top to bottom."

A 600-line bash script written top-to-bottom is untestable by definition. Functions cannot be sourced in isolation, side effects execute on import, and tests resort to brittle `sed` extraction to test individual functions.

This tool uses a **phase library** architecture: `nix/setup.sh` is a slim ~110-line orchestrator that sources independent phase files from `nix/lib/phases/`. Each phase exports functions with documented inputs and outputs (`# Reads:` / `# Writes:` header comments). Side-effecting operations (nix commands, curl probes, external script invocations) are routed through thin wrappers in `nix/lib/io.sh`:

```bash
_io_nix()        { nix "$@"; }
_io_curl_probe() { curl -sS "$1" >/dev/null 2>&1; }
_io_run()        { "$@"; }
```

Tests override these wrappers by function redefinition before sourcing the phase under test - three lines per test, zero framework overhead:

```bash
setup() {
  _io_nix() { echo "nix $*" >>"$BATS_TEST_TMPDIR/nix.log"; }
  source "$REPO_ROOT/nix/lib/io.sh"
  source "$REPO_ROOT/nix/lib/phases/nix_profile.sh"
}
```

This pattern makes bash scripts testable at a level normally associated with compiled languages - without mocking frameworks, without PATH manipulation, without subprocess overhead. It is the reason this project has 412 test cases across 22 test files for what is, at its core, a shell script.

### Why JSON as the shared schema format

**The objection:** "Bash scripts should use bash-native data formats."

Scope metadata (valid names, install order, dependency rules) lives in a single `scopes.json` consumed by three runtimes:

| Consumer   | Parser             |
| ---------- | ------------------ |
| bash       | `jq`               |
| PowerShell | `ConvertFrom-Json` |
| Python     | `json` stdlib      |

JSON is the only format all three parse natively without a custom parser. Alternatives (bash-sourceable data, TSV, INI) would force either a fragile parallel parser in PowerShell/Python or a source-of-truth split between bash-data and JSON-data. A single source of truth means scope definitions are always consistent across `nix/setup.sh`, `wsl/wsl_setup.ps1`, and the `validate_scopes.py` pre-commit hook.

The only cost is that bash 3.2 on a bare macOS has no JSON parser, so `jq` must be bootstrapped before scope resolution can run. This is handled by a minimal `base_init.nix` scope (~13 lines) that installs `jq` on first run and is skipped on all subsequent runs - a bounded, one-time cost for a permanent architectural benefit.

### Why not checksum-pin the Nix installer

**The objection:** "Piping `curl | sh` is insecure. Download the installer, verify a SHA-256 checksum against a known-good value, then execute."

This sounds like a clear security improvement. On closer inspection, it creates maintenance burden without meaningful security gain.

**Determinate Systems does not publish checksums or signatures.** Their GitHub releases (as of April 2025) contain bare binaries - no `.sha256` files, no cosign bundles, no GPG signatures. To implement checksum verification, you would compute a hash yourself after downloading the installer once, then pin *that* hash. The initial "known-good" download trusts the same HTTPS channel as every subsequent download. You have not added a trust root - you have frozen a moment in time.

**The shell script is not the installer.** The 19KB script downloaded from `install.determinate.systems` is a thin platform-detecting wrapper. It downloads a ~15MB static `nix-installer` binary per architecture at runtime. Vendoring or verifying the shell script does not pin the binary it fetches. To actually pin the installer, you would need to vendor all three platform binaries (~45MB total: `x86_64-linux`, `aarch64-linux`, `aarch64-darwin`), turning the repo into a fork of Determinate's distribution channel.

**Maintenance cost equals vendoring.** A pinned checksum requires a scheduled GitHub Action to detect new installer releases, compute new hashes, and open a PR. Every upstream release blocks users until someone merges the hash bump. That is the same operational cost as vendoring the binaries - except vendoring would also provide offline installation.

**The real security is already in place.** Both call sites enforce TLS 1.2+ via `curl --proto '=https' --tlsv1.2` (TLS 1.2 minimum). The installer script itself pins a tagged binary version internally (`NIX_INSTALLER_BINARY_ROOT` points to a specific release URL, e.g., `v3.18.1`). The threat model where HTTPS is compromised but a repo-pinned hash saves you is a CDN compromise at `install.determinate.systems` - at which point the attacker likely controls the next release hash too.

**Both call sites already skip when Nix is installed.** `bootstrap.sh:phase_bootstrap_detect_nix()` and `install_nix.sh` check for existing Nix installations before touching the network. The installer runs once per machine, not on every setup invocation.

**The enterprise answer is pre-installation, not verifying.** Organizations with strict supply-chain requirements should pre-install Nix via their approved channel - MDM (Jamf/Intune via [Determinate's enterprise offering](https://determinate.systems/nix/macos/mdm/)), internal package repository, or manual installation. All entry points detect existing installations and skip the download. This is documented in the setup help and proxy documentation.

The `curl | sh` pattern is an accepted trade-off for a bootstrapper: it runs once, over enforced HTTPS, with a version-pinned payload, and is skipped entirely when Nix already exists. Adding checksum verification would create ongoing maintenance for a one-time operation that already has reasonable protections.

### Why bash end-to-end, not "bootstrap in bash, implement in Python"

**The objection:** "Bash was chosen because it's available everywhere, but the project has grown beyond what bash is suited for. Rewrite the logic layer in Python (or Go, or Rust) and keep bash only for the minimal bootstrap."

The instinct is reasonable - bash is not a general-purpose programming language, and most projects that reach ~30 shell files and 400+ test cases have outgrown it. This project has not, because it solved the scalability problems that normally force a rewrite.

**The codebase already has the structural properties of a well-engineered typed codebase.**

- **Testability.** The phase library architecture with `_io_*` side-effect stubs gives function-level unit testing without mocking frameworks. Tests override wrappers by function redefinition before sourcing the phase under test - three lines per test, zero framework overhead. The result is 400+ test cases across 22 test files, with coverage of phase functions, scope resolution, profile block management, and CLI commands. This level of testing is not typical bash; it is typical of a well-engineered project in any language.
- **Documented interfaces.** Each phase file has `# Reads:` / `# Writes:` header comments that document cross-phase data flow. The variable naming convention (`_IR_*` for install record, `_io_*` for wrappers, `phase_*` for public functions, `_<name>_*` for private helpers) makes ownership visible at a glance - the same information that module boundaries and type signatures provide in other languages.
- **Mechanical constraint enforcement.** The bash 3.2 compatibility constraint is enforced by a pre-commit hook (`check_bash32.py`) that scans every nix-path file for bash 4+ constructs. ShellCheck runs on every commit. The macOS CI workflow validates the constraint end-to-end. These are not conventions that drift - they are gates that block.

**A rewrite would be a lateral move, not an improvement.** Bash has well-known limitations (weak data structures, no type system, verbose complex logic), but replacing it with Python introduces a different set of problems specific to this context:

- **Runtime availability.** macOS no longer ships Python. Bare containers may lack it. The tool cannot assume Python exists on a fresh machine - the same bootstrapping paradox that justifies bash 3.2 compatibility.
- **Version skew.** Target platforms span Python 3.8 to 3.12+. Managing Python version compatibility for a tool whose purpose is solving version management is circular.
- **Dependency management for the tool itself.** A Python implementation needs either vendored dependencies, a `requirements.txt` with a virtualenv, or a `pyproject.toml` with a build step. Each option adds distribution complexity to a tool that currently requires zero installation beyond cloning.
- **Shell startup penalty.** `nx` is currently a shell function with zero overhead - it's sourced into the user's shell on login. A Python CLI adds interpreter startup cost (~50-100ms) to every invocation, noticeable on commands like `nx scope list` or tab completions.

The bootstrapping paradox is the decisive factor. The same argument that justifies bash 3.2 compatibility (macOS ships it, the tool cannot assume anything else exists) applies to the entire runtime. After setup, `nx upgrade`, `nx doctor`, `nx scope`, and `nx profile regenerate` all work with nothing but bash and the nix-installed tools. Adding a Python dependency to the runtime means users need Python installed to manage their environment - the same circular dependency the project already solved for `jq` via `base_init.nix`, except `jq` is a 5MB static binary and Python is an ecosystem.

**The right trigger for partial extraction.** The architecture is at roughly the right size ceiling for bash. If the project were to grow into dependency graph solving with conflict resolution, network-heavy operations with retry/backoff logic, or structured API clients, those specific capabilities would benefit from extraction into a compiled single-binary tool (Go or Rust, distributed via the nix flake). The key word is *extraction* - the orchestrator and CLI would remain bash, and the compiled tool would be called via `_io_run` like any other side effect. This preserves the zero-dependency property while offloading genuinely complex logic to a language suited for it.

Nothing in the current scope calls for that extraction. The complexity ceiling has not been reached - it has been managed.
