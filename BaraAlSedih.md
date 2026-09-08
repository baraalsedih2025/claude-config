# Profile: Bara AlSedih

Context that holds across every host in the fleet. Loaded via `CLAUDE.md`.

**Status: DRAFT.** Items marked `?` are unconfirmed — they are questions, not
claims. Everything unmarked is evidenced from this repo, `CLAUDE.md`, or an
observed session, and is still worth correcting if it reads wrong.

Deliberately absent, by rule: secrets and tokens, internal hostnames and IPs,
ports, and client or organisation names. Where a fact needed one of those to be
meaningful, it is described generically instead.

Machine facts belong in `hosts/<CLAUDE_HOST>.md`, not here — a fleet name, an
IP, a container name, a port, a tenant identifier are properties of a box, not
of a person. This file is a profile and is read on every host, so keeping it
free of them is what makes it safe to sync fleet-wide. For this box, see
`hosts/sgh-server.md`.

## Role and background

- Owns a shared multi-tenant GPU/ML server and the team workspaces on it:
  provisioning isolated containers per team, per-user accounts, storage layout
  and cross-team access.
- Runs the release pipeline for an internal ML platform — tag-triggered deploys
  onto that box, and the debugging when a release does not land.
- Maintains fleet-wide Claude Code configuration as version-controlled infra
  (this repo), rather than per-machine dotfiles.
- `?` Job title, and years in the field.
- `?` Domain in your own words. From the work I have seen it reads as healthcare
  claims / payer analytics, but I would rather quote you than infer.
- `?` Team size, and whether you are the one on call for this box.

## Stack and tools

Observed in use:

| Layer | What |
|---|---|
| Languages | Python, Bash |
| Python | FastAPI + uvicorn, polars, SQLAlchemy, pymysql, pytest `?` |
| Data | Parquet trees, PostgreSQL, MySQL, RabbitMQ + Celery |
| ML | PyTorch, Ray, AutoGluon (profile-gated, not deployed on the shared box) |
| Containers | Docker, Compose, Docker-in-Docker, CUDA base images |
| Orchestration | systemd units and timers, cron, bash deploy scripts, rsync |
| Git / CI | GitHub, `gh`, pre-commit, gitleaks, tag-driven releases |
| Auth | OIDC / Keycloak |
| Claude Code | skills, hooks (`PreToolUse` guards), headless `claude -p`, memory |

**No Kubernetes.** Confirmed 2026-09-08. The deployment config comments describe
the layout as "mirroring the k8s-gitops `environment.properties` pattern" — that
is a *borrowed convention* (non-secret settings in version-controlled per-env
files, secrets in a 0600 file beside them), not a description of infrastructure
being operated. Nothing here runs on k8s; do not reach for `kubectl`, a
manifest, or a Helm chart, and do not read that comment as evidence of a
cluster. Orchestration is Docker Compose inside Docker-in-Docker, driven by
systemd timers and cron.

- `?` Anything else major missing — Terraform, dbt, Airflow, Spark, a cloud SDK,
  a JS/TS frontend?
- `?` Editor and shell, if you want me to match conventions.

## Working preferences

Confirmed:

- **Short by default.** Lead with the result, then only what I must act on. No
  restating the request, no re-summarising work already reported. See
  `CLAUDE.md` § Response length.
- **Tables over prose** for anything comparative or enumerable.
- **Report the finding, not the search for it.** A verified result is one line,
  not the commands that proved it.
- **Do not invent facts about me or my infrastructure** — verify, or ask.
- **Proceed vs ask.** Proceed on reasonable assumptions for reversible work and
  flag them inline. Stop and ask when the action is irreversible,
  outward-facing, or encodes a decision that would be expensive to reverse
  later.

  Reversible, so just do it: local script and config edits, a scratch clone, a
  read-only query, anything a later commit can undo.

  Ask first: a host or fleet name, a credential, pushing or opening a PR,
  deleting someone else's container, a claim written into shared config that
  future sessions will treat as fact. Naming things and writing things down are
  the expensive-to-reverse category, not just deletions.

Unconfirmed:

- `?` Code review: do you want correctness bugs only, or style and structure
  too? Inline patches, or a findings list you apply yourself?
- `?` What should I stop explaining to you? Candidates: Docker and Compose
  semantics, git mechanics, Python packaging, systemd, basic SQL. Name the ones
  that waste your time.
- `?` When I hit a blocker, do you want the one-line blocker, or blocker plus
  the diagnostic evidence behind it?
- `?` Commit and PR messages: terse subject lines, or the fuller
  rationale-in-the-body style already in this repo's history?

## Environment quirks

Confirmed, and each one has cost time already:

- **A `PreToolUse` Bash guard** blocks recursive deletes and other destructive
  patterns on this shared host. It matches on the *command text*, so writing a
  script that merely **contains** `rm -rf` is refused too. Use per-file `rm -f`.
- **Nested Docker.** Compose runs inside a DinD container, so a path as the DinD
  sees it differs from the host path for the same directory. Mixing them builds
  a tree in one place and deploys nothing.
- **Two different `/workspace` trees** exist — one at the filesystem root, one
  under the home directory. They are not the same place.
- **Compose config precedence:** `environment:` silently overrides `env_file:`,
  and `${...}` interpolates only from the project `.env`, never from an
  `env_file`. This has caused at least three separate incidents here.
- **Python is externally managed (PEP 668).** `pip install --user` fails; use a
  venv. `pre-commit` and `gitleaks` are not installed by default.
- **`find`**: pass ISO timestamps, never the words `yesterday`/`today` — GNU
  `find` reads `today` as *now*. See `CLAUDE.md`.
- **An auto-mode classifier** independently refuses some commands even when
  permissions allow them — `crontab` edits and some `docker exec` calls have
  been blocked mid-task. Hand the command over rather than working around it.
Host-specific specifics — container names, ports, paths, tenant identifiers —
are in `hosts/<CLAUDE_HOST>.md`; this list is only the generic shape of each
trap.

- `?` Other machines in the fleet, and anything specific that trips me up there.
- `?` Is the shared box's data tree backed up, or should I treat every write to
  it as unrecoverable?

## Current projects

**Pruning rule: delete any entry older than 90 days unless it is still active.**
This section rots faster than the rest of the file — a stale "current project"
is worse than no entry, because it is read as present tense. Every entry carries
an ISO date so the cut is mechanical; when in doubt whether something is still
running, ask rather than leaving it to age.

- **2026-09-08 — ML platform release pipeline.** Tag-triggered deploys had been
  failing silently for three releases: a service could not see its data
  directory because nothing mounted it, and the unhealthy service blocked two
  others behind it. Fixed and released; a second bug where Compose shadowed the
  tenant DB credentials with empty strings is fixed on the branch, not yet
  tagged.
- **2026-09-08 — This repo, `scripts/fleet-sync.sh`.** Nightly collection of
  per-host config drift into a PR. Live on a daily schedule. Open PR carries the
  script; a follow-up carries the transcript secret-scan for
  `nightly-review.sh` and the first shared skill.
- **2026-09-08 — Team container provisioning.** Several team workspaces on the
  shared box, each with its own storage, accounts and access rules.
- `?` What else is active that I have not seen, and what is the next thing you
  expect to hand me?
