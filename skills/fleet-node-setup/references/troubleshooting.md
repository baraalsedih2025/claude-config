# Troubleshooting

Symptoms observed on real nodes, and what they actually were.

## "No drift on this host"

`install.sh` never ran. Without the symlinks, the live config is not in the
repo at all, so there is structurally nothing to detect. Not "in sync" —
"not wired in".

Check: is `~/.claude/CLAUDE.md` a symlink into the repo, or a real file?

## A merged change never reaches a host

Nothing pulls. Both scripts now fast-forward main at start via
`scripts/lib/pull.sh`; if a host predates that, it pushes drift up forever
and never receives anything.

The pull must **check out** main, not merely update the ref — the live
symlinks point at the working tree, so updating the ref alone changes
nothing on disk.

Rules for that pull: fast-forward only, never merge/rebase/force. Dirty tree
means skip the pull, log loudly, and continue with the sync — local drift
must not be clobbered before it has been captured. Diverged main means abort
and log, never resolve unattended.

## The script deletes itself mid-run

`fleet-sync.sh` was tracked on one PR's branch but absent from `origin/main`.
Its own `git checkout -B <new> origin/main` removed it from disk while it was
running. Bash had already read the file, so the run completed normally and
the script vanished silently.

This recurs for any script not yet merged to main. Merge the script's own PR
before relying on scheduled runs.

## A locally edited config shows as repo drift

Expected. `install.sh` symlinks the live paths into the repo, so editing
`~/.claude/CLAUDE.md` **is** editing the repo. That is the mechanism by which
local learning becomes fleet knowledge.

Sort it before committing: fleet-wide (shared `CLAUDE.md`, `skills/`,
`commands/`) versus host-only (belongs in `hosts/<NAME>.md`). Flag anything
in a shared file that reads host-specific.

## Two hosts edited the same section differently

That is a signal the instruction is host-specific and should be split into
`hosts/` files — not merged into one compromise wording.

## A skill stopped working after onboarding

`install.sh` symlinked `~/.claude/skills` into the repo, and the repo's
`skills/` held only `.gitkeep`. The host's local skills are intact in
`~/.claude/backups/<UTC>/` but no longer active.

Copy them into the repo (secret-scan first — provisioning skills tend to
contain password placeholders that read as findings) and re-run
`install.sh`.

## gh push succeeds but the PR 403s

Push auth and `gh` auth are separate. The remote may be SSH while `gh` is
authenticated as a different account.

Verify both independently. Use `gh api user`, not `gh auth status` — the
latter reports stale and invalid logins as though they were live.

## A revoked token still works

Classic PATs and fine-grained tokens live on **different** GitHub settings
pages. Revoking on one page does not touch the other. Re-test explicitly
after revoking rather than assuming it took.

## The scanner passed but should not have

See `testing-the-hook.md`. Three distinct causes seen: the credential type
was outside the ruleset, the test credential was in an allowlist, and a
check sat after the early-exit it was meant to guard (a gitignored `.env`
makes the tree look clean, so a credential-file check placed after the
clean-tree exit never runs against the case it exists for).

## Counts from a transcript grep are inflated

Substring searches over transcripts match the assistant's own output, not
just the user's messages. A "666 OOM references" figure filtered down to one
real mention.

Never build a ranked failure-mode table from raw grep counts. Filter to user
turns, and if the result is thin, mark the section unmeasured rather than
publishing invented rows. A confident wrong runbook sends someone past the
real cause.

## A long-uptime service is assumed healthy

Uptime is not evidence of startability. A container up 47 days could not have
restarted — it demanded a GPU memory fraction that was no longer free, and
would have died at the next host reboot with nobody knowing why. It was found
only because an unrelated key rotation forced a recreate.

Long-uptime services on shared hosts are unverified until recreated. Check
restartability deliberately rather than waiting for a reboot to find out.
