# Review history

<!-- arch-drift: record -->

Written by `.claude/skills/review/scripts/review.py finish`; read by its `status` and `prepare` verbs. One row per standing review in **Runs**, follow-ups one shard handed to another in **Open follow-ups**, and every finding's decision under **Decision logs**. Do not edit the tables by hand: a follow-up that no longer applies is closed as `resolve-only` in its shard's next run.

Before the shards were re-split in October 2026, four of the nine original shards had one review each: `test-quality` and `nx-cli` (2026-05-09), `certs` (2026-05-13) and `orchestration` (2026-05-24). Their fixes shipped in 1.7.1, 1.7.2 and 1.10.0. No current shard has been reviewed against its new charter yet.

## Runs

| Date | Shard | Charter | Found | Fixed | Declined | Escalated | Handed off | Branch |
| ---- | ----- | ------- | ----- | ----- | -------- | --------- | ---------- | ------ |

## Open follow-ups

| ID     | For   | Where                                    | Finding                                                                                                                                                                                                                                                                                      | From             |
| ------ | ----- | ---------------------------------------- | -------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------- | ---------------- |
| FU-001 | certs | .assets/setup/setup_profile_user.ps1:317 | Static `#region certs` / `ca-bundle` / `gcloud-certs` blocks are added once, gated on a substring check, and go stale when a tool is added or the bundle moves. The managed `nix:certs` region in `_aliases_nix.ps1` now exports the same variables: drop the static blocks or convert them. | certs 2026-05-13 |

## Decision logs
