#!/usr/bin/env bash
#
# review-mr.sh — autonomously review a GitLab Merge Request and merge it if the
# review finds no blocking issues.
#
# Usage:
#   review-mr.sh [--dry-run] <project> <iid>
#   review-mr.sh [--dry-run] <iid>            (uses REVIEW_PROJECT from env)
#   review-mr.sh [--dry-run] --all <project>
#   review-mr.sh [--dry-run] --all            (uses REVIEW_PROJECT from env)
#
# Env:
#   GITLAB_TOKEN          required, PAT with `api` scope
#   GITLAB_HOST           default: gitlab.com
#   REVIEW_PROJECT        default project path (e.g. acme/widgets)
#   REVIEW_TARGET_BRANCH  default: main
#   CLAUDE_BIN            default: claude
#   REVIEW_DEBUG=1        verbose debug logging

set -euo pipefail

SCRIPT_DIR="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)"
readonly SCRIPT_DIR
PROJECT_ROOT="$(cd -- "$SCRIPT_DIR/.." && pwd)"
readonly PROJECT_ROOT

# shellcheck source=../lib/log.sh
source "$PROJECT_ROOT/lib/log.sh"
# shellcheck source=../lib/gitlab.sh
source "$PROJECT_ROOT/lib/gitlab.sh"
# shellcheck source=../lib/review.sh
source "$PROJECT_ROOT/lib/review.sh"

readonly PROMPT_TEMPLATE="$PROJECT_ROOT/prompts/review-prompt.tpl"

DRY_RUN=0
ALL_MODE=0
PROJECT=""
IID=""

# Files registered here are removed on script exit. Functions that mktemp
# should call `track_tmp <path>` instead of installing their own RETURN trap;
# RETURN traps interact badly with `set -u` once their locals fall out of scope.
TMP_FILES=()
track_tmp() { TMP_FILES+=("$1"); }
cleanup_tmp() {
  if (( ${#TMP_FILES[@]} > 0 )); then
    rm -f "${TMP_FILES[@]}"
  fi
  return 0
}
trap cleanup_tmp EXIT

usage() {
  sed -n '/^# review-mr.sh/,/^$/p' "$0" | sed 's/^# \{0,1\}//'
  exit "${1:-0}"
}

parse_args() {
  while [[ $# -gt 0 ]]; do
    case "$1" in
      --dry-run) DRY_RUN=1; shift ;;
      --all)     ALL_MODE=1; shift ;;
      -h|--help) usage 0 ;;
      --) shift; break ;;
      -*) log::error "unknown flag: $1"; usage 2 ;;
      *)  break ;;
    esac
  done

  if (( ALL_MODE )); then
    if [[ $# -eq 1 ]]; then
      PROJECT="$1"
    elif [[ $# -eq 0 && -n "${REVIEW_PROJECT:-}" ]]; then
      PROJECT="$REVIEW_PROJECT"
    else
      log::error "--all requires a <project> argument or REVIEW_PROJECT set in env"
      usage 2
    fi
  else
    if [[ $# -eq 2 ]]; then
      PROJECT="$1"
      IID="$2"
    elif [[ $# -eq 1 && -n "${REVIEW_PROJECT:-}" ]]; then
      PROJECT="$REVIEW_PROJECT"
      IID="$1"
    else
      log::error "expected <project> <iid>, or set REVIEW_PROJECT in env and pass only <iid>"
      usage 2
    fi
  fi
}

preflight() {
  local missing=()
  for bin in glab jq "${CLAUDE_BIN:-claude}"; do
    command -v "$bin" >/dev/null 2>&1 || missing+=("$bin")
  done
  if (( ${#missing[@]} )); then
    log::error "missing required binaries: ${missing[*]}"
    exit 1
  fi
  if [[ -z "${GITLAB_TOKEN:-}" ]]; then
    log::error "GITLAB_TOKEN is not set"
    exit 1
  fi
  export GITLAB_HOST="${GITLAB_HOST:-gitlab.com}"
}

# Echoes a one-line reason if the MR should be skipped; empty if eligible.
eligibility_reason() {
  local mr_json="$1" target_branch="$2"

  local state draft conflicts target pipeline
  state="$(    echo "$mr_json" | jq -r '.state // empty')"
  draft="$(    echo "$mr_json" | jq -r '.draft // .work_in_progress // false')"
  conflicts="$(echo "$mr_json" | jq -r '.has_conflicts // false')"
  target="$(   echo "$mr_json" | jq -r '.target_branch // empty')"
  pipeline="$( echo "$mr_json" | gitlab::pipeline_status)"

  [[ "$state"     == "opened" ]]         || { echo "state=$state (not opened)"; return; }
  [[ "$draft"     == "false"  ]]         || { echo "MR is draft";                 return; }
  [[ "$conflicts" == "false"  ]]         || { echo "MR has merge conflicts";      return; }
  [[ "$target"    == "$target_branch" ]] || { echo "target_branch=$target (want $target_branch)"; return; }

  case "$pipeline" in
    success|"") : ;;  # success or no pipeline = ok
    failed)     echo "pipeline failed"; return ;;
    running|pending|created|waiting_for_resource|preparing)
                echo "pipeline still running ($pipeline)"; return ;;
    canceled|skipped|manual)
                echo "pipeline status=$pipeline; needs human"; return ;;
    *)          echo "unknown pipeline status: $pipeline"; return ;;
  esac
}

# Renders prompt, calls Claude, validates JSON. Echoes verdict JSON to stdout.
run_review() {
  local mr_json="$1" diff_path="$2"
  local title description prompt_path verdict

  title="$(      echo "$mr_json" | jq -r '.title       // ""')"
  description="$(echo "$mr_json" | jq -r '.description // ""')"

  prompt_path="$(mktemp)"
  track_tmp "$prompt_path"
  review::render_prompt "$PROMPT_TEMPLATE" "$title" "$description" "$diff_path" >"$prompt_path"

  log::debug "prompt rendered to $prompt_path ($(wc -l <"$prompt_path") lines)"

  verdict="$(review::invoke_claude "$prompt_path")"

  if ! review::validate_verdict "$verdict"; then
    log::error "verdict JSON failed validation: $verdict"
    return 1
  fi
  echo "$verdict"
}

# Posts the summary plus one note per blocking issue and per suggestion.
post_feedback() {
  local project="$1" iid="$2" verdict="$3"
  local summary

  summary="$(echo "$verdict" | jq -r '.summary')"
  printf '### Autonomous review summary\n\n%s\n' "$summary" \
    | gitlab::mr_note "$project" "$iid"

  echo "$verdict" | jq -r '.blocking[]?' | while IFS= read -r issue; do
    [[ -n "$issue" ]] || continue
    printf '🚫 **Blocking:** %s\n' "$issue" | gitlab::mr_note "$project" "$iid"
  done

  echo "$verdict" | jq -r '.suggestions[]?' | while IFS= read -r sug; do
    [[ -n "$sug" ]] || continue
    printf '💡 **Suggestion:** %s\n' "$sug" | gitlab::mr_note "$project" "$iid"
  done
}

# Reviews and (if appropriate) merges a single MR. Echoes one JSON line to stdout.
process_mr() {
  local project="$1" iid="$2"
  local mr_json reason verdict approved blocker_count action="skipped" merged=false

  log::info "fetching MR $project!$iid"
  mr_json="$(gitlab::mr_view "$project" "$iid")"

  reason="$(eligibility_reason "$mr_json" "${REVIEW_TARGET_BRANCH:-main}")"
  if [[ -n "$reason" ]]; then
    log::warn "skipping MR !$iid: $reason"
    jq -n --arg p "$project" --argjson i "$iid" --arg r "$reason" \
      '{project: $p, iid: $i, action: "skipped", reason: $r, merged: false}'
    return 0
  fi

  local diff_path
  diff_path="$(mktemp)"
  track_tmp "$diff_path"
  gitlab::mr_diff "$project" "$iid" >"$diff_path"

  log::info "running review for MR !$iid"
  verdict="$(run_review "$mr_json" "$diff_path")"

  approved="$(     echo "$verdict" | jq -r '.approved')"
  blocker_count="$(echo "$verdict" | jq '.blocking | length')"

  if (( DRY_RUN )); then
    log::info "dry-run: would post feedback and ${approved/true/merge} MR !$iid"
    action="dry-run"
  else
    post_feedback "$project" "$iid" "$verdict"
    if [[ "$approved" == "true" && "$blocker_count" -eq 0 ]]; then
      log::info "merging MR !$iid"
      if gitlab::mr_merge "$project" "$iid"; then
        action="merged"
        merged=true
      else
        log::error "merge of MR !$iid failed — leaving open"
        action="merge_failed"
      fi
    else
      log::info "leaving MR !$iid open ($blocker_count blocking issue(s))"
      action="changes_requested"
    fi
  fi

  jq -n \
    --arg p "$project" \
    --argjson i "$iid" \
    --arg a "$action" \
    --argjson b "$blocker_count" \
    --argjson m "$merged" \
    --argjson v "$verdict" \
    '{project: $p, iid: $i, action: $a, blocking_count: $b, merged: $m, verdict: $v}'
}

main() {
  parse_args "$@"
  preflight

  local exit_code=0
  if (( ALL_MODE )); then
    local target="${REVIEW_TARGET_BRANCH:-main}"
    log::info "discovering open MRs in $PROJECT targeting $target"
    local iids
    iids="$(gitlab::list_open_mrs "$PROJECT" "$target")"
    if [[ -z "$iids" ]]; then
      log::info "no eligible MRs"
      echo '{"action":"none","reason":"no open MRs"}'
      return 0
    fi
    while IFS= read -r iid; do
      [[ -n "$iid" ]] || continue
      process_mr "$PROJECT" "$iid" || exit_code=$?
    done <<<"$iids"
  else
    process_mr "$PROJECT" "$IID" || exit_code=$?
  fi
  return "$exit_code"
}

main "$@"
