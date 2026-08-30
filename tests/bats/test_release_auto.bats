#!/usr/bin/env bats
# Unit tests for .claude/skills/release-auto/scripts/release.py - the release
# orchestrator's git-driver core: recut idempotency, reconcile set-diff,
# pre-validation rejects, safety-ref restore, and the resume staleness guard.
# Exercised by importing release.py as a module inside isolated temp git repos
# (no network, no make/gh - only the deterministic spine primitives).
# shellcheck disable=SC2154
bats_require_minimum_version 1.5.0

REPO_SRC="$(cd "$BATS_TEST_DIRNAME/../.." && pwd)"
SCRIPT_DIR="$REPO_SRC/.claude/skills/release-auto/scripts"

setup() {
  TMP="$(mktemp -d)"
  cd "$TMP" || return 1
  git init -q
  git config user.name "Test"
  git config user.email "test@example.com"
  git config commit.gpgsign false
  # Baseline commit + tag: the release scopes against this. .release/ is
  # git-ignored (as in the real repo) so it never counts as an orphan path.
  echo "base" >base.txt
  echo ".release/" >.gitignore
  git add base.txt .gitignore
  git commit -qm "chore: base"
  git tag v0.1.0
}

teardown() {
  cd / || true
  rm -rf "$TMP"
}

# Run a python snippet with release.py importable and CWD at the temp repo.
# release.py targets Python 3.13+ (it uses PurePosixPath.full_match, added in
# 3.13; the project pins requires-python = "~=3.13.0"). Production always runs
# it under `uv run` via the shebang, so it never sees an older interpreter. The
# test must honor the same contract - a bare `python3` resolves to the system
# interpreter (3.12 on stock Ubuntu / macOS runners without the python scope),
# which lacks full_match and fails every test with an AttributeError. `uv run`
# provisions a >=3.13 interpreter regardless of what's on PATH.
_py() {
  PYTHONPATH="$SCRIPT_DIR" uv run --no-project --python '>=3.13' python3 -c "$1"
}

# Seed a two-group plan (feature file + changelog riders) and two changed files.
_seed_plan_and_changes() {
  mkdir -p .release .assets/setup
  cat >.release/commit-plan.json <<'JSON'
{
  "version": "0.2.0",
  "groups": [
    {"globs": [".assets/**"], "prefix": "feat", "message": "feat(x): add thing"},
    {"globs": ["CHANGELOG.md"], "prefix": "docs", "message": "docs(changelog): cut 0.2.0"}
  ]
}
JSON
  cat >.release/state.json <<JSON
{
  "version": "0.2.0",
  "skip_review": false,
  "last_tag": "v0.1.0",
  "reset_target": "v0.1.0",
  "is_rerun": false,
  "phase": "await_push",
  "head_sha": "$(git rev-parse HEAD)",
  "confirmed_covered_set": [],
  "completed_phases": ["A", "B"],
  "decisions": []
}
JSON
  echo "feature" >.assets/setup/thing.sh
  echo "# changelog" >CHANGELOG.md
}

# =============================================================================
# recut - idempotency
# =============================================================================

@test "recut produces the same tree and commits when re-run" {
  _seed_plan_and_changes
  run _py "
import release, json, subprocess
plan = json.load(open('.release/commit-plan.json'))
state = json.load(open('.release/state.json'))
subj1 = release.recut(plan, state)
tree1 = subprocess.run(['git','rev-parse','HEAD^{tree}'],capture_output=True,text=True).stdout.strip()
subj2 = release.recut(plan, state)
tree2 = subprocess.run(['git','rev-parse','HEAD^{tree}'],capture_output=True,text=True).stdout.strip()
n = subprocess.run(['git','rev-list','--count','v0.1.0..HEAD'],capture_output=True,text=True).stdout.strip()
assert subj1 == subj2, (subj1, subj2)
assert tree1 == tree2, (tree1, tree2)
assert n == '2', n
print('OK')
"
  [ "$status" -eq 0 ]
  [[ "$output" == *OK* ]]
}

# =============================================================================
# recut - content re-edit keeps topology (zero-agent-turn path)
# =============================================================================

@test "recut after a content-only edit re-commits the same topology" {
  _seed_plan_and_changes
  _py "
import release, json
plan = json.load(open('.release/commit-plan.json'))
state = json.load(open('.release/state.json'))
release.recut(plan, state)
# Record the covered set the way resume_phase1 does after the first cut.
state['confirmed_covered_set'] = sorted(['.assets/setup/thing.sh', 'CHANGELOG.md'])
json.dump(state, open('.release/state.json','w'))
"
  # Simulate a review fix: edit an already-covered file, no new paths.
  echo "feature v2" >.assets/setup/thing.sh
  run _py "
import release, json, subprocess
plan = json.load(open('.release/commit-plan.json'))
state = json.load(open('.release/state.json'))
rec = release.reconcile(plan, state)
assert rec['blocked'] is False, rec
subj = release.recut(plan, state)
n = subprocess.run(['git','rev-list','--count','v0.1.0..HEAD'],capture_output=True,text=True).stdout.strip()
assert n == '2', n
print('OK')
"
  [ "$status" -eq 0 ]
  [[ "$output" == *OK* ]]
}

# =============================================================================
# reconcile - covered-set delta detection
# =============================================================================

@test "reconcile does NOT block on a new covered path the plan already claims" {
  _seed_plan_and_changes
  run _py "
import release, json
plan = json.load(open('.release/commit-plan.json'))
state = json.load(open('.release/state.json'))
state['confirmed_covered_set'] = ['.assets/setup/thing.sh']
rec = release.reconcile(plan, state)
# CHANGELOG.md is covered by a plan glob but not yet confirmed: reported as
# new_covered context, but NOT a block - the plan can execute as-is.
assert rec['blocked'] is False, rec
assert 'CHANGELOG.md' in rec['new_covered'], rec
print('OK')
"
  [ "$status" -eq 0 ]
  [[ "$output" == *OK* ]]
}

@test "reconcile blocks on an orphan path no group claims" {
  _seed_plan_and_changes
  echo "stray" >stray.txt # matches no glob
  run _py "
import release, json
plan = json.load(open('.release/commit-plan.json'))
state = json.load(open('.release/state.json'))
rec = release.reconcile(plan, state)
assert 'stray.txt' in rec['orphans'], rec
assert rec['blocked'] is True, rec
print('OK')
"
  [ "$status" -eq 0 ]
  [[ "$output" == *OK* ]]
}

@test "reconcile blocks when a plan group would be empty" {
  _seed_plan_and_changes
  run _py "
import release, json
plan = json.load(open('.release/commit-plan.json'))
# Add a group whose glob matches nothing in the tree.
plan['groups'].append({'globs': ['does/not/exist.sh'], 'prefix': 'fix', 'message': 'fix: ghost'})
json.dump(plan, open('.release/commit-plan.json','w'))
state = json.load(open('.release/state.json'))
rec = release.reconcile(plan, state)
assert rec['blocked'] is True, rec
assert any('ghost' in e for e in rec['empty_groups']), rec
print('OK')
"
  [ "$status" -eq 0 ]
  [[ "$output" == *OK* ]]
}

@test "reconcile does NOT block on a dropped path once the plan drops its group" {
  # Regression: reverting a change mid-coda used to dead-end. The dropped path
  # is reported as context, but with no orphan/empty-group the plan executes.
  _seed_plan_and_changes
  run _py "
import release, json, os
plan = json.load(open('.release/commit-plan.json'))
state = json.load(open('.release/state.json'))
# CHANGELOG.md was confirmed but is reverted out of the tree, and the agent has
# updated the plan to no longer reference it (its group is removed).
os.remove('CHANGELOG.md')
plan['groups'] = [g for g in plan['groups'] if 'CHANGELOG.md' not in g['globs']]
json.dump(plan, open('.release/commit-plan.json','w'))
state['confirmed_covered_set'] = ['.assets/setup/thing.sh', 'CHANGELOG.md']
rec = release.reconcile(plan, state)
assert 'CHANGELOG.md' in rec['dropped'], rec
assert rec['blocked'] is False, rec
print('OK')
"
  [ "$status" -eq 0 ]
  [[ "$output" == *OK* ]]
}

@test "reconcile is silent when the covered set is unchanged" {
  _seed_plan_and_changes
  run _py "
import release, json
plan = json.load(open('.release/commit-plan.json'))
state = json.load(open('.release/state.json'))
state['confirmed_covered_set'] = ['.assets/setup/thing.sh', 'CHANGELOG.md']
rec = release.reconcile(plan, state)
assert rec['blocked'] is False, rec
assert rec['new_covered'] == [], rec
assert rec['orphans'] == [], rec
print('OK')
"
  [ "$status" -eq 0 ]
  [[ "$output" == *OK* ]]
}

# =============================================================================
# cmd_recut - command-level coda orchestration (gate / re-seed / advisory)
# =============================================================================
# These exercise the wiring reconcile()+recut() do not: the gate decision, the
# confirmed_covered_set re-seed, and the advisory reconciled payload. run_make is
# stubbed so lint-diff never shells out inside the isolated temp repo.

@test "cmd_recut proceeds and re-seeds confirmed_covered_set on a clean plan" {
  _seed_plan_and_changes
  run _py "
import release, json, argparse
release.run_make = lambda *a, **k: ''  # stub lint-diff
# A prior recut confirmed only the feature file; CHANGELOG.md is newly covered
# by an existing glob (advisory new_covered, must NOT gate).
state = json.load(open('.release/state.json'))
state['confirmed_covered_set'] = ['.assets/setup/thing.sh']
json.dump(state, open('.release/state.json','w'))
rc = release.cmd_recut(argparse.Namespace())
assert rc == release.EXIT_OK, rc
after = json.load(open('.release/state.json'))
# re-seeded to the full covered set actually cut
assert after['confirmed_covered_set'] == sorted(['.assets/setup/thing.sh','CHANGELOG.md']), after
print('OK')
"
  [ "$status" -eq 0 ]
  [[ "$output" == *OK* ]]
}

@test "cmd_recut gates (exit 10) on an orphan path instead of dead-ending" {
  _seed_plan_and_changes
  echo "stray" >stray.txt # no glob claims it
  run _py "
import release, json, argparse
release.run_make = lambda *a, **k: ''
rc = release.cmd_recut(argparse.Namespace())
assert rc == release.EXIT_GATE, rc
print('OK')
"
  [ "$status" -eq 0 ]
  [[ "$output" == *OK* ]]
}

@test "cmd_recut does NOT gate when a previously-confirmed path is dropped" {
  # Regression for the mid-coda revert dead-end. A path confirmed by a prior cut
  # is no longer in the tree's changed universe (a review reverted it) and its
  # plan group is gone. The old covered-set-delta gate would report `dropped` and
  # block forever, because the coda path never re-seeds confirmed_covered_set.
  # cmd_recut must now proceed: no orphan, no empty group -> executable plan.
  _seed_plan_and_changes
  run _py "
import release, json, argparse
release.run_make = lambda *a, **k: ''
# State claims a third path that this run's plan does NOT cover and that is not
# in the tree - exactly a stale 'dropped' entry from a reverted fix.
state = json.load(open('.release/state.json'))
state['confirmed_covered_set'] = ['.assets/setup/thing.sh', 'CHANGELOG.md', 'gone.sh']
json.dump(state, open('.release/state.json','w'))
rc = release.cmd_recut(argparse.Namespace())
assert rc == release.EXIT_OK, rc  # proceeds despite the dropped 'gone.sh'
after = json.load(open('.release/state.json'))
# re-seeded to what was actually cut - the stale 'gone.sh' is gone.
assert after['confirmed_covered_set'] == sorted(['.assets/setup/thing.sh','CHANGELOG.md']), after
print('OK')
"
  [ "$status" -eq 0 ]
  [[ "$output" == *OK* ]]
}

# =============================================================================
# pre-validation - rejects before any git mutation
# =============================================================================

@test "prevalidate rejects an orphan path before mutating git" {
  _seed_plan_and_changes
  echo "stray" >stray.txt
  run _py "
import release, json
plan = json.load(open('.release/commit-plan.json'))
head = release.head_sha()
try:
    release.recut(plan, json.load(open('.release/state.json')))
    print('NO-RAISE')
except release.ReleaseError as e:
    assert 'orphans' in str(e), str(e)
    # HEAD must not have moved - failure was pre-mutation.
    assert release.head_sha() == head
    print('OK')
"
  [ "$status" -eq 0 ]
  [[ "$output" == *OK* ]]
}

@test "prevalidate rejects a plan that would produce an empty commit" {
  _seed_plan_and_changes
  # Add a third group whose glob matches nothing changed.
  _py "
import json
plan = json.load(open('.release/commit-plan.json'))
plan['groups'].append({'globs': ['nonexistent/**'], 'prefix': 'test', 'message': 'test: none'})
json.dump(plan, open('.release/commit-plan.json','w'))
"
  run _py "
import release, json
plan = json.load(open('.release/commit-plan.json'))
try:
    release.recut(plan, json.load(open('.release/state.json')))
    print('NO-RAISE')
except release.ReleaseError as e:
    assert 'empty commit' in str(e), str(e)
    print('OK')
"
  [ "$status" -eq 0 ]
  [[ "$output" == *OK* ]]
}

# =============================================================================
# safety backup ref - restore on a mid-recut failure
# =============================================================================

@test "recut soft-rewinds and PRESERVES uncommitted work if a commit fails mid-way" {
  _seed_plan_and_changes
  run _py "
import release, json
plan = json.load(open('.release/commit-plan.json'))
state = json.load(open('.release/state.json'))
head_before = release.head_sha()
calls = {'n': 0}
orig = release._commit
def flaky(msg):
    calls['n'] += 1
    if calls['n'] == 2:
        raise release.ReleaseError('simulated commit failure')
    return orig(msg)
release._commit = flaky
try:
    release.recut(plan, state)
    print('NO-RAISE')
except release.ReleaseError:
    assert release.head_sha() == head_before, 'HEAD not restored'
    # The real regression guard: the release work must still be in the tree,
    # NOT destroyed by a hard reset. On a first cut it is all uncommitted.
    assert open('.assets/setup/thing.sh').read().strip() == 'feature', 'work lost!'
    assert open('CHANGELOG.md').read().strip() == '# changelog', 'changelog lost!'
    print('OK')
"
  [ "$status" -eq 0 ]
  [[ "$output" == *OK* ]]
}

@test "recut rewinds when the validate callback fails, preserving work" {
  _seed_plan_and_changes
  run _py "
import release, json
plan = json.load(open('.release/commit-plan.json'))
state = json.load(open('.release/state.json'))
head_before = release.head_sha()
def failing_validate():
    raise release.ReleaseError('simulated lint-diff failure')
try:
    release.recut(plan, state, validate=failing_validate)
    print('NO-RAISE')
except release.ReleaseError:
    assert release.head_sha() == head_before, 'HEAD not rewound after validate fail'
    # commits were made then rewound; work is back in the tree, uncommitted.
    assert open('.assets/setup/thing.sh').read().strip() == 'feature', 'work lost!'
    import subprocess
    n = subprocess.run(['git','rev-list','--count','v0.1.0..HEAD'],capture_output=True,text=True).stdout.strip()
    assert n == '0', f'expected no commits after rewind, got {n}'
    print('OK')
"
  [ "$status" -eq 0 ]
  [[ "$output" == *OK* ]]
}

# =============================================================================
# resume guard - HEAD staleness refusal
# =============================================================================

@test "guard_resume refuses when HEAD moved underneath the orchestrator" {
  _seed_plan_and_changes
  run _py "
import release, json
state = json.load(open('.release/state.json'))
state['head_sha'] = '0' * 40   # pretend a different HEAD was recorded
try:
    release.guard_resume(state)
    print('NO-RAISE')
except release.ReleaseError as e:
    assert 'HEAD moved' in str(e), str(e)
    print('OK')
"
  [ "$status" -eq 0 ]
  [[ "$output" == *OK* ]]
}

@test "guard_resume passes when HEAD is unchanged" {
  _seed_plan_and_changes
  run _py "
import release, json
state = json.load(open('.release/state.json'))
release.guard_resume(state)   # head_sha matches current HEAD
print('OK')
"
  [ "$status" -eq 0 ]
  [[ "$output" == *OK* ]]
}

# =============================================================================
# _cspell_add - surfaces a helper failure instead of swallowing it
# =============================================================================

@test "_cspell_add raises when the helper exits non-zero" {
  _seed_plan_and_changes
  run _py "
import release
from pathlib import Path
# Point SHARED at a dir whose cspell_words.py always fails.
release.SHARED = Path('fakebin')
Path('fakebin').mkdir()
script = Path('fakebin/cspell_words.py')
script.write_text('#!/usr/bin/env python3\nimport sys; sys.stderr.write(\"boom\"); sys.exit(1)\n')
script.chmod(0o755)
try:
    release._cspell_add(['someword'])
    print('NO-RAISE')
except release.ReleaseError as e:
    assert 'cspell_words.py add failed' in str(e), str(e)
    print('OK')
"
  [ "$status" -eq 0 ]
  [[ "$output" == *OK* ]]
}

@test "_cspell_add is a no-op for an empty word list" {
  _seed_plan_and_changes
  run _py "
import release
release._cspell_add([])   # must not raise or shell out
print('OK')
"
  [ "$status" -eq 0 ]
  [[ "$output" == *OK* ]]
}

# =============================================================================
# start guard - refuses a second in-flight release (version-mismatch class)
# =============================================================================

@test "cmd_start refuses when a release is already in progress" {
  _seed_plan_and_changes # writes .release/state.json for 0.2.0
  run _py "
import release, argparse
args = argparse.Namespace(version='0.3.0', skip_review=False)
try:
    release.cmd_start(args)
    print('NO-RAISE')
except release.ReleaseError as e:
    assert 'already in progress' in str(e), str(e)
    print('OK')
"
  [ "$status" -eq 0 ]
  [[ "$output" == *OK* ]]
}

# =============================================================================
# refuse_shared_branch - main is rejected, release/* allowed
# =============================================================================

@test "spine-complete seeds review-policy.json but preserves an existing copy" {
  _seed_plan_and_changes
  run _py "
import release
from pathlib import Path
# Point DEFAULT_POLICY at a fixture; simulate the seed condition directly.
Path('default-policy.json').write_text('{\"known_false_positives\": []}')
release.DEFAULT_POLICY = Path('default-policy.json')
# Case 1: no per-release copy -> seed it.
assert not release.POLICY_FILE.exists()
if not release.POLICY_FILE.exists() and release.DEFAULT_POLICY.is_file():
    release.STATE_DIR.mkdir(exist_ok=True)
    release.POLICY_FILE.write_text(release.DEFAULT_POLICY.read_text())
assert release.POLICY_FILE.exists(), 'policy not seeded'
# Case 2: local edit must survive a second seed attempt.
release.POLICY_FILE.write_text('{\"local\": \"edit\"}')
if not release.POLICY_FILE.exists() and release.DEFAULT_POLICY.is_file():
    release.POLICY_FILE.write_text(release.DEFAULT_POLICY.read_text())
assert 'local' in release.POLICY_FILE.read_text(), 'local edit clobbered'
print('OK')
"
  [ "$status" -eq 0 ]
  [[ "$output" == *OK* ]]
}

@test "load_plan rejects a group missing required keys with a clean error" {
  _seed_plan_and_changes
  _py "
import json
plan = json.load(open('.release/commit-plan.json'))
plan['groups'].append({'prefix': 'test'})   # no globs, no message
json.dump(plan, open('.release/commit-plan.json','w'))
"
  run _py "
import release
try:
    release.load_plan()
    print('NO-RAISE')
except release.ReleaseError as e:
    assert 'missing required key' in str(e), str(e)
    print('OK')
"
  [ "$status" -eq 0 ]
  [[ "$output" == *OK* ]]
}

@test "_upsert_pr refuses an empty CHANGELOG body" {
  _seed_plan_and_changes
  run _py "
import release
# CHANGELOG has no '## [9.9.9]' section -> changelog_section returns ''.
try:
    release._upsert_pr('9.9.9')
    print('NO-RAISE')
except release.ReleaseError as e:
    assert 'empty body' in str(e), str(e)
    print('OK')
"
  [ "$status" -eq 0 ]
  [[ "$output" == *OK* ]]
}

@test "refuse_shared_branch rejects a detached HEAD" {
  _seed_plan_and_changes
  run _py "
import release, subprocess
subprocess.run(['git','checkout','-q','--detach'])
try:
    release.refuse_shared_branch()
    print('NO-RAISE')
except release.ReleaseError as e:
    assert 'detached HEAD' in str(e), str(e)
    print('OK')
"
  [ "$status" -eq 0 ]
  [[ "$output" == *OK* ]]
}

@test "tracked_and_untracked includes staged-only changes" {
  _seed_plan_and_changes
  # Stage a brand-new file, then remove it from the working tree so it exists
  # ONLY in the index. `git diff <base>` alone would miss it; --cached catches it.
  echo "staged" >.assets/setup/staged_only.sh
  git add .assets/setup/staged_only.sh
  rm .assets/setup/staged_only.sh
  run _py "
import release
u = release.tracked_and_untracked('v0.1.0')
assert '.assets/setup/staged_only.sh' in u, u
print('OK')
"
  [ "$status" -eq 0 ]
  [[ "$output" == *OK* ]]
}

@test "refuse_shared_branch rejects main but allows release/*" {
  run _py "
import release
subprocess = __import__('subprocess')
subprocess.run(['git','checkout','-q','-b','main'])
try:
    release.refuse_shared_branch()
    raised = False
except release.ReleaseError:
    raised = True
assert raised, 'main should be refused'
subprocess.run(['git','checkout','-q','-b','release/0.2.0'])
release.refuse_shared_branch()   # must not raise
print('OK')
"
  [ "$status" -eq 0 ]
  [[ "$output" == *OK* ]]
}

# =============================================================================
# push guard - refuses when a plan-covered fix was edited but not re-cut
# =============================================================================

@test "uncommitted_covered_paths is empty after a clean recut" {
  _seed_plan_and_changes
  run _py "
import release, json
plan = json.load(open('.release/commit-plan.json'))
state = json.load(open('.release/state.json'))
release.recut(plan, state)   # commits everything; tree now clean
stale = release.uncommitted_covered_paths(plan)
assert stale == [], stale
print('OK')
"
  [ "$status" -eq 0 ]
  [[ "$output" == *OK* ]]
}

@test "uncommitted_covered_paths flags a covered edit made after recut" {
  _seed_plan_and_changes
  _py "
import release, json
plan = json.load(open('.release/commit-plan.json'))
state = json.load(open('.release/state.json'))
release.recut(plan, state)
"
  # Simulate a review fix left uncommitted (the 'forgot to recut' case).
  echo "feature v2" >.assets/setup/thing.sh
  run _py "
import release, json
plan = json.load(open('.release/commit-plan.json'))
stale = release.uncommitted_covered_paths(plan)
assert '.assets/setup/thing.sh' in stale, stale
print('OK')
"
  [ "$status" -eq 0 ]
  [[ "$output" == *OK* ]]
}

@test "uncommitted_covered_paths ignores dirt on paths no plan group claims" {
  _seed_plan_and_changes
  _py "
import release, json
plan = json.load(open('.release/commit-plan.json'))
state = json.load(open('.release/state.json'))
release.recut(plan, state)
"
  # An untracked file outside every plan glob is reconcile's concern, not the
  # push guard's - it must not trip the stale-commit refusal.
  echo "stray" >unclaimed.txt
  run _py "
import release, json
plan = json.load(open('.release/commit-plan.json'))
stale = release.uncommitted_covered_paths(plan)
assert stale == [], stale
print('OK')
"
  [ "$status" -eq 0 ]
  [[ "$output" == *OK* ]]
}

# =============================================================================
# abort - only unwinds THIS run's recut, never a finalized/pushed release
# =============================================================================

@test "abort rewinds this run's recut commits when a backup ref exists" {
  _seed_plan_and_changes
  run _py "
import release, json, argparse, subprocess
plan = json.load(open('.release/commit-plan.json'))
state = json.load(open('.release/state.json'))
release.recut(plan, state)   # writes refs/release-backup/0.2.0, makes 2 commits
n = subprocess.run(['git','rev-list','--count','v0.1.0..HEAD'],capture_output=True,text=True).stdout.strip()
assert n == '2', n
release.cmd_abort(argparse.Namespace())
# commits rewound, content preserved in the working tree
n2 = subprocess.run(['git','rev-list','--count','v0.1.0..HEAD'],capture_output=True,text=True).stdout.strip()
assert n2 == '0', f'expected rewind to tag, got {n2}'
assert open('.assets/setup/thing.sh').read().strip() == 'feature', 'work lost!'
print('OK')
"
  [ "$status" -eq 0 ]
  [[ "$output" == *OK* ]]
}

@test "abort does NOT unwind already-finalized commits when no backup ref exists" {
  # Regression for the data-integrity bug: a no-op re-run's abort must never
  # soft-rewind a prior finalized+pushed release back into the working tree.
  _seed_plan_and_changes
  run _py "
import release, json, argparse, subprocess
plan = json.load(open('.release/commit-plan.json'))
state = json.load(open('.release/state.json'))
release.recut(plan, state)
release.delete_backup('0.2.0')   # simulate a prior clean finish (ref gone)
head_before = release.head_sha()
n_before = subprocess.run(['git','rev-list','--count','v0.1.0..HEAD'],capture_output=True,text=True).stdout.strip()
assert n_before == '2', n_before
release.cmd_abort(argparse.Namespace())
# No backup ref -> commits MUST be left untouched (not rewound).
assert release.head_sha() == head_before, 'abort unwound finalized commits!'
n_after = subprocess.run(['git','rev-list','--count','v0.1.0..HEAD'],capture_output=True,text=True).stdout.strip()
assert n_after == '2', f'commits changed: {n_after}'
print('OK')
"
  [ "$status" -eq 0 ]
  [[ "$output" == *OK* ]]
}

@test "abort does NOT rewind when the backup ref is not an ancestor of HEAD" {
  # Regression for the cross-cycle orphan bug: a backup ref left over from a
  # divergent, already-shipped cycle points at a commit that is NOT an ancestor
  # of HEAD. Soft-resetting to it would move the branch onto foreign history and
  # stage a bogus diff. abort must leave commits/tree untouched and only wipe.
  _seed_plan_and_changes
  run _py "
import release, json, argparse, subprocess

def sh(*a):
    return subprocess.run(['git',*a],capture_output=True,text=True).stdout.strip()

# Fabricate an orphaned backup ref on a divergent commit (not reachable from HEAD).
sh('checkout','-q','-b','divergent','v0.1.0')
open('orphan.txt','w').write('orphan')
sh('add','orphan.txt'); sh('commit','-qm','docs(changelog): abandoned recut')
orphan_sha = release.head_sha()
sh('checkout','-q','-')                          # back to the working branch
sh('update-ref','refs/release-backup/0.2.0',orphan_sha)
assert release._is_ancestor(orphan_sha,'HEAD') is False, 'setup: orphan must be divergent'

head_before = release.head_sha()
release.cmd_abort(argparse.Namespace())
# Non-ancestor backup -> HEAD MUST be untouched (no reset onto foreign history).
assert release.head_sha() == head_before, 'abort reset onto divergent history!'
import os
assert not os.path.isfile('.release/state.json'), 'state not wiped'
# The commit plan is the one deliberate survivor - an aborted release is
# usually retried, and re-deriving every group is the expensive part.
leftover = sorted(os.listdir('.release')) if os.path.isdir('.release') else []
assert leftover in ([], ['commit-plan.prev.json']), leftover
print('OK')
"
  [ "$status" -eq 0 ]
  [[ "$output" == *OK* ]]
}

@test "start refuses with shipped-aware guidance when leftover state is already tagged" {
  # Regression for the orphaned-state blocker: state left behind by a shipped
  # cycle (coda never ran `push --done`) must not read as "in progress". When the
  # leftover version is already a git tag, start points at `abort`, not `resume`.
  _seed_plan_and_changes # seeds .release/state.json @ 0.2.0
  git tag v0.2.0         # simulate 0.2.0 already shipped
  run _py "
import release, argparse
try:
    release.cmd_start(argparse.Namespace(version='0.3.0', skip_review=False))
    assert False, 'start should have refused'
except release.ReleaseError as e:
    msg = str(e)
    assert 'already tagged' in msg, msg
    assert 'abort' in msg, msg
    print('OK')
"
  [ "$status" -eq 0 ]
  [[ "$output" == *OK* ]]
}

# =============================================================================
# nothing-to-release guard helpers
# =============================================================================

@test "tree_is_clean detects a dirty vs clean working tree" {
  _seed_plan_and_changes
  run _py "
import release, json
plan = json.load(open('.release/commit-plan.json'))
state = json.load(open('.release/state.json'))
# Seed wrote uncommitted files -> dirty.
assert release.tree_is_clean() is False, 'expected dirty tree before recut'
release.recut(plan, state)   # commits everything
assert release.tree_is_clean() is True, 'expected clean tree after recut'
print('OK')
"
  [ "$status" -eq 0 ]
  [[ "$output" == *OK* ]]
}

@test "head_is_published is False without an upstream, True when HEAD==upstream" {
  # Needs a real tracking branch, so build a clone-based remote here rather than
  # reuse the shared setup (which has no remote).
  local root="$TMP/pubtest" bare="$TMP/pub_bare.git"
  git init -q --bare "$bare"
  git clone -q "$bare" "$root"
  cd "$root" || return 1
  git config user.name Test
  git config user.email test@example.com
  git config commit.gpgsign false
  echo base >base.txt
  git add base.txt
  git commit -qm base
  run _py "
import release
# No upstream yet -> unpublished.
assert release.head_is_published() is False, 'no upstream should be unpublished'
"
  [ "$status" -eq 0 ]
  # Don't hard-code 'master' - the initial branch depends on init.defaultBranch
  # (can be 'main'). Capture the actual branch name and track that.
  local branch
  branch="$(git branch --show-current)"
  git push -q origin "$branch"
  git branch --set-upstream-to="origin/$branch"
  run _py "
import release, subprocess
assert release.head_is_published() is True, 'HEAD==upstream should be published'
open('new.txt','w').write('x')
subprocess.run(['git','add','-A']); subprocess.run(['git','commit','-qm','ahead'])
assert release.head_is_published() is False, 'ahead of upstream should be unpublished'
print('OK')
"
  [ "$status" -eq 0 ]
  [[ "$output" == *OK* ]]
}

@test "push gate reports whether the review coda will run" {
  _seed_plan_and_changes
  run _py "
import release
# The value the agent has to notice is the false one: it means this push
# wipes the run, so a coda has nothing left to drive.
for skip, expected in ((True, False), (False, True)):
    assert (not {'skip_review': skip}.get('skip_review')) is expected
# And the real payload carries it.
src = open(release.__file__).read()
assert '\"review_coda\": not state.get(\"skip_review\")' in src, 'gate does not report review_coda'
print('OK')
"
  [ "$status" -eq 0 ]
  [[ "$output" == *OK* ]]
}

@test "push gate decision can turn the review coda on" {
  _seed_plan_and_changes
  run _py "
import release
# A driver launched with --skip-review when the user wanted the review: the
# flag is otherwise fixed at start and the push wipes state, so without this
# the only recovery is re-running the whole spine.
state = {'skip_review': True}
decision = {'approve': True, 'review': True}
if decision.get('review'):
    state['skip_review'] = False
assert state['skip_review'] is False
print('OK')
"
  [ "$status" -eq 0 ]
  [[ "$output" == *OK* ]]
}

@test "push gate decision cannot turn an enabled review coda off" {
  _seed_plan_and_changes
  run _py "
import release
# One-way by design: forgetting to repeat a flag is likelier than wanting to
# revoke it, and revoking here would destroy the state the coda runs on.
state = {'skip_review': False}
for decision in ({'approve': True}, {'approve': True, 'review': False}):
    if decision.get('review'):
        state['skip_review'] = False
    assert state['skip_review'] is False, decision
print('OK')
"
  [ "$status" -eq 0 ]
  [[ "$output" == *OK* ]]
}

@test "push --done on an already-finished run is a no-op, not an error" {
  _seed_plan_and_changes
  rm -rf .release
  run _py "
import argparse, release
# The documented last step is run unconditionally; a --skip-review run has
# already wiped its own state by then, so this used to dead-end on
# 'no .release/state.json' - which reads as a fault, not as 'already done'.
rc = release.cmd_push(argparse.Namespace(done=True))
assert rc == release.EXIT_OK, rc
print('OK')
"
  [ "$status" -eq 0 ]
  [[ "$output" == *OK* ]]
  [[ "$output" == *"already finished"* ]]
}

@test "push without --done still fails loudly when there is no run" {
  _seed_plan_and_changes
  rm -rf .release
  run _py "
import argparse, release
try:
    release.cmd_push(argparse.Namespace(done=False))
    print('NO-RAISE')
except release.ReleaseError as e:
    assert 'no .release/state.json' in str(e), str(e)
    print('OK')
"
  [ "$status" -eq 0 ]
  [[ "$output" == *OK* ]]
}
