#!/usr/bin/env bash
# Thin wrappers over `glab`. Sourced by review-mr.sh.
#
# All functions assume:
#   GITLAB_TOKEN is exported
#   GITLAB_HOST  is exported (defaulted in the caller)
#   glab and jq are on PATH

# Fetch MR JSON. Stdout: raw JSON from `glab mr view --output json`.
# Exits non-zero if the MR can't be fetched.
gitlab::mr_view() {
  local project="$1" iid="$2"
  glab mr view "$iid" --repo "$project" --output json
}

# Fetch the unified diff for an MR. Stdout: diff text.
gitlab::mr_diff() {
  local project="$1" iid="$2"
  glab mr diff "$iid" --repo "$project"
}

# List open, non-draft MRs targeting $target_branch. Stdout: newline-separated IIDs.
gitlab::list_open_mrs() {
  local project="$1" target_branch="$2"
  glab mr list \
    --repo "$project" \
    --target-branch "$target_branch" \
    --not-draft \
    --output json \
    | jq -r '.[].iid'
}

# Post a comment on an MR. Reads body from stdin.
gitlab::mr_note() {
  local project="$1" iid="$2"
  local body
  body="$(cat)"
  # `glab mr note` reads --message from arg, so pass it explicitly.
  glab mr note "$iid" --repo "$project" --message "$body" >/dev/null
}

# Merge an MR. Squashes, removes source branch on success.
gitlab::mr_merge() {
  local project="$1" iid="$2"
  glab mr merge "$iid" \
    --repo "$project" \
    --yes \
    --squash \
    --remove-source-branch
}

# Extract a single field from the MR JSON blob on stdin.
# Usage:  echo "$mr_json" | gitlab::field state
gitlab::field() {
  local key="$1"
  jq -r --arg k "$key" '.[$k] // empty'
}

# Nested pipeline status. Returns "success", "failed", "running", "canceled",
# "skipped", "manual", or empty string if no head pipeline exists.
gitlab::pipeline_status() {
  jq -r '.head_pipeline.status // empty'
}
