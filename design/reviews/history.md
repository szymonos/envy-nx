# Review history

<!-- arch-drift: record -->

Written by `.claude/skills/review/scripts/review.py finish`; read by its `status` and `prepare` verbs. One row per standing review in **Runs**, follow-ups one shard handed to another in **Open follow-ups**, and every finding's decision under **Decision logs**. Do not edit the tables by hand: a follow-up that no longer applies is closed as `resolve-only` in its shard's next run.

Before the shards were re-split in October 2026, four of the nine original shards had one review each: `test-quality` and `nx-cli` (2026-05-09), `certs` (2026-05-13) and `orchestration` (2026-05-24). Their fixes shipped in 1.7.1, 1.7.2 and 1.10.0. No current shard has been reviewed against its new charter yet.

## Runs

| Date       | Shard | Charter  | Found | Fixed | Declined | Escalated | Handed off | Branch                  |
| ---------- | ----- | -------- | ----- | ----- | -------- | --------- | ---------- | ----------------------- |
| 2026-10-25 | certs | 6e671204 | 39    | 28    | 8        | 4         | 0          | review/certs-2026-10-25 |

## Open follow-ups

| ID | For | Where | Finding | From |
| -- | --- | ----- | ------- | ---- |

## Decision logs

### 2026-10-25 certs

| ID     | Where                                    | Finding                                                | Call     | Owner | Why                                                                                                                              |
| ------ | ---------------------------------------- | ------------------------------------------------------ | -------- | ----- | -------------------------------------------------------------------------------------------------------------------------------- |
| R-001  | .assets/lib/certs.sh:78                  | Linux ca-bundle.crt never includes ca-custom.crt       | escalate | certs | changes what the Linux trust store contains (symlink to merged file); rootless MITM users depend on it                           |
| F-001  | .assets/lib/certs.sh:78                  | Linux bundle ignores ca-custom.crt                     | escalate | certs | same root cause as R-001                                                                                                         |
| F-010  | .assets/lib/certs.sh:78                  | Linux builder ignores merged local certs               | escalate | certs | same root cause as R-001                                                                                                         |
| F-027  | .assets/lib/certs.sh:78                  | collected custom CAs never reach full-bundle consumers | escalate | certs | same root cause as R-001                                                                                                         |
| R-002  | .assets/lib/certs.sh:74                  | openSUSE /etc/ssl/ca-bundle.pem never probed           | fix      | certs | no bundle and no warning on a supported distro; WSL list too                                                                     |
| F-008  | .assets/lib/certs.sh:77                  | empty system bundle accepted                           | fix      | certs | -f to -s, so an empty file is never linked as the trust store                                                                    |
| F-024  | .assets/lib/certs.sh:77                  | empty system bundle linked with success                | fix      | certs | same root cause as F-008                                                                                                         |
| R-003  | .assets/lib/certs.sh:274                 | zsh prints cert_intercept loop locals to stdout        | fix      | certs | reproduced with zsh -fc; locals hoisted to function top                                                                          |
| R-004  | wsl/wsl_certs_add.ps1:158                | wsl.exe exit codes unchecked                           | fix      | certs | REVIEW.md LASTEXITCODE rule; warnings on install, merge and link                                                                 |
| F-006  | wsl/wsl_certs_add.ps1:158                | native WSL exit codes ignored                          | fix      | certs | same root cause as R-004                                                                                                         |
| F-011  | wsl/wsl_certs_add.ps1:178                | unchecked WSL exits and cd then ln on failure          | fix      | certs | same root cause as R-004; cd now exits on failure                                                                                |
| R-005  | .assets/lib/certs.sh:60                  | build_ca_bundle has no real test                       | fix      | certs | charter rule; Darwin branch tests for rebuild, idempotency and failed exports                                                    |
| R-006  | .assets/setup/setup_profile_user.ps1:317 | static cert blocks are dead code                       | fix      | certs | carried FU-001; writer removed, ARCHITECTURE.md updated                                                                          |
| F-026  | .assets/setup/setup_profile_user.ps1:317 | FU-001 unresolved                                      | fix      | certs | same root cause as R-006                                                                                                         |
| FU-001 | .assets/setup/setup_profile_user.ps1:317 | static cert blocks                                     | fix      | certs | nix:certs is written first so the substring gates never fire; dead writer removed                                                |
| R-007  | wsl/wsl_certs_add.ps1:175                | dead ok shim with wrong comment                        | fix      | certs | certs.sh defines its own fallback ok                                                                                             |
| R-008  | .assets/lib/certs.sh:35                  | stale header-format and header-dedup comments          | fix      | certs | wrong doc; WSL goes through merge_local_certs and dedup reads PEM serials                                                        |
| R-009  | .assets/lib/certs.sh:28                  | history-only comments and dead test helper             | fix      | certs | CLAUDE.md comment rule; unused _fp_of removed                                                                                    |
| F-002  | .assets/lib/certs.sh:92                  | Keychain export failure replaces bundle with partial   | fix      | certs | verified an empty keychain exits 0, so a non-zero exit is a real failure; prior bundle kept                                      |
| F-013  | .assets/lib/certs.sh:92                  | one failed Keychain export still publishes             | fix      | certs | same root cause as F-002                                                                                                         |
| F-003  | .assets/lib/certs.sh:101                 | rm of symlink before mv breaks atomicity               | decline  | certs | the rm only fires once on a legacy symlink; TMPDIR shares the APFS data volume with HOME                                         |
| F-012  | .assets/lib/certs.sh:86                  | macOS rebuild not reliably atomic                      | decline  | certs | same reason as F-003                                                                                                             |
| F-004  | .assets/lib/certs.sh:185                 | unreadable cert aborts setup under set -e              | fix      | certs | pipeline guarded; strict-mode bats test added                                                                                    |
| F-018  | .assets/lib/certs.sh:185                 | unreadable cert skip dead under pipefail               | fix      | certs | same root cause as F-004                                                                                                         |
| F-005  | .assets/fix/fix_gcloud_certs.sh:10       | fixers miss _emit_cert_header on fresh home            | fix      | certs | fixers now source repo certs.sh before functions.sh                                                                              |
| F-022  | .assets/fix/fix_gcloud_certs.sh:10       | fixers append certs without headers                    | fix      | certs | same root cause as F-005                                                                                                         |
| F-028  | .assets/fix/fix_gcloud_certs.sh:10       | fixers depend on deployed certs.sh                     | fix      | certs | same root cause as F-005                                                                                                         |
| F-007  | .assets/lib/certs.sh:227                 | probe URL path breaks interception                     | fix      | certs | scheme and path stripped per URI like the probe; explicit ports left out, no user sets one                                       |
| F-023  | .assets/lib/certs.sh:247                 | interception does not parse URL                        | fix      | certs | same root cause as F-007                                                                                                         |
| F-030  | .assets/lib/certs.sh:227                 | probe and interception parse URL differently           | fix      | certs | same root cause as F-007                                                                                                         |
| F-009  | .assets/lib/cert_probe.sh:36             | -CAfile still loads default CA dir                     | fix      | certs | comment claimed SSL_CERT_DIR is ignored; corrected - flag change not taken, PATH may resolve LibreSSL                            |
| F-014  | .assets/lib/certs.sh:102                 | directory at ca-bundle.crt                             | decline  | certs | planted path in the tool's own directory; now a charter rule                                                                     |
| F-015  | .assets/lib/certs.sh:196                 | append without trailing newline                        | decline  | certs | every writer ends PEM with a newline; charter rule                                                                               |
| F-016  | .assets/lib/certs.sh:95                  | ca-custom.crt aliasing ca-bundle.crt                   | decline  | certs | contrived symlink; charter rule                                                                                                  |
| F-017  | .assets/lib/certs.sh:196                 | failed append still counted                            | decline  | certs | only with a directory planted at ca-custom.crt; charter rule                                                                     |
| F-019  | .assets/lib/certs.sh:43                  | xargs dies on an apostrophe in a DN                    | fix      | certs | real corporate DNs carry apostrophes; sed prefix instead of xargs                                                                |
| F-020  | .assets/lib/certs.sh:195                 | multi-cert .crt imports only the first                 | fix      | certs | chain files are a common corporate CA format; bash and WSL paths                                                                 |
| F-021  | .assets/lib/certs.sh:200                 | symlinked source dir imports nothing                   | decline  | certs | .assets/certs is a repo directory nobody symlinks                                                                                |
| F-025  | .assets/lib/cert_probe.sh:37             | -servername without hostname verification              | decline  | certs | MITM detection asks only whether the chain verifies; charter rule                                                                |
| F-029  | .assets/lib/certs.sh:290                 | interactive cert_intercept leaves macOS bundle stale   | fix      | certs | cert_intercept rebuilds itself; redundant phase call removed                                                                     |
| R-001  | -                                        | -                                                      | answered | -     | leave: setup targets WSL (root), Coder (no proxy) and macOS; a rootless container behind a proxy handles its system certs itself |
| F-001  | -                                        | -                                                      | answered | -     | leave: same as R-001                                                                                                             |
| F-010  | -                                        | -                                                      | answered | -     | leave: same as R-001                                                                                                             |
| F-027  | -                                        | -                                                      | answered | -     | leave: same as R-001                                                                                                             |
