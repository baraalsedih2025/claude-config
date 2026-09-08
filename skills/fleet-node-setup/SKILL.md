---
name: fleet-node-setup
description: Onboard a new server as a node in the shared Claude config fleet (repo baraalsedih2025/claude-config) — clone, pin a host name, symlink the live config, install gitleaks and the pre-commit hook, schedule the nightly sync, and open a PR. Use this whenever a new machine needs to join the fleet, or someone says "add this server", "onboard this box", "set up Claude config here", "wire this host into the sync repo", or asks why a host isn't picking up merged config changes. Also use it to audit an existing node that isn't syncing.
---

# Fleet node setup

Wires a new server into the shared Claude config repo so its instructions,
skills, commands, runbooks and decisions stay in sync with every other host.

**Repo:** `https://github.com/baraalsedih2025/claude-config`

## The model

The repo is the hub. Hosts push drift up as branches and PRs; the operator
merges; hosts pull main back down on the next scheduled run. Two scripts do
the work, both living in the repo:

| Script | Reads | Produces |
|---|---|---|
| `nightly-review.sh` (03:00) | Yesterday's transcripts | A proposal branch suggesting instruction changes |
| `fleet-sync.sh` (03:30) | The repo diff | A branch + PR carrying whatever changed on disk |

Both begin by fast-forwarding main via `scripts/lib/pull.sh`. Because the live
config paths are symlinks into the working tree, a pull takes effect
immediately — no reinstall, no restart.

Nothing merges automatically. That gate is deliberate: an agent silently
rewriting its own instructions across a fleet is the failure this design
exists to prevent.

## Order of operations

Do these in order. Later steps depend on earlier ones.

### 1. Verify the remote before anything else

```sh
cd ~/claude-config && git remote -v
```

Must be `https://github.com/baraalsedih2025/claude-config`. If it is missing,
different, or unreachable — **stop and ask**. Never guess a remote, never add
one unprompted. HTTPS needs `GH_TOKEN`; SSH needs a key belonging to the repo
owner's account.

### 2. Pin the host name

Ask the operator for a name. **Never invent one, and never fall back to
`hostname`.** See `references/host-naming.md` for why — this is the single
most common source of rework.

```sh
umask 077
printf 'CLAUDE_HOST=%s\n' "<NAME>" > ~/.claude-config.env
chmod 600 ~/.claude-config.env
```

The name flows into `hosts/<NAME>.md`, into branch names
(`sync/<date>-<NAME>`), and into the container-ID warning in `install.sh`.

### 3. Run install.sh

```sh
scripts/install.sh
```

It symlinks `~/.claude/CLAUDE.md`, `~/.claude/skills` and `~/.claude/commands`
into the repo, backing up anything it replaces into
`~/.claude/backups/<UTC>/`. It is idempotent and honours `DRY_RUN=1`.

**Report what it backed up, then act on it.** A host with local skills will
have them deactivated by the symlink — the repo's `skills/` may hold only
`.gitkeep`. Copy them into the repo (secret-scan first) or they are silently
lost. This has happened on every host onboarded so far.

Until this step runs, the host produces no drift and both nightly jobs
correctly find nothing. "No drift" on a fresh node usually means
`install.sh` never ran, not that the host is in sync.

### 4. Install gitleaks and verify the hook

Organization policy requires an approved secret scanner before every commit,
and requires stopping rather than proceeding when it is unavailable. There is
no manual-review exemption.

```sh
gitleaks version    # if absent, fetch the GitHub release binary to ~/.local/bin
```

Note the v8 command surface: `git`, `dir`, `stdin`. `protect` and `detect` no
longer exist; the staged scan is `gitleaks git --staged`. Check `--help` on the
actual build rather than trusting any flag list.

Then **test that the hook actually blocks**, using a fabricated GitHub PAT —
not an AWS key. See `references/testing-the-hook.md`. A hook that passes
because the test credential was undetectable is worse than no hook, because
it will be trusted.

Confirm fail-closed: with gitleaks hidden from `PATH`, the hook must refuse,
not pass.

### 5. Create the host file

`hosts/<NAME>.md` holds facts true of this machine only: non-default paths,
port assignments, container names, tenant identifiers, scheduler quirks,
anything that would be wrong on another host.

Keep host-specific facts **out** of shared `CLAUDE.md`. A half-true
instruction in a shared file is worse than no instruction, because every
other host inherits it.

### 6. Confirm the transcript path

```sh
ls ~/.claude/projects/*.jsonl 2>/dev/null | wc -l
```

`nightly-review.sh` reads this directory. Report the count. Zero means the
nightly review will find nothing to propose — expected on a fresh host.

Also scan it for credentials before scheduling anything. Transcripts are the
input to the review system, so a token sitting in one is a live path from a
leaked credential into a proposal file. Redact in place rather than deleting —
the history is the point.

### 7. Schedule the jobs

Check what the host actually has before assuming cron exists:

```sh
pgrep cron
```

Many containers have no init and no cron daemon. See
`references/scheduling.md` for the supercronic fallback and the login-shell
persistence problem.

Schedule `nightly-review.sh` at 03:00 and `fleet-sync.sh` at 03:30 — in that
order, so they do not race. Pin `CRON_TZ` if the host's timezone is unset.

**Schedule after the remote works.** `fleet-sync.sh` hard-fails without a
reachable `origin`, so scheduling first just fills the log with failures.

### 8. Push, do not merge

```sh
git fetch
git checkout -B "sync/$(date +%F)-$CLAUDE_HOST" origin/main
```

Commit, push that branch only, open a PR with `gh`. Never commit to main,
never `--no-verify`, never bypass push protection.

`gh` opens the PR as whoever it is authenticated as — verify with
`gh api user`, not `gh auth status`, which happily reports stale logins.

Then hand it to the operator to merge.

## Standing rules

**Never invent a host name or a credential.** If a placeholder like `<NAME>`
or `<TOKEN>` arrives literally, say so and stop. Do not guess.

**Never take a token through the chat or a command line.** Both end up in the
transcript that the nightly review reads. Have the operator save it out of
band:

```sh
umask 077; read -rs T && printf "%s" "$T" > ~/.newtoken && chmod 600 ~/.newtoken && echo saved
```

Then read it programmatically, verify, delete. Sweep afterward — test commands
have a habit of writing the old value back into the session file.

**Proceed vs ask.** Proceed on reasonable assumptions for reversible work
(local script edits, scratch clones, read-only queries) and flag them inline.
Stop and ask when the action is irreversible, outward-facing, or encodes
something expensive to reverse: naming things, credentials, pushing, deleting
someone else's work. Writing a claim into shared config belongs in the second
category even though nothing is deleted — the cost is propagation, not
deletion.

**Test in a throwaway clone.** Both scripts refuse a dirty tree and refuse to
touch main. Testing them in the real repo means violating one of those to
proceed. Build a fixture with its own bare remote instead.

**Distrust a passing test.** Every guard in this system that failed, failed by
passing vacuously — a credential the scanner did not recognize, a check
sitting after the early-exit it was meant to cover, a long-uptime service
assumed startable. When a check passes, ask what would have happened if it
had not.

**Report findings, not fixes, unless asked.** Onboarding surfaces real
problems. Record them; do not drift into remediation. The operator decides
what gets fixed.

## Reference files

- `references/host-naming.md` — why the name cannot come from `hostname`
- `references/testing-the-hook.md` — the vacuous-pass trap and the AKIA gap
- `references/scheduling.md` — no-cron hosts, supercronic, login persistence
- `references/troubleshooting.md` — symptoms seen on real hosts and their causes
