#!/usr/bin/env bats
# Unit tests for tests/hooks/check_skills.py - the hook that validates
# SKILL.md frontmatter against the Claude Skills spec.
#
# The failure this guards is asymmetric and silent: Claude Code loads an
# over-spec skill anyway, while GitHub Copilot CLI drops the whole skill
# directory on sync, so nothing surfaces at authoring time.
#
# Run through `uv run` because the hook imports PyYAML, which resolves from
# the project venv and not from a bare python3 - the same reason the hook
# carries a `#!/usr/bin/env -S uv run python3` shebang.
# shellcheck disable=SC2154
bats_require_minimum_version 1.5.0

REPO_SRC="$(cd "$(dirname "$BATS_TEST_FILENAME")/../.." && pwd)"

setup() {
  FIXTURE="$(mktemp -d)"
  mkdir -p "$FIXTURE/.claude/skills/demo"
  SKILL="$FIXTURE/.claude/skills/demo/SKILL.md"
}

teardown() {
  rm -rf "$FIXTURE"
}

# cwd is the repo so `uv run` finds pyproject.toml; the fixture lives outside
# it, so the hook validates the path on shape alone (see _under_skill_root).
_run_hook() {
  cd "$REPO_SRC" || return 1
  uv run python3 -m tests.hooks.check_skills "$@"
}

_skill() {
  cat >"$SKILL"
}

_long_string() {
  head -c "$1" </dev/zero | tr '\0' 'x'
}

# ---------------------------------------------------------------------------
# baseline
# ---------------------------------------------------------------------------

@test "a spec-compliant SKILL.md passes" {
  _skill <<'MD'
---
name: demo-skill
description: Does one clearly described thing, so the runtime can route to it.
---

# Demo
MD
  run _run_hook "$SKILL"
  [ "$status" -eq 0 ]
}

@test "every SKILL.md committed in this repo passes its own hook" {
  run _run_hook
  [ "$status" -eq 0 ]
}

# ---------------------------------------------------------------------------
# frontmatter block
# ---------------------------------------------------------------------------

@test "a file not starting with '---' is reported" {
  _skill <<'MD'
# Demo

No frontmatter at all.
MD
  run _run_hook "$SKILL"
  [ "$status" -eq 1 ]
  [[ "$output" == *"missing YAML frontmatter"* ]]
}

@test "an unterminated frontmatter block is reported" {
  _skill <<'MD'
---
name: demo-skill
description: Never closed.
MD
  run _run_hook "$SKILL"
  [ "$status" -eq 1 ]
  [[ "$output" == *"missing closing '---' fence"* ]]
}

@test "malformed YAML in the frontmatter is reported" {
  _skill <<'MD'
---
name: demo-skill
description: "unbalanced
  quotes: [ oops
---
MD
  run _run_hook "$SKILL"
  [ "$status" -eq 1 ]
  [[ "$output" == *"YAML parse error"* ]]
}

@test "an empty frontmatter block is reported" {
  _skill <<'MD'
---
---

# Demo
MD
  run _run_hook "$SKILL"
  [ "$status" -eq 1 ]
  [[ "$output" == *"frontmatter is empty"* ]]
}

@test "frontmatter that is a list rather than a mapping is reported" {
  _skill <<'MD'
---
- demo-skill
- does a thing
---
MD
  run _run_hook "$SKILL"
  [ "$status" -eq 1 ]
  [[ "$output" == *"must be a YAML mapping"* ]]
}

@test "a '----' rule in the body is not mistaken for the closing fence" {
  # The closing fence is a line that is exactly '---', so a longer rule in
  # the body must not truncate the frontmatter.
  _skill <<'MD'
---
name: demo-skill
description: Body contains a horizontal rule further down.
---

# Demo

----

More body.
MD
  run _run_hook "$SKILL"
  [ "$status" -eq 0 ]
}

# ---------------------------------------------------------------------------
# name
# ---------------------------------------------------------------------------

@test "a missing name is reported" {
  _skill <<'MD'
---
description: Has no name field.
---
MD
  run _run_hook "$SKILL"
  [ "$status" -eq 1 ]
  [[ "$output" == *"missing required field 'name'"* ]]
}

@test "a non-string name is reported with its type" {
  _skill <<'MD'
---
name: 42
description: Name parsed as an integer.
---
MD
  run _run_hook "$SKILL"
  [ "$status" -eq 1 ]
  [[ "$output" == *"'name' must be a string, got int"* ]]
}

@test "a name with uppercase or underscores is reported" {
  _skill <<'MD'
---
name: Demo_Skill
description: Name violates the character class.
---
MD
  run _run_hook "$SKILL"
  [ "$status" -eq 1 ]
  [[ "$output" == *"must match [a-z0-9-]+"* ]]
}

@test "a name over 64 chars is reported with its length" {
  local long
  long="$(_long_string 65 | tr 'x' 'a')"
  printf -- '---\nname: %s\ndescription: Name is too long.\n---\n' "$long" >"$SKILL"
  run _run_hook "$SKILL"
  [ "$status" -eq 1 ]
  [[ "$output" == *"'name' is 65 chars, max allowed is 64"* ]]
}

@test "a name at exactly 64 chars passes" {
  local long
  long="$(_long_string 64 | tr 'x' 'a')"
  printf -- '---\nname: %s\ndescription: Name is exactly at the cap.\n---\n' "$long" >"$SKILL"
  run _run_hook "$SKILL"
  [ "$status" -eq 0 ]
}

@test "a name containing an XML tag is reported" {
  _skill <<'MD'
---
name: "demo-<tag>-skill"
description: Name carries a tag.
---
MD
  run _run_hook "$SKILL"
  [ "$status" -eq 1 ]
  [[ "$output" == *"contains an XML tag"* ]]
}

@test "a name containing the reserved word 'claude' is reported" {
  _skill <<'MD'
---
name: claude-helper
description: Name uses a reserved word.
---
MD
  run _run_hook "$SKILL"
  [ "$status" -eq 1 ]
  [[ "$output" == *"contains reserved word 'claude'"* ]]
}

@test "a name containing the reserved word 'anthropic' is reported" {
  _skill <<'MD'
---
name: anthropic-tools
description: Name uses a reserved word.
---
MD
  run _run_hook "$SKILL"
  [ "$status" -eq 1 ]
  [[ "$output" == *"contains reserved word 'anthropic'"* ]]
}

# ---------------------------------------------------------------------------
# description
# ---------------------------------------------------------------------------

@test "a missing description is reported" {
  _skill <<'MD'
---
name: demo-skill
---
MD
  run _run_hook "$SKILL"
  [ "$status" -eq 1 ]
  [[ "$output" == *"missing required field 'description'"* ]]
}

@test "a whitespace-only description is reported as empty" {
  _skill <<'MD'
---
name: demo-skill
description: "   "
---
MD
  run _run_hook "$SKILL"
  [ "$status" -eq 1 ]
  [[ "$output" == *"'description' must be non-empty"* ]]
}

@test "a description over 1024 chars is reported with its length" {
  local long
  long="$(_long_string 1025)"
  printf -- '---\nname: demo-skill\ndescription: %s\n---\n' "$long" >"$SKILL"
  run _run_hook "$SKILL"
  [ "$status" -eq 1 ]
  [[ "$output" == *"'description' is 1025 chars, max allowed is 1024"* ]]
}

@test "a description at exactly 1024 chars passes" {
  local long
  long="$(_long_string 1024)"
  printf -- '---\nname: demo-skill\ndescription: %s\n---\n' "$long" >"$SKILL"
  run _run_hook "$SKILL"
  [ "$status" -eq 0 ]
}

@test "a description containing an XML tag is reported" {
  # This is the shape that actually shipped: argument placeholders written as
  # <...> read as tags and cost the skill its whole directory on Copilot sync.
  _skill <<'MD'
---
name: demo-skill
description: Run with demo <scope> to do the thing.
---
MD
  run _run_hook "$SKILL"
  [ "$status" -eq 1 ]
  [[ "$output" == *"'description' contains an XML tag"* ]]
}

@test "angle brackets that are not a tag do not trip the XML check" {
  _skill <<'MD'
---
name: demo-skill
description: Use when a value is < 10 or > 20, comparing numeric bounds.
---
MD
  run _run_hook "$SKILL"
  [ "$status" -eq 0 ]
}

# ---------------------------------------------------------------------------
# which files the hook claims
# ---------------------------------------------------------------------------

@test "a .github/skills root is validated too" {
  mkdir -p "$FIXTURE/.github/skills/demo"
  local gh="$FIXTURE/.github/skills/demo/SKILL.md"
  printf -- '---\nname: Bad_Name\ndescription: Wrong char class.\n---\n' >"$gh"
  run _run_hook "$gh"
  [ "$status" -eq 1 ]
  [[ "$output" == *"must match [a-z0-9-]+"* ]]
}

@test "a markdown file that is not SKILL.md is ignored" {
  local other="$FIXTURE/.claude/skills/demo/README.md"
  printf 'no frontmatter here\n' >"$other"
  run _run_hook "$other"
  [ "$status" -eq 0 ]
}

@test "a SKILL.md outside any skills root is ignored" {
  mkdir -p "$FIXTURE/docs/demo"
  local stray="$FIXTURE/docs/demo/SKILL.md"
  printf 'no frontmatter here\n' >"$stray"
  run _run_hook "$stray"
  [ "$status" -eq 0 ]
}

@test "multiple failing files are all reported and counted" {
  mkdir -p "$FIXTURE/.claude/skills/second"
  local two="$FIXTURE/.claude/skills/second/SKILL.md"
  printf -- '---\nname: Bad_One\ndescription: x\n---\n' >"$SKILL"
  printf -- '---\nname: Bad_Two\ndescription: x\n---\n' >"$two"
  run _run_hook "$SKILL" "$two"
  [ "$status" -eq 1 ]
  [[ "$output" == *"Bad_One"* ]]
  [[ "$output" == *"Bad_Two"* ]]
  [[ "$output" == *"2 SKILL.md file(s) failed"* ]]
}

@test "a file listed but absent from disk is skipped, not a crash" {
  run _run_hook "$FIXTURE/.claude/skills/ghost/SKILL.md"
  [ "$status" -eq 0 ]
}
