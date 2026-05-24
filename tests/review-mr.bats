#!/usr/bin/env bats
#
# Tests for bin/review-mr.sh. Stubs `glab` and `claude` so we don't need network
# or credentials. Each test sets up a fake-bins directory on PATH whose stub
# binaries record their invocations and produce canned output.

setup() {
  PROJECT_ROOT="$(cd "$BATS_TEST_DIRNAME/.." && pwd)"
  TMPDIR_T="$(mktemp -d)"
  FAKE_BIN="$TMPDIR_T/bin"
  CALL_LOG="$TMPDIR_T/calls.log"
  mkdir -p "$FAKE_BIN"

  : >"$CALL_LOG"
  export CALL_LOG TMPDIR_T

  # Path overrides — keep core utils available.
  export PATH="$FAKE_BIN:/usr/bin:/bin"

  # Required env.
  export GITLAB_TOKEN="test-token"
  export GITLAB_HOST="gitlab.example.com"
  export REVIEW_TARGET_BRANCH="main"
  export CLAUDE_BIN="claude"
}

teardown() {
  rm -rf "$TMPDIR_T"
}

# --- helpers ---------------------------------------------------------------

# Write a stub binary that logs its argv and emits the fixture on stdout.
# Usage: make_stub <name> <fixture_path>
make_stub() {
  local name="$1" fixture="$2"
  cat >"$FAKE_BIN/$name" <<EOF
#!/usr/bin/env bash
echo "$name \$*" >>"\$CALL_LOG"
cat "$fixture"
EOF
  chmod +x "$FAKE_BIN/$name"
}

# Write a stub `glab` that routes by first arg ("mr") + second arg (subcommand)
# and produces different output per subcommand from a fixture directory.
# fixtures/
#   view.json      → glab mr view
#   diff.patch     → glab mr diff
#   list.json      → glab mr list
make_glab_stub() {
  local fixtures_dir="$1"
  cat >"$FAKE_BIN/glab" <<EOF
#!/usr/bin/env bash
echo "glab \$*" >>"\$CALL_LOG"
case "\$1 \$2" in
  "mr view")   cat "$fixtures_dir/view.json" ;;
  "mr diff")   cat "$fixtures_dir/diff.patch" ;;
  "mr list")   cat "$fixtures_dir/list.json" ;;
  "mr note")   : ;;                           # silent success
  "mr merge")  echo "merged" ;;               # silent success
  *)           echo "stub: unknown args: \$*" >&2; exit 99 ;;
esac
EOF
  chmod +x "$FAKE_BIN/glab"
}

# Write a stub `claude` that emits a canned verdict.
# Usage: make_claude_stub <verdict_json>
make_claude_stub() {
  local verdict="$1"
  cat >"$FAKE_BIN/claude" <<EOF
#!/usr/bin/env bash
echo "claude \$*" >>"\$CALL_LOG"
# drain stdin so the caller doesn't block
cat >/dev/null
cat <<VERDICT
$verdict
VERDICT
EOF
  chmod +x "$FAKE_BIN/claude"
}

# Need jq for stubs to be useful. Use the real one.
setup_jq() {
  ln -sf "$(command -v jq)" "$FAKE_BIN/jq"
}

# --- preflight -------------------------------------------------------------

@test "preflight: fails when GITLAB_TOKEN is unset" {
  setup_jq
  make_stub glab    /dev/null
  make_stub claude  /dev/null
  unset GITLAB_TOKEN

  run "$PROJECT_ROOT/bin/review-mr.sh" acme/widgets 1
  [ "$status" -ne 0 ]
  [[ "$output" == *"GITLAB_TOKEN is not set"* ]]
}

@test "preflight: fails when glab is missing" {
  setup_jq
  make_stub claude /dev/null

  run "$PROJECT_ROOT/bin/review-mr.sh" acme/widgets 1
  [ "$status" -ne 0 ]
  [[ "$output" == *"missing required binaries"* ]]
  [[ "$output" == *"glab"* ]]
}

@test "args: --all requires exactly one project" {
  setup_jq
  make_stub glab   /dev/null
  make_stub claude /dev/null

  run "$PROJECT_ROOT/bin/review-mr.sh" --all
  [ "$status" -ne 0 ]
  [[ "$output" == *"--all takes exactly one"* ]]
}

@test "args: single-MR mode requires <project> <iid>" {
  setup_jq
  make_stub glab   /dev/null
  make_stub claude /dev/null

  run "$PROJECT_ROOT/bin/review-mr.sh" acme/widgets
  [ "$status" -ne 0 ]
  [[ "$output" == *"expected <project> <iid>"* ]]
}

# --- eligibility gates ----------------------------------------------------

@test "skips MR that is a draft" {
  setup_jq
  local fx="$TMPDIR_T/fx"; mkdir -p "$fx"
  cat >"$fx/view.json" <<'JSON'
{"state":"opened","draft":true,"has_conflicts":false,"target_branch":"main","title":"WIP","description":"","head_pipeline":{"status":"success"}}
JSON
  echo "" >"$fx/diff.patch"
  echo "[]" >"$fx/list.json"
  make_glab_stub "$fx"
  make_claude_stub '{"approved":true,"blocking":[],"suggestions":[],"summary":"n/a"}'

  run "$PROJECT_ROOT/bin/review-mr.sh" acme/widgets 7
  [ "$status" -eq 0 ]
  [[ "$output" == *'"action": "skipped"'* ]]
  [[ "$output" == *"draft"* ]]
  # Must NOT have invoked claude or merged.
  ! grep -q '^claude ' "$CALL_LOG"
  ! grep -q '^glab mr merge' "$CALL_LOG"
}

@test "skips MR with merge conflicts" {
  setup_jq
  local fx="$TMPDIR_T/fx"; mkdir -p "$fx"
  cat >"$fx/view.json" <<'JSON'
{"state":"opened","draft":false,"has_conflicts":true,"target_branch":"main","title":"x","description":"","head_pipeline":{"status":"success"}}
JSON
  echo "" >"$fx/diff.patch"
  echo "[]" >"$fx/list.json"
  make_glab_stub "$fx"
  make_claude_stub '{"approved":true,"blocking":[],"suggestions":[],"summary":"n/a"}'

  run "$PROJECT_ROOT/bin/review-mr.sh" acme/widgets 7
  [ "$status" -eq 0 ]
  [[ "$output" == *'"action": "skipped"'* ]]
  [[ "$output" == *"conflicts"* ]]
  ! grep -q '^glab mr merge' "$CALL_LOG"
}

@test "skips MR with failing pipeline" {
  setup_jq
  local fx="$TMPDIR_T/fx"; mkdir -p "$fx"
  cat >"$fx/view.json" <<'JSON'
{"state":"opened","draft":false,"has_conflicts":false,"target_branch":"main","title":"x","description":"","head_pipeline":{"status":"failed"}}
JSON
  echo "" >"$fx/diff.patch"
  echo "[]" >"$fx/list.json"
  make_glab_stub "$fx"
  make_claude_stub '{"approved":true,"blocking":[],"suggestions":[],"summary":"n/a"}'

  run "$PROJECT_ROOT/bin/review-mr.sh" acme/widgets 7
  [ "$status" -eq 0 ]
  [[ "$output" == *'"action": "skipped"'* ]]
  [[ "$output" == *"pipeline failed"* ]]
  ! grep -q '^glab mr merge' "$CALL_LOG"
}

@test "skips MR targeting a non-canonical branch" {
  setup_jq
  local fx="$TMPDIR_T/fx"; mkdir -p "$fx"
  cat >"$fx/view.json" <<'JSON'
{"state":"opened","draft":false,"has_conflicts":false,"target_branch":"develop","title":"x","description":"","head_pipeline":{"status":"success"}}
JSON
  echo "" >"$fx/diff.patch"
  echo "[]" >"$fx/list.json"
  make_glab_stub "$fx"
  make_claude_stub '{"approved":true,"blocking":[],"suggestions":[],"summary":"n/a"}'

  run "$PROJECT_ROOT/bin/review-mr.sh" acme/widgets 7
  [ "$status" -eq 0 ]
  [[ "$output" == *'"action": "skipped"'* ]]
  [[ "$output" == *"target_branch=develop"* ]]
}

# --- happy paths ----------------------------------------------------------

@test "merges MR when review approves with zero blockers" {
  setup_jq
  local fx="$TMPDIR_T/fx"; mkdir -p "$fx"
  cat >"$fx/view.json" <<'JSON'
{"state":"opened","draft":false,"has_conflicts":false,"target_branch":"main","title":"Tidy","description":"small","head_pipeline":{"status":"success"}}
JSON
  cat >"$fx/diff.patch" <<'PATCH'
--- a/foo
+++ b/foo
@@ -1 +1 @@
-old
+new
PATCH
  echo "[]" >"$fx/list.json"
  make_glab_stub "$fx"
  make_claude_stub '{"approved":true,"blocking":[],"suggestions":["nit: rename foo"],"summary":"Safe."}'

  run "$PROJECT_ROOT/bin/review-mr.sh" acme/widgets 7
  [ "$status" -eq 0 ]
  [[ "$output" == *'"action": "merged"'* ]]
  [[ "$output" == *'"merged": true'* ]]
  grep -q '^glab mr merge 7' "$CALL_LOG"
  # Summary + one suggestion = at least two notes posted.
  [ "$(grep -c '^glab mr note 7' "$CALL_LOG")" -ge 2 ]
}

@test "leaves MR open when review reports blocking issues" {
  setup_jq
  local fx="$TMPDIR_T/fx"; mkdir -p "$fx"
  cat >"$fx/view.json" <<'JSON'
{"state":"opened","draft":false,"has_conflicts":false,"target_branch":"main","title":"Risky","description":"","head_pipeline":{"status":"success"}}
JSON
  cat >"$fx/diff.patch" <<'PATCH'
--- a/foo
+++ b/foo
@@ -1 +1 @@
-safe
+rm -rf /
PATCH
  echo "[]" >"$fx/list.json"
  make_glab_stub "$fx"
  make_claude_stub '{"approved":false,"blocking":["foo:2 calls rm -rf /","missing tests"],"suggestions":[],"summary":"Do not merge."}'

  run "$PROJECT_ROOT/bin/review-mr.sh" acme/widgets 7
  [ "$status" -eq 0 ]
  [[ "$output" == *'"action": "changes_requested"'* ]]
  [[ "$output" == *'"blocking_count": 2'* ]]
  [[ "$output" == *'"merged": false'* ]]
  ! grep -q '^glab mr merge' "$CALL_LOG"
  # Summary + 2 blockers = at least 3 notes posted.
  [ "$(grep -c '^glab mr note 7' "$CALL_LOG")" -ge 3 ]
}

@test "--dry-run posts no notes and does not merge even when approved" {
  setup_jq
  local fx="$TMPDIR_T/fx"; mkdir -p "$fx"
  cat >"$fx/view.json" <<'JSON'
{"state":"opened","draft":false,"has_conflicts":false,"target_branch":"main","title":"Tidy","description":"","head_pipeline":{"status":"success"}}
JSON
  echo "diff" >"$fx/diff.patch"
  echo "[]" >"$fx/list.json"
  make_glab_stub "$fx"
  make_claude_stub '{"approved":true,"blocking":[],"suggestions":[],"summary":"Safe."}'

  run "$PROJECT_ROOT/bin/review-mr.sh" --dry-run acme/widgets 7
  [ "$status" -eq 0 ]
  [[ "$output" == *'"action": "dry-run"'* ]]
  ! grep -q '^glab mr merge' "$CALL_LOG"
  ! grep -q '^glab mr note' "$CALL_LOG"
}

# --- --all mode ------------------------------------------------------------

@test "--all processes every IID returned by glab mr list" {
  setup_jq
  local fx="$TMPDIR_T/fx"; mkdir -p "$fx"
  cat >"$fx/view.json" <<'JSON'
{"state":"opened","draft":false,"has_conflicts":false,"target_branch":"main","title":"x","description":"","head_pipeline":{"status":"success"}}
JSON
  echo "" >"$fx/diff.patch"
  cat >"$fx/list.json" <<'JSON'
[
  {"iid": 11, "draft": false, "work_in_progress": false},
  {"iid": 22, "draft": false, "work_in_progress": false}
]
JSON
  make_glab_stub "$fx"
  make_claude_stub '{"approved":true,"blocking":[],"suggestions":[],"summary":"ok"}'

  run "$PROJECT_ROOT/bin/review-mr.sh" --all acme/widgets
  [ "$status" -eq 0 ]
  # Both MRs got viewed and merged.
  grep -q '^glab mr view 11' "$CALL_LOG"
  grep -q '^glab mr view 22' "$CALL_LOG"
  grep -q '^glab mr merge 11' "$CALL_LOG"
  grep -q '^glab mr merge 22' "$CALL_LOG"
}

@test "--all reports no-op when there are no open MRs" {
  setup_jq
  local fx="$TMPDIR_T/fx"; mkdir -p "$fx"
  echo "{}" >"$fx/view.json"
  echo "" >"$fx/diff.patch"
  echo "[]" >"$fx/list.json"
  make_glab_stub "$fx"
  make_claude_stub '{"approved":true,"blocking":[],"suggestions":[],"summary":"ok"}'

  run "$PROJECT_ROOT/bin/review-mr.sh" --all acme/widgets
  [ "$status" -eq 0 ]
  [[ "$output" == *'"action":"none"'* ]]
  ! grep -q '^glab mr merge' "$CALL_LOG"
}

# --- verdict validation ----------------------------------------------------

@test "fails the MR when the verdict JSON is malformed" {
  setup_jq
  local fx="$TMPDIR_T/fx"; mkdir -p "$fx"
  cat >"$fx/view.json" <<'JSON'
{"state":"opened","draft":false,"has_conflicts":false,"target_branch":"main","title":"x","description":"","head_pipeline":{"status":"success"}}
JSON
  echo "diff" >"$fx/diff.patch"
  echo "[]" >"$fx/list.json"
  make_glab_stub "$fx"
  # Missing required keys.
  make_claude_stub '{"approved":"yes"}'

  run "$PROJECT_ROOT/bin/review-mr.sh" acme/widgets 7
  [ "$status" -ne 0 ]
  [[ "$output" == *"verdict JSON failed validation"* ]]
  ! grep -q '^glab mr merge' "$CALL_LOG"
}

@test "review::invoke_claude is called without --output-format json" {
  setup_jq
  local fx="$TMPDIR_T/fx"; mkdir -p "$fx"
  cat >"$fx/view.json" <<'JSON'
{"state":"opened","draft":false,"has_conflicts":false,"target_branch":"main","title":"x","description":"","head_pipeline":{"status":"success"}}
JSON
  echo "diff" >"$fx/diff.patch"
  echo "[]" >"$fx/list.json"
  make_glab_stub "$fx"

  # This stub records its own argv. If --output-format json is passed,
  # the stub will record it. We assert it is NOT present.
  cat >"$FAKE_BIN/claude" <<'EOF'
#!/usr/bin/env bash
echo "claude $*" >>"$CALL_LOG"
cat >/dev/null
cat <<VERDICT
{"approved":true,"blocking":[],"suggestions":[],"summary":"ok"}
VERDICT
EOF
  chmod +x "$FAKE_BIN/claude"

  run "$PROJECT_ROOT/bin/review-mr.sh" acme/widgets 7
  [ "$status" -eq 0 ]
  # Must use --output-format text, not the envelope-wrapping json variant.
  ! grep -q -- '--output-format json' "$CALL_LOG"
  grep -q  -- '--output-format text' "$CALL_LOG"
}
