---
name: gitlab-review-mr
description: Use when asked to review, approve, or merge GitLab Merge Requests autonomously. Triggers on phrases like "review MR", "review merge request", "merge if green", or "process open MRs". Runs bin/review-mr.sh, which fetches the diff, runs an AI code review, posts findings, and merges when no blocking issues remain.
---

# gitlab-review-mr

Autonomously review a GitLab Merge Request, post feedback, and merge if the
review finds no blocking issues.

## When to use

- The user gives you a GitLab project path + MR IID and asks you to review,
  approve, or merge it.
- The user asks you to triage / merge all open MRs in a GitLab project.
- The user asks for an MR review to be posted as comments on the MR itself,
  not just summarized in chat.

## Inputs

- `<project>` — GitLab project path, e.g. `acme/widgets` or `group/sub/repo`.
- `<iid>` — Merge Request internal ID (the number in the MR URL).
- `--all` — review every open, non-draft MR in the project instead of a single
  one.
- `--dry-run` — run the review and print the verdict, but post no notes and
  do not merge. Use this whenever the user wants to preview behavior.

## Preconditions

Verify before invoking:

1. `GITLAB_TOKEN` is exported in the environment. If not, ask the user to set
   it or to `source .env` from the project root.
2. `glab`, `jq`, and `claude` are on `PATH`. If `glab` is missing, point the
   user at https://gitlab.com/gitlab-org/cli.

## Process

1. Resolve the project root: walk up from the current directory until you find
   `bin/review-mr.sh` of `gitlab-mr-reviewer`, or use
   `~/projects/gitlab-mr-reviewer` if installed there.
2. Invoke the script:
   ```bash
   ./bin/review-mr.sh [--dry-run] <project> <iid>
   ./bin/review-mr.sh [--dry-run] --all <project>
   ```
3. The script emits one JSON line per MR on stdout, plus human-readable logs on
   stderr. Parse the JSON to report back:
   - `action`: `merged`, `changes_requested`, `skipped`, `dry-run`, or `none` (`none` only occurs in `--all` mode when no open MRs exist)
   - `blocking_count`: number of blocking issues raised
   - `merged`: whether the MR was merged
   - `verdict.summary`: the one-paragraph verdict (when present)

## Reporting

After running, summarize to the user:

- Per MR: IID, action taken, blocking count, and a one-line summary.
- If anything was skipped, name the reason (draft, conflicts, failing
  pipeline, wrong target branch).
- Link to the MR(s) so the user can inspect the posted notes.

Do **not** re-paste the full review into chat — it has already been posted on
the MR. A short recap is enough.

## Safety

- Never bypass `--dry-run` if the user requested it.
- Never run with `--all` against an unfamiliar project without first asking
  the user to confirm.
- If the script exits non-zero, surface the stderr to the user; do not retry
  blindly.
