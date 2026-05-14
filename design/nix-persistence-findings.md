# Nix Configuration Persistence Failure — Investigation Findings

**Date:** 2026-05-14  
**Workspace:** `szymonos-nix` (Coder, Ubuntu 24.04, 4 CPU / 12 GB RAM / 32 GB home disk)

---

## Executive Summary

The Coder workspace image **bakes a pre-built nix profile** into the `/nix` mount. On workspace upgrade (new image), the entire `/nix/store` is **wiped and re-populated from the new image**. The baked profile was built from an **older state** of `~/.config/nix-env/` that predates several scope additions. Result: 10 scope binaries are missing from the nix profile despite `config.nix` correctly listing all 7 scopes.

---

## Filesystem Layout (Critical Context)

```
/dev/sdc (32GB ext4, persistent) mounted at:
  ├── /home/coder          ← user data, persists across rebuilds
  ├── /nix                 ← nix store, WIPED on image upgrade, repopulated from image
  ├── /var/lib/coder/docker
  └── /var/lib/coder/containers

overlay (container image, ephemeral):
  └── /etc/nix/            ← nix.conf + profile-root (baked into image)
```

**Key insight:** `/nix` and `/home/coder` share the same physical disk (`/dev/sdc`), but `/nix` is **completely repopulated from the container image on every workspace start**. All 3,602 store paths have birth time `2026-05-14 06:46` (today's workspace start). The persistent home disk retains the nix *configuration* but not the nix *store*.

---

## What Survived (persistent home disk)

| Artifact | Path | Status |
|----------|------|--------|
| Nix env config | `~/.config/nix-env/config.nix` | ✅ 7 scopes declared |
| Flake + lock | `~/.config/nix-env/flake.{nix,lock}` | ✅ Intact |
| Scope .nix files | `~/.config/nix-env/scopes/*.nix` | ✅ All 18 files |
| nx CLI libraries | `~/.config/nix-env/nx*.sh` | ✅ Intact |
| Shell RC blocks | `~/.bashrc`, `~/.zshrc` | ✅ Present (but stale/duplicated) |
| Profile manifest | `~/.local/state/nix/profiles/` | ⚠️ Exists but points to wrong store path |
| OMP theme | `~/.config/nix-env/omp/` | ✅ Intact |

## What Was Lost

| Artifact | Evidence |
|----------|----------|
| Full dev-env (gen 36, all scopes) | Store path `360k0abs...` → **INVALID** (not in DB) |
| GC roots for user profile | `/nix/var/nix/gcroots/auto/` has NO profile link |
| Profile history/rollback | Only current generation exists |

---

## Root Cause Analysis

### Timeline

| Time | Event |
|------|-------|
| May 12 13:03 | `flake.lock` pinned (last nixpkgs rev) |
| May 13 12:48 | `config.nix` updated with 7 scopes |
| May 13 12:49 | `nix profile upgrade` → generation 36 (full dev-env, all scope packages) |
| **May 13 14:49** | **Coder image built** — bakes `/nix/store` + `/etc/nix/profile-root` into image |
| **May 14 06:45** | **Workspace rebuilt from new image** |
| 06:45:53 | `/etc/nix/profile-root` unpacked from image (points to `41zzqnq3...profile`) |
| 06:46:16–32 | `/nix/store` populated from image layer (3,602 paths, 1.9 GB) |
| 06:46:32 | `/nix/.coder-bootstrap-complete` marker created |

### The Failure Mechanism

```
┌─────────────────────────────────────────────────────────────────────┐
│  CODER IMAGE BUILD (May 13 ~14:49)                                  │
│                                                                     │
│  Image builds nix profile from ~/.config/nix-env/ at that moment.   │
│  BUT: the profile baked into the image was built from an OLDER      │
│  config.nix state (before all scopes were added/resolved).          │
│  Missing: k8s_base, az, terraform, oh_my_posh packages              │
│                                                                     │
│  Baked store path: ml1l1rj3x2kzj2ij9r68ibrfg960i0fj-dev-env       │
│  Contains: 234 binaries (base + shell + python + gcloud only)       │
└─────────────────────────────────────────────────────────────────────┘
                                    │
                                    ▼
┌─────────────────────────────────────────────────────────────────────┐
│  USER RUNS `nix profile upgrade` (May 13 12:49)                     │
│                                                                     │
│  Adds all scope packages → new generation 36                        │
│  Store path: 360k0absdn62gbvxv893kwh3ai29cb1f-profile               │
│  This is the CORRECT, full dev-env                                  │
└─────────────────────────────────────────────────────────────────────┘
                                    │
                                    ▼
┌─────────────────────────────────────────────────────────────────────┐
│  WORKSPACE UPGRADE (May 14 06:45)                                   │
│                                                                     │
│  1. New image deployed                                              │
│  2. /nix WIPED and repopulated from image                           │
│  3. Image's baked profile (incomplete) becomes active               │
│  4. User's generation 36 store paths are GONE                       │
│  5. ~/.config/nix-env/config.nix still has 7 scopes (persisted)     │
│  6. Profile manifest still references the incomplete build          │
│                                                                     │
│  Result: config says 7 scopes, but profile only has base packages   │
└─────────────────────────────────────────────────────────────────────┘
```

### Additional Issues Found

1. **No GC root for user profile.** `/nix/var/nix/gcroots/auto/` has no symlink to `~/.local/state/nix/profiles/profile`. Even if the store were persistent, a GC would collect the user's packages.

2. **Stale profile-36-link.** `~/.local/state/nix/profiles/profile-36-link` still exists on the persistent disk but points to a store path that's no longer valid. Future `nix profile rollback` will fail.

3. **Duplicate managed blocks in `.bashrc`.** Lines 34–71 (`# >>> nix:managed >>>`) AND lines 89–116 (`# >>> nix-env managed >>>`). Two blocks with slightly different markers.

---

## Current State

### `nx doctor` Output

```
PASS  nix_available
PASS  flake_lock
PASS  env_dir_files
PASS  install_record
WARN  scope_binaries: missing: k8s_base/k9s, kubecolor, kubectx, kubens; az/azcopy;
                               terraform/tfswitch, tflint; oh_my_posh/oh-my-posh
FAIL  scope_bins_in_profile: 10 binaries not in ~/.nix-profile/bin
FAIL  shell_profile: 2 duplicate blocks in .bashrc
FAIL  managed_block_drift: managed blocks differ from regenerated content

9 passed, 1 warning, 3 failed
```

### Tools: Expected vs Actual

| Tool | Expected (nix scope) | Actual Source | Status |
|------|---------------------|---------------|--------|
| rg, eza, bat, fzf, git, uv | shell/python | nix profile | ✅ Working |
| kubectl | k8s_base | `/usr/local/bin` (system fallback) | ⚠️ |
| terraform | terraform | `~/.local/bin` (tfswitch) | ⚠️ |
| az | az | `~/.local/bin` (uv-installed) | ⚠️ |
| gcloud | gcloud | `~/google-cloud-sdk/bin` | ⚠️ |
| oh-my-posh | oh_my_posh | — | ❌ Missing entirely |
| k9s, kubecolor, kubectx, kubens | k8s_base | — | ❌ Missing entirely |
| tfswitch, tflint | terraform | — | ❌ Missing entirely |
| azcopy | az | — | ❌ Missing entirely |

---

## Immediate Fix (Run Now)

```bash
# 1. Rebuild dev-env from current config.nix (downloads ~125 MB, unpacks ~564 MB)
nix profile upgrade nix-env

# 2. Fix duplicate/stale managed blocks in .bashrc
~/.config/nix-env/nx.sh profile regenerate
```

---

## Instructions for Coder Template Maintainers

### Problem Statement

The Coder template bakes a nix profile into the workspace image at image-build time. When users add scopes after the image is built (via `nix/setup.sh --<scope>` or `nx scope add`), those additions are stored in `~/.config/nix-env/config.nix` (persistent home disk). On the next workspace rebuild, the image's **stale** baked profile overwrites the user's profile, losing all scope-specific packages.

### Root Cause

The `/nix` mount is repopulated from the container image on every workspace start. The image contains a pre-built nix profile with a fixed set of packages. Any user-side `nix profile upgrade` results (stored in `/nix/store`) are lost when the image is replaced.

### Recommended Fix: Post-Start Profile Rebuild

Add the following to the workspace startup script (or `coder_agent` startup block), **after** the nix bootstrap completes:

```bash
# Rebuild nix profile from user's durable config if it exists and differs from image
if [ -f "$HOME/.config/nix-env/config.nix" ] && command -v nix >/dev/null 2>&1; then
  # Check if current profile matches what config.nix declares
  current_drv=$(nix eval --quiet path:"$HOME/.config/nix-env"#packages.x86_64-linux.default.drvPath 2>/dev/null || true)
  installed_paths=$(nix profile list --json 2>/dev/null | jq -r '.elements["nix-env"].storePaths[0] // empty')
  
  if [ -n "$current_drv" ] && [ -n "$installed_paths" ]; then
    expected_out=$(nix-store -q --outputs "$current_drv" 2>/dev/null || true)
    if [ "$expected_out" != "$installed_paths" ]; then
      echo "Nix profile out of date — rebuilding from ~/.config/nix-env/config.nix..."
      nix profile upgrade nix-env 2>&1 | tail -5
    fi
  fi
fi
```

### Alternative Fix: Persistent `/nix/store`

Instead of repopulating `/nix` from the image on every start, **preserve** the user's nix store across rebuilds:

1. **Don't wipe `/nix` on workspace start.** Since it's already on the persistent `/dev/sdc` volume, simply stop overwriting it with image contents when the user already has a valid nix installation.

2. **Use a sentinel file** (e.g., `/nix/.user-managed`) to skip image-layer copy:

```bash
# In the Coder template's nix bootstrap:
if [ -f /nix/.user-managed ] && [ -f /nix/var/nix/db/db.sqlite ]; then
  echo "Nix store preserved from previous session"
  touch /nix/.coder-bootstrap-complete
  exit 0
fi

# ... existing bootstrap logic ...
touch /nix/.user-managed
```

3. **Register the profile as a GC root** (the image currently doesn't do this):

```bash
# After profile install/upgrade, ensure the profile is a GC root
nix-store --add-root /nix/var/nix/gcroots/auto/user-profile \
  --indirect --realise ~/.local/state/nix/profiles/profile
```

### Why This Matters

| Approach | Cold-start cost | Scope drift risk | Rollback support |
|----------|----------------|------------------|------------------|
| Current (image bake only) | 0 min | **HIGH** — always reverts to image state | ❌ Lost |
| Post-start rebuild | 2–5 min | None — rebuilds from user config | ❌ Still lost |
| Persistent store | 0 min | None — store survives | ✅ Preserved |

**Recommendation:** Persistent store (option 2) is the correct fix. The image-baked profile serves as a fallback for first-time users; returning users keep their customized store intact.
