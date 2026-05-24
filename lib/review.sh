#!/usr/bin/env bash
# Builds the review prompt and invokes the Claude CLI to get a structured verdict.
# Sourced by review-mr.sh.

# Render the prompt template by substituting placeholders.
# Args: <template_path> <mr_title> <mr_description> <diff_path>
# Stdout: rendered prompt.
review::render_prompt() {
  local template="$1" title="$2" description="$3" diff_path="$4"
  local diff
  diff="$(<"$diff_path")"
  # Use awk to substitute, so newlines in $diff/$description survive intact.
  awk -v title="$title" -v description="$description" -v diff="$diff" '
    {
      gsub(/\{\{MR_TITLE\}\}/, title)
      gsub(/\{\{MR_DESCRIPTION\}\}/, description)
      gsub(/\{\{MR_DIFF\}\}/, diff)
      print
    }
  ' "$template"
}

# Invoke Claude with the rendered prompt. Expects the CLI to return JSON.
# Args: <rendered_prompt_path>
# Stdout: JSON verdict.
review::invoke_claude() {
  local prompt_path="$1"
  local claude_bin="${CLAUDE_BIN:-claude}"
  "$claude_bin" \
    -p \
    --agent gitlab-mr-reviewer \
    --output-format text \
    --max-turns 1 \
    < "$prompt_path"
}

# Validate the structure of the verdict JSON. Returns 0 on success.
# Required shape: { approved: bool, blocking: [str], suggestions: [str], summary: str }
review::validate_verdict() {
  local json="$1"
  echo "$json" | jq -e '
    (.approved | type == "boolean") and
    (.blocking | type == "array") and
    (.suggestions | type == "array") and
    (.summary | type == "string")
  ' >/dev/null
}
