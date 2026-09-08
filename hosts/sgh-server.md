# Host: sgh-server

Machine-specific facts. These are properties of *this box*, not of the user —
they live here so `BaraAlSedih.md` stays a profile and remains safe to read on
any host in the fleet.

Not auto-linked. `install.sh` reports it as present; include or `@`-reference it
from the global `CLAUDE.md` only if you want it active here.

## Identity

| | |
|---|---|
| Fleet name (`CLAUDE_HOST`) | `sgh-server` — pinned in `~/.claude-config.env` |
| Machine hostname | `ip-172-31-40-218` (AWS-assigned; **not** the fleet name) |
| Config repo clone | `/workspace/Bara/claude-config` — **not** the `~/claude-config` default, so `REPO_DIR` must be passed explicitly to every script |

`CLAUDE_HOST` must stay pinned. Unpinned, the scripts fall back to `hostname`,
and sync branches then come out named `sync/<date>-ip-172-31-40-218`, which
nobody can trace back to a machine.

## Container topology

| | |
|---|---|
| Docker-in-Docker container | `ml-team` |
| Host → DinD mount | the home-directory workspace tree is mounted at the root-level `/workspace` inside the DinD |
| Team 1 (main box) | SSH `2222`, Jupyter `9991` |
| Team 2 | SSH `2223`, Jupyter `9992` |
| v3 (no GPU) | SSH `2225`, Jupyter `9993` |

The path divergence this creates is the single most expensive quirk here: a
directory has one path as the host sees it and a different one as the DinD sees
it. `rsync` runs on the host and takes the host path; `compose` runs inside the
DinD and takes the DinD path. Mixing them builds a tree in one place and
deploys nothing. See `BaraAlSedih.md` § Environment quirks.

## Deployed stack

| | |
|---|---|
| Tenant identifier | `moh` (single-tenant mode) |
| Deploy directory | under the home workspace tree, per project |
| Shared config directory | `deployments/config/<project>/<env>/` — `common.env` (committed, non-secret) and `secrets.env` (mode 0600) |
| Mount-path variables | live in the deploy directory's `.env`, **never** in `common.env` — compose interpolates `${...}` only from the project `.env` |

## Scheduling

| | |
|---|---|
| Scheduler | system `cron` (`/usr/sbin/cron -f -P`) — not supercronic |
| `fleet-sync.sh` | 03:30 daily, in the `ubuntu` user crontab |
| `nightly-review.sh` | **not currently scheduled on this host** |

The 03:30 slot exists to sit after a 03:00 `nightly-review` so the two never
race for the same working tree. That review is not yet installed here, so the
race is hypothetical for now — keep the gap when it is.

## Notes

- **2026-09-08** — `scripts/install.sh` first run on this host. It backed up the
  pre-existing `~/.claude/skills` (which held `provision-team-container`) into
  `~/.claude/backups/<UTC timestamp>/` before symlinking. Nothing was lost, but
  the skill was briefly inactive until it was copied into the repo's `skills/`.
- **2026-09-08** — `gitleaks` is installed to `~/.local/bin`, not by a package
  manager. It is a hard dependency of both `fleet-sync.sh` and
  `nightly-review.sh`; both fail closed without it.

## Resolved

- **2026-09-03** — the `bfs` claim in the shared `CLAUDE.md` `find` note was
  stale, not host-specific (`bfs` is not installed here; `find` resolves to
  `/usr/bin/find`), so it was deleted rather than moved here. The GNU
  `today`-parses-as-*now* caveat and the ISO-timestamp rule stay shared. See
  memory `find-is-bfs-date-filters`.
