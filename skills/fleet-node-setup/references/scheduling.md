# Scheduling

## Check first, do not assume

```sh
pgrep cron
command -v crontab
```

Containers frequently have no init and no cron daemon. Observed on a real
node: no cron binary, `systemctl` present but systemd not running, PID 1 was
`tail -f /dev/null`, uid 1004, no sudo, `apt-get` unusable.

If cron exists, use it. Otherwise use the fallback below.

## Slots

| Time | Job |
|---|---|
| 03:00 | `nightly-review.sh` |
| 03:30 | `fleet-sync.sh` |

In that order, so they do not race. Both fast-forward main at start, and two
simultaneous checkouts of the same working tree is not a state worth
debugging.

Pin `CRON_TZ` if the host's timezone is unset, or "03:00" means UTC on one
host and local on another.

## Schedule only after the remote works

`fleet-sync.sh` hard-fails without a reachable `origin`. Scheduling before
auth is sorted just fills the log with nightly failures.

## No-cron fallback: supercronic

Works unprivileged, no daemon required:

- Binary to `~/.local/bin/supercronic`
- Crontab at `~/.claude-config.crontab`, mode 600
- Starter script, log and pidfile in `$HOME`
- Add new jobs to the **existing** crontab; do not start a second instance

Upstream publishes no release checksums. Record the sha256 you got rather
than claiming verification.

Orphaned processes may linger as zombies when PID 1 is `tail` and never
reaps. Harmless; scheduled runs are unaffected.

## The login-persistence problem

With no init, nothing starts the scheduler at boot. Login is the only hook.

```sh
# Keep the nightly Claude config review scheduled. This container has no init
# and no cron, so nothing starts the scheduler at boot; login is the only hook.
# The script is idempotent — a no-op once it is already running.
if [ -x "$HOME/.local/bin/claude-scheduler-up.sh" ]; then
  QUIET=1 "$HOME/.local/bin/claude-scheduler-up.sh" || true
fi
```

**Put it in both `~/.profile` and `~/.zshrc`.** zsh does not source
`~/.profile`, so `~/.profile` alone silently never fires for an interactive
zsh login. This is a real failure that surfaces only after the next restart.

Editing login files may be blocked by a classifier. Do not work around it —
print the snippet and let the operator paste it.

## Prove it fires

Do not trust the schedule. Add a throwaway every-minute job, watch it fire,
confirm the log says the job succeeded, then remove the test job.

Also test under a cron-equivalent environment (`env -i`, bare `PATH`): auth
read from the env file, tools found via the script's own `PATH` repair. A job
that works in an interactive shell and not under cron is the default outcome,
not the exception — nvm-installed binaries in particular are not on cron's
`PATH`.

## Add dated tasks to the schedule, not to a file

A task dated in `oncall.md` depends on someone reading `oncall.md` that day —
the assumption that breaks during a leave. If a check needs to happen on a
date, put it in the scheduled run so the output lands in a PR. Keep the date
as the decision point, not the trigger.
