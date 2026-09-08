# fleet-config-sync

This repo's own automation: nightly collection of per-host Claude Code config
drift into a pull request, and a nightly transcript review that proposes config
changes.

**Status: DOCUMENTED 2026-09-08.** **[M]** machine-verified, **[C]** needs
confirmation, or `unknown — nobody knows`.

## What it does

**[M]** Two independent scripts, both gated behind human review:

| Script | Runs | Produces |
|---|---|---|
| `scripts/fleet-sync.sh` | 03:30 daily (cron) | a `sync/<date>-<host>` branch + PR of this host's uncommitted config drift |
| `scripts/nightly-review.sh` | **not scheduled on this host** | a `proposal/<date>-<host>` branch containing one file under `proposals/` |
| `scripts/rag-callers.sh` | on demand | a caller summary from Caddy's access log |

**[M]** Neither script can change `main`. `fleet-sync.sh` branches off
`origin/main` and opens a PR; `nightly-review.sh` refuses to commit anything
except its single proposal file and aborts if anything else is staged.

## Where it runs

| | |
|---|---|
| Repo clone | `/workspace/Bara/claude-config` — **not** the `~/claude-config` default, so `REPO_DIR` must be passed |
| Symlinked into | `~/.claude/CLAUDE.md`, `~/.claude/skills`, `~/.claude/commands` |
| Host identity + auth | `~/.claude-config.env`, mode 600 — `GH_TOKEN`, `CLAUDE_HOST` |
| Schedule | system `cron`, `ubuntu` crontab, 03:30 |
| Log | `~/.claude-fleet-sync.log` |
| Review log | `~/.claude-config-review.log` |

**[M]** `install.sh` creates the symlinks, backing up anything in the way into
`~/.claude/backups/<UTC timestamp>/` first. It is idempotent.

## Health check

```bash
crontab -l | grep fleet-sync
tail -30 ~/.claude-fleet-sync.log
gh pr list --repo <owner>/claude-config --state open
```

**[M]** A clean-tree run logs `working tree clean — nothing to sync` and exits
0 without opening a PR. That is the normal quiet outcome — no PR is not a
failure.

**[M]** The credential check is `gh api user`, deliberately **not**
`gh auth status`. `gh auth status` exits nonzero over a cosmetic warning: a
classic token with only `repo` scope — all this needs — is reported as
"Missing required token scopes: read:org", and any stale stored account also
fails it. That false negative blocked a working credential on 2026-09-08.

## Behaviour worth knowing

**[M]** Verified by test on 2026-09-08:

- **Clean tree → exit 0, no branch, no PR.** Deliberate: nightly empty PRs
  train people to ignore them.
- **Today's branch and PR are reused**, not duplicated. A second run pushes
  into the existing PR.
- **Fails closed** if `gitleaks` or `gh` is missing — no regex fallback for
  secrets.
- **Two secret scans**: `gitleaks dir` over the working tree, plus a
  credential-**filename** pass. The filename pass runs *before* the clean-tree
  exit, because `.gitignore` hides `.env`/`*.key` from `git status` — so a
  credential sitting in the repo leaves the tree looking clean, and a check
  placed after that exit would never run against the only case it exists for.
- **`--exit-code 2`** separates "found a secret" from "the scanner broke". Both
  refuse to commit, but they are different problems.
- **Untracked files that the target branch already tracks** are set aside and
  restored on top, rather than blocking the checkout. That collision is the
  normal second-run state, and `-f` would discard the drift being collected.

**[M]** `nightly-review.sh` also scans the transcripts it reads **before**
handing them to the model, and fails the whole run if any contains a
credential-shaped string. Scanning only its output was insufficient: a token
pasted into a session sits in that input, and the only thing between it and a
committed file would have been the model choosing not to quote it.

## Symptom → diagnosis → fix

**[M]** Observed 2026-09-08.

| Symptom | Cause | Check |
|---|---|---|
| `gitleaks` exits `Unknown report format` on every run | `--report-path` pointed at an extensionless temp file; gitleaks infers format from the extension | fixed by passing `--report-format json` explicitly |
| Run dies at preflight: `gh is not authenticated` while `gh api user` works | preflight used `gh auth status`, which fails on the cosmetic `read:org` warning | fixed by checking `gh api user` |
| Branch checkout aborts: `untracked working tree files would be overwritten` | the target branch already tracks a file that the live config recreated as untracked | the set-aside/restore logic now handles it |
| `git push` returns 403 | the token lacks write scope, or the account lacks repo access | `gh api repos/<owner>/<repo> --jq .permissions` |
| Cron run fails but a manual run works | cron has a bare environment; `GH_TOKEN` must come from `~/.claude-config.env`, and it must be `export`ed | run under `env -i HOME=… PATH=/usr/bin:/bin` to reproduce |

**[M]** That last row is the trap: the scripts *source* the env file and then
invoke `gh`/`git` as **child processes**, so a plain assignment is invisible to
them. `export` is required, not cosmetic.

## Looks broken, isn't

- **[M]** No PR after a nightly run — the tree was clean. Working as designed.
- **[M]** `gh auth status` complaining about `read:org` — that scope is not
  needed; `gh api user` is the real test.
- **[M]** `gh auth status` reporting no logged-in host at all — auth comes from
  `GH_TOKEN` in the env file, with no stored login by design.
- **[M]** This host produces little drift: `~/.claude/skills` etc. are symlinks
  into the repo, so genuine local edits appear as repo changes and everything
  else is quiet.
- **[M]** `nightly-review.sh` not being scheduled here is the current state, not
  a broken timer. The 03:30 slot for `fleet-sync` exists to sit after a 03:00
  review that is **not installed on this host**.

## Do NOT

- **[M] Do not commit to `main`.** Both scripts refuse; do not do by hand what
  they are built to prevent.
- **[M] Never `--no-verify`.** The `gitleaks` pre-commit hook is the last line
  before a credential reaches the remote.
- **[M] Do not put a plain (non-`export`) assignment in `~/.claude-config.env`.**
  Child processes will not see it and cron runs will fail confusingly.
- **[M] Do not delete a stub runbook** to tidy up — that hides a known gap.
- **[M] Do not let `CLAUDE_HOST` go unset.** Branches then get named after the
  machine hostname, which nobody can trace back to a fleet member.

## Undocumented / unknown

- `unknown — nobody knows` — whether `nightly-review.sh` should be scheduled on
  this host, or is deliberately manual.
- `unknown — nobody knows` — whether any other host in the fleet runs these
  scripts. No second host was inspected; `hosts/` contains one other file
  (`sgh-dev.md`) of unknown currency.
- `unknown — nobody knows` — whether anyone other than the owner has ever
  reviewed or merged a sync PR. `oncall.md` B1 records that nobody else can.
- `unknown — nobody knows` — who watches the 03:30 cron for failures. Nothing
  alerts; the log is local to the host.

## Escalation

`unknown — nobody knows`. Note `../oncall.md` **B1**: the repo is on a personal
account, so during an absence nobody else can merge a PR these scripts open —
which makes them documentation-generating rather than actionable.
