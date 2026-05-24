#!/usr/bin/env bash
# Builds the review prompt and invokes the Claude CLI to get a structured verdict.
# Sourced by review-mr.sh.

# Render the prompt template by substituting placeholders.
# Args: <template_path> <mr_title> <mr_description> <diff_path>
# Stdout: rendered prompt.
review::render_prompt() {
  local template="$1" title="$2" description="$3" diff_path="$4"
  local t_file d_file
  # Write values to temp files so newlines survive (awk -v rejects embedded newlines).
  t_file="$(mktemp)"
  d_file="$(mktemp)"
  track_tmp "$t_file"
  track_tmp "$d_file"
  printf '%s' "$title"       > "$t_file"
  printf '%s' "$description" > "$d_file"
  # Use index()/substr() substitution — unlike gsub(), this treats replacement
  # values as plain strings with no special-character interpretation.
  awk -v tf="$t_file" -v df="$d_file" -v rf="$diff_path" '
    function replace_all(str, old, new,    result, i) {
      result = ""
      while ((i = index(str, old)) > 0) {
        result = result substr(str, 1, i-1) new
        str = substr(str, i + length(old))
      }
      return result str
    }
    BEGIN {
      while ((getline line < tf) > 0) title       = (title       == "") ? line : title       "\n" line
      close(tf)
      while ((getline line < df) > 0) description = (description == "") ? line : description "\n" line
      close(df)
      while ((getline line < rf) > 0) diff        = (diff        == "") ? line : diff        "\n" line
      close(rf)
    }
    {
      line = $0
      line = replace_all(line, "{{MR_TITLE}}",       title)
      line = replace_all(line, "{{MR_DESCRIPTION}}", description)
      line = replace_all(line, "{{MR_DIFF}}",        diff)
      print line
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
