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
_py() {
  PYTHONPATH="$SCRIPT_DIR" python3 -c "$1"
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
assert rec['has_delta'] is False, rec
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

@test "reconcile gates on a new covered path" {
  _seed_plan_and_changes
  run _py "
import release, json
plan = json.load(open('.release/commit-plan.json'))
state = json.load(open('.release/state.json'))
state['confirmed_covered_set'] = ['.assets/setup/thing.sh']
rec = release.reconcile(plan, state)
# CHANGELOG.md is covered but not yet confirmed -> delta.
assert rec['has_delta'] is True, rec
assert 'CHANGELOG.md' in rec['new_covered'], rec
print('OK')
"
  [ "$status" -eq 0 ]
  [[ "$output" == *OK* ]]
}

@test "reconcile flags an orphan path" {
  _seed_plan_and_changes
  echo "stray" >stray.txt # matches no glob
  run _py "
import release, json
plan = json.load(open('.release/commit-plan.json'))
state = json.load(open('.release/state.json'))
rec = release.reconcile(plan, state)
assert 'stray.txt' in rec['orphans'], rec
assert rec['has_delta'] is True, rec
print('OK')
"
  [ "$status" -eq 0 ]
  [[ "$output" == *OK* ]]
}

@test "reconcile gates when a previously-covered path is dropped" {
  _seed_plan_and_changes
  run _py "
import release, json
plan = json.load(open('.release/commit-plan.json'))
state = json.load(open('.release/state.json'))
# CHANGELOG.md was confirmed but is no longer in the tree (e.g. a fix reverted it).
import os
os.remove('CHANGELOG.md')
state['confirmed_covered_set'] = ['.assets/setup/thing.sh', 'CHANGELOG.md']
rec = release.reconcile(plan, state)
assert 'CHANGELOG.md' in rec['dropped'], rec
assert rec['has_delta'] is True, rec
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
assert rec['has_delta'] is False, rec
assert rec['new_covered'] == [], rec
assert rec['orphans'] == [], rec
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
