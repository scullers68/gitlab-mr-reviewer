# gitlab-mr-reviewer

Autonomous GitLab Merge Request reviewer. Fetches an MR, runs a Claude-powered
code review on the diff, posts findings as MR notes, and merges into the target
branch when the review finds no blocking issues.

## What it does

For each Merge Request:

1. **Gate** — skip if draft, has merge conflicts, or pipeline is failing/running.
2. **Review** — fetch the diff and invoke the `gitlab-mr-reviewer` Claude agent,
   which returns a structured verdict: `{ approved, blocking[], suggestions[], summary }`.
3. **Post feedback** — write the summary as an MR note; emit one note per blocking
   issue (`🚫 Blocking:`) and per suggestion (`💡 Suggestion:`).
4. **Decide** — if `approved == true` and `blocking` is empty, run
   `glab mr merge --yes --remove-source-branch`. Otherwise leave the MR open
   with the review feedback attached.

The script emits one JSON line per MR to stdout and a human-readable summary at
the end, so it composes cleanly into CI and other automation.

## Requirements

- [`glab`](https://gitlab.com/gitlab-org/cli) on `PATH`
- [`jq`](https://jqlang.github.io/jq/) on `PATH`
- [`claude`](https://docs.claude.com/en/docs/claude-code) CLI on `PATH`
- A GitLab Personal Access Token with the `api` scope

## Install

```bash
git clone https://github.com/scullers68/gitlab-mr-reviewer ~/projects/gitlab-mr-reviewer
cd ~/projects/gitlab-mr-reviewer
cp .env.example .env
# edit .env and set GITLAB_TOKEN
```

To make the `/gitlab-review-mr` slash command available to Claude Code globally,
symlink the skill and agent into your user-level Claude config:

```bash
ln -s "$(pwd)/.claude/skills/gitlab-review-mr"     ~/.claude/skills/gitlab-review-mr
ln -s "$(pwd)/.claude/agents/gitlab-mr-reviewer.md" ~/.claude/agents/gitlab-mr-reviewer.md
```

Or just run the script directly — the skill is a convenience wrapper.

## Usage

```bash
# Load credentials
set -a; source .env; set +a

# Review one MR
./bin/review-mr.sh acme/widgets 42

# Review every open MR in a project
./bin/review-mr.sh --all acme/widgets

# Dry run — review and print verdict, but post no comments and do not merge
./bin/review-mr.sh --dry-run acme/widgets 42

# If REVIEW_PROJECT=acme/widgets is set in .env, the project can be omitted
./bin/review-mr.sh 42
./bin/review-mr.sh --all
```

From inside Claude Code, after installing the skill:

```
/gitlab-review-mr acme/widgets 42
/gitlab-review-mr --all acme/widgets
```

## Configuration

All configuration is via environment variables (see `.env.example`):

| Var | Default | Purpose |
|---|---|---|
| `GITLAB_TOKEN` | _required_ | Personal Access Token with `api` scope |
| `GITLAB_HOST` | `gitlab.com` | Host for self-hosted instances |
| `REVIEW_PROJECT` | _unset_ | Default project path (e.g. `mygroup/myrepo`); omit `<project>` from CLI when set |
| `REVIEW_TARGET_BRANCH` | `main` | Only MRs targeting this branch are eligible |
| `CLAUDE_BIN` | `claude` | Override the Claude CLI binary path |
| `REVIEW_DEBUG` | _unset_ | Set to `1` for verbose debug logging to stderr |

## Safety model

- **Never merges** if the pipeline is failing, the MR has conflicts, it's a
  draft, or the target branch doesn't match `REVIEW_TARGET_BRANCH`.
- **Never merges** if the review returns even a single blocking issue.
- **`--dry-run`** prints the verdict without posting or merging — use this to
  vet the behavior on a real MR before going hands-off.
- Feedback is always posted, even when the MR is merged, so the audit trail
  lives on the MR itself.

## Testing

```bash
bats tests/
```

Tests stub `glab` and `claude` so they run without network or credentials.

## Layout

```
gitlab-mr-reviewer/
├── bin/review-mr.sh            # Entry point
├── lib/                        # gitlab.sh, review.sh, log.sh
├── prompts/review-prompt.tpl   # Prompt fed to the reviewer agent
├── .claude/
│   ├── skills/gitlab-review-mr/SKILL.md
│   └── agents/gitlab-mr-reviewer.md
└── tests/review-mr.bats
```
