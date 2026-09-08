# predict-core-deploy

The tag-triggered deploy worker for predict-core. Polls GitHub for new tags and
deploys them onto the shared host.

**Status: DOCUMENTED 2026-09-08.** **[M]** machine-verified, **[C]** needs
confirmation, or `unknown — nobody knows`.

## What it does

**[M]** A systemd timer runs a bash script every minute. The script fetches
tags from the predict-core repo, compares them against a seen-list, and for any
new tag matching the release pattern it: archives the tag to a staging
checkout, rsyncs that into the deploy directory, then rebuilds and recreates the
whole Compose stack **inside** the Docker-in-Docker container.

If it stops, releases silently stop deploying. Nothing alerts.

## Where it runs

| | |
|---|---|
| Script | `/usr/local/bin/predict-core-deploy`, mode 0755, root:root |
| Service | `predict-core-deploy.service` — `Type=oneshot`, `User=predict-core-deploy` |
| Timer | `predict-core-deploy.timer` — `OnBootSec=2min`, `OnUnitActiveSec=1min` |
| Runs as | unprivileged user `predict-core-deploy`, `HOME=/home/predict-core-deploy` |
| Staging clone | `$HOME/predict-core-src` (bare clone + `checkout/` worktree) |
| Seen-list | `$HOME/.predict-core.seen-tags` |
| Branch allowlist | `/etc/predict-core-deploy/predict-core.branch` |
| Lock | `/var/lock/predict-core-deploy.lock` (`flock -n`) |
| Deploy dir (host) | `<home>/workspace/deployments/predict-core` |
| Deploy dir (as DinD sees it) | `/workspace/deployments/predict-core` |
| DinD container | `ml-team` |
| Deployed file owner | `1004:1000` — numeric on purpose; the host may not have those names |
| Log | `journalctl -u predict-core-deploy.service` |

**[M]** `RemainAfterExit` is deliberately **not** set. A oneshot that stays
"active" makes `OnUnitActiveSec` measure from the *start* of the last run, not
its end — which would queue runs behind a long build.

## Health check

```bash
systemctl status predict-core-deploy.timer
systemctl list-timers --all | grep predict-core
journalctl -u predict-core-deploy.service -n 50 --no-pager
```

**[M]** A healthy idle run exits 0 in ~2 s and logs nothing but start/finish.
Silence is normal — the script only logs when it finds a new tag.

**[M]** To see what it has decided historically:

```bash
journalctl -u predict-core-deploy.service --no-pager -o cat \
  | grep -E "deploying|deployed|refus|ignoring|seeded|lock"
```

That grep is the single most useful diagnostic on this system: it shows every
tag considered and what happened to it.

## The tag contract

**[M]** `TAG_RE='^ml-dev-sgh\.[A-Za-z0-9._-]+$'` — a prefix check with a
permissive suffix. The suffix is permissive on purpose: an over-narrow pattern
such as `ml-dev-sgh\.[0-9]+` would silently ignore `ml-dev-sgh.v1`, **and an
ignored tag is still marked seen**, so the name is consumed and re-pushing it
does nothing.

**[M]** Non-matching tags are logged and marked seen. Observed examples:
`ml-dev.18`, `ml-dev.v12`–`v15`, `predict-core.build.0.0.94`–`0.0.97`.

**[M] A seen tag is never revisited.** Re-pushing the same tag name has no
effect. **If a deploy fails, cut the next version — do not re-push.**

**[M] The state file is written BEFORE the risky steps**, deliberately.
Recording only on success would make a failing build retry every minute with
the stack down; recording the attempt first means a failure stops and waits for
a human.

**[M]** `mark_seen` appends one tag and re-sorts. It deliberately does *not*
dump the whole current tag list, because that would mark tags the loop has not
reached yet — with alphabetical sorting, a junk tag sorting ahead of a real one
would consume the real release before it was considered.

**[M]** Tags are selected by **set difference against the seen-list**, never by
`--sort=-creatordate`. A lightweight tag (what the GitHub web UI and a plain
`git tag` create) carries no date of its own, so git falls back to the commit
date: a tag cut today on an older commit would sort as older and be skipped
forever.

## Branch allowlist

**[M]** `/etc/predict-core-deploy/predict-core.branch` currently contains `*` —
**any branch may deploy**, by explicit decision.

**[M]** The comment in the script records why this is dangerous: it is the
setting that once let a tag cut from a feature branch replace a 23-service
compose file with that branch's 5-service one and take the stack down.

**[M]** A missing or empty allowlist file causes the script to **refuse and exit
1 without marking the tag seen**, so a legitimate release is not burned by a
lookup error. A genuine wrong-branch refusal *is* marked seen and exits 0, so
the timer does not retry it forever.

**[M]** A tag on no remote branch is refused and marked seen — push the branch
before the tag.

## Symptom → diagnosis → fix

**[M] All four rows below were observed on 2026-09-07/08.**

| Symptom | Cause | Check | What was observed |
|---|---|---|---|
| Tag pushed, nothing deployed, journal silent | tag does not match `TAG_RE` — and is now marked seen | the `ignoring` lines in the journal grep above | tag name is consumed; a new version must be cut |
| `dependency failed to start: container predict-core-analyzer is unhealthy` | a service in the dependency chain cannot start; everything behind it is blocked | `docker logs` for the named service inside `ml-team` | failed **three consecutive releases** (v4, v5, v6) with an identical error before anyone noticed |
| `Conflict. The container name "…" is already in use` | a hand-created container holds a name the compose file claims | compare `docker ps` names against `container_name:` in the compose file | `--remove-orphans` does **not** clear these if they carry a matching `com.docker.compose.service` label |
| Deploy "succeeded" but the code is old | the rsync source is the staging `checkout/`, not the repo you edited | compare the deploy dir against `git archive <tag>` | a local edit in the deploy directory is destroyed by the next rsync |

**[M] Confirmed failure history:** v1–v3 deployed cleanly (2026-09-06). v4
(09-07 12:21), v5 (09-07 13:47) and v6 (09-08 06:11) all logged `deploying` and
**never logged `deployed`**. v7 deployed successfully at 09-08 07:09. Tag v6
remains marked seen and will never redeploy.

## Looks broken, isn't

- **[M]** The timer firing every minute with no log output is normal. It only
  logs when there is a new tag.
- **[M]** `Active: inactive (dead)` on the *service* is normal — it is a
  `oneshot`. Check the **timer**, not the service, for liveness.
- **[M]** `another run holds the lock; skipping` is normal during a long build.
  `flock -n` drops overlapping runs by design; a build outlasts the 1-minute
  interval.
- **[M]** The mlstudio services being absent is deliberate — they are
  profile-gated (`profiles: ["mlstudio"]`) and `COMPOSE_PROFILES` is left unset.
- **[M]** `git` commands run against the staging clone as any other user fail
  with `detected dubious ownership`. Expected — the clone is owned by
  `predict-core-deploy`. Use `sudo -u predict-core-deploy git -C …`.

## Do NOT

- **[M] Do not re-push a failed tag.** It is marked seen; nothing will happen.
  Cut the next version.
- **[M] Do not edit files in the deploy directory** expecting them to persist.
  `rsync --delete` overwrites the tree on the next release. Only `.env` and
  `.git` are excluded.
- **[M] Do not change the rsync flags without changing the sudoers rule.** The
  script's own comment: *"THESE FLAGS MUST MATCH THE SUDOERS RULE CHARACTER FOR
  CHARACTER."*
- **[M] Do not remove `--exclude=.env`.** The checkout has no `.env` (it is
  gitignored), so `--delete` would destroy the one Compose depends on for
  `${DEPLOY_ENV}`, `${POSTGRES_PASSWORD}`, `${AGENT_PORT}` and
  `${INGEST_DATA_ROOT}`. An `env_file` cannot supply those — Compose
  interpolates only from `.env`.
- **[M] Do not validate a guard by running the real script.** The script's own
  warning: a guard that correctly *allows* is indistinguishable from one that
  fails open, when what runs on success is `rsync --delete`. That test wiped a
  deployed tree once. Use `DRY_RUN=1`.
- **[M] Do not mix host and DinD paths.** `rsync` runs on the host and takes the
  host path; `compose` runs inside `ml-team` and takes the DinD path. Mixing
  them builds a decoy tree and deploys nothing.
- **[M] Do not name services in `compose up`.** `up -d <name>` starts even a
  profile-gated service, and this stack has them — naming one would pull a
  multi-GB ML image that is intentionally not deployed here.

## Undocumented / unknown

- `unknown — nobody knows` — whether anything alerts when a deploy fails. Three
  consecutive failures went unnoticed for ~18 hours, which suggests nothing
  does.
- `unknown — nobody knows` — who besides the owner can read the journal or
  restart the timer.
- `unknown — nobody knows` — whether the `*` branch allowlist is still the
  intended setting, or a leftover from testing.
- **[C]** Whether the deploy user's SSH key has a second copy anywhere. None
  was found on this host.

## Escalation

`unknown — nobody knows`. See `../oncall.md`; the deploy pipeline's git
identity is credential #2 there, with no recorded backup holder.
