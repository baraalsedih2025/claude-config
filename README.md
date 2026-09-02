# claude-config

Shared Claude Code configuration for the fleet. One repo, symlinked into
`~/.claude` on every server, plus a nightly job that proposes improvements from
what actually happened in sessions.

```
CLAUDE.md              global instructions — symlinked to ~/.claude/CLAUDE.md
skills/                shared skills, one directory per skill
commands/              shared slash commands, one .md per command
hosts/<hostname>.md    per-host notes and overrides (never auto-linked)
scripts/install.sh     onboard a machine
scripts/nightly-review.sh   nightly transcript review -> proposal branch
proposals/             nightly output, one file per host per day
```

## Onboarding a new server

```sh
git clone <REMOTE_URL> ~/claude-config
REPO_URL=<REMOTE_URL> ~/claude-config/scripts/install.sh
```

The installer pulls the repo and symlinks three paths:

| link | target |
| --- | --- |
| `~/.claude/CLAUDE.md` | `~/claude-config/CLAUDE.md` |
| `~/.claude/skills` | `~/claude-config/skills` |
| `~/.claude/commands` | `~/claude-config/commands` |

It is idempotent — re-running it on an already-linked host does nothing. Anything
already sitting at one of those paths is copied into
`~/.claude/backups/<UTC timestamp>/` **before** being replaced; if the backup
copy fails, the installer aborts rather than touching the original. Preview with
`DRY_RUN=1 scripts/install.sh`.

Not symlinked, deliberately: `~/.claude/settings.json` (holds machine-specific
model, status line and attribution settings) and `~/.claude/projects/`
(transcripts and per-project memory — session data, never shared).

### Per-host overrides

Drop notes for a single machine in `hosts/$(hostname).md`. Nothing reads it
automatically; if you want it active on that host, reference it from `CLAUDE.md`
or paste the relevant lines in. Keeping it out of the symlink path is what stops
one host's quirks from leaking into everyone else's instructions.

## The review / merge flow

`scripts/nightly-review.sh` runs at 03:00 (see [Cron](#cron)) and:

1. finds transcripts under `~/.claude/projects/` modified in the last 24h
2. runs `claude -p` over them in `--permission-mode plan` (read-only) asking what
   repeated corrections, workflows and preferences are *not* already in
   `CLAUDE.md` or `skills/`
3. writes the answer to `proposals/YYYY-MM-DD-$(hostname).md`
4. scans that file for secrets, and discards it if anything matches
5. commits it on `proposal/YYYY-MM-DD-$(hostname)` and pushes that branch

**The job never commits to `main`, and never edits `CLAUDE.md`, `skills/` or
`commands/`.** It adds exactly one file under `proposals/` and aborts if anything
else ends up staged. Every actual config change is yours to make:

```sh
git fetch origin
git branch -r --list 'origin/proposal/*'          # what is waiting
git log -p origin/proposal/2026-09-02-myhost      # read one
```

If a proposal is worth taking, apply it yourself on a normal branch — edit
`CLAUDE.md` or add the skill by hand, keeping only the parts you agree with —
then merge to `main`. Merging the proposal branch itself only lands the
`proposals/` record, which is fine if you want the paper trail. Hosts pick the
change up on their next `install.sh` run or `git -C ~/claude-config pull`.

Delete stale proposal branches freely; the file in `proposals/` is a record, not
state anything depends on.

### Running it by hand

```sh
NO_PUSH=1 ~/claude-config/scripts/nightly-review.sh
tail -f ~/.claude-config-review.log
```

`NO_PUSH=1` does everything except the push. The script logs to
`~/.claude-config-review.log` and exits nonzero on any failure — including a
dirty working tree, a missing `origin`, a `claude -p` failure, or a secret in the
generated output.

## Rolling back

**A bad config change on one host** — point back at a known-good commit:

```sh
git -C ~/claude-config checkout <good-sha>   # detached; `git checkout main` to rejoin
```

The symlinks follow the working tree, so this takes effect immediately with no
re-install.

**A bad change for everyone** — revert on `main` and let hosts pull:

```sh
git -C ~/claude-config revert <bad-sha>
git -C ~/claude-config push origin main
```

**Undo the install entirely** — restore the pre-install files:

```sh
ls ~/.claude/backups/                     # pick the timestamp from install time
rm ~/.claude/CLAUDE.md ~/.claude/skills ~/.claude/commands   # these are symlinks
cp -a ~/.claude/backups/<timestamp>/. ~/.claude/
```

Removing the symlinks never touches repo content — the files live in
`~/claude-config`.

## Cron

Not installed. Add it with `crontab -e` on each host:

```cron
# Nightly Claude config review at 03:00 — writes a proposal branch, never main.
# 0 3 * * * /bin/bash "$HOME/claude-config/scripts/nightly-review.sh"
```

Cron runs with a minimal `PATH`; the script prepends `~/.nvm/versions/node/*/bin`
and `~/.local/bin` itself so an nvm-managed `claude` is found. It needs push
credentials available non-interactively — an SSH key with no passphrase (or one
loaded in an agent cron can reach), or a credential helper.

Stagger the minute across hosts if many push at once.

## Secrets

Nothing secret goes in this repo — no tokens, keys, `.env` values or connection
strings. `.gitignore` blocks the usual suspects (`.env*`, `*.pem`, `*.key`,
`*credentials*`, `*secret*`, `*token*`, `*.jsonl`), and `nightly-review.sh`
pattern-scans generated proposals before staging them. Both are backstops, not a
substitute for reading a diff before merging it.
