# On-call and escalation

Who to reach, what they own, and what to do when the owner is unavailable.

**Status: SKELETON.** Every `?` is unanswered and must be filled by a human —
none of it is inferable from a repo. Until then this file is not usable cover.

**No credential values here, ever.** Name the store and the person who grants
access. If a value appears in this file, it is an incident: rotate it, scrub the
file, and record the rotation.

## 🚫 BLOCKING — must be resolved before leave, not documented around

These four are **not coverage gaps to write a procedure for**. No runbook can
mitigate them, because the mitigation in each case is "ask the owner", and the
owner is the thing that is unavailable. They are prerequisites for the rest of
this file meaning anything.

| | Item | Hard deadline? |
|---|---|---|
| B1 | Config repo on a personal GitHub account | no, but blocks every other fix |
| B2 | Long-lived static AWS keys on disk | no |
| B3 | `sghprod` certificate expires and will not renew | **yes — 2026-09-30** |
| B4 | Internet-facing services with no access log | **RESOLVED 2026-09-08** — logging enabled |
| B5 | `bge-m3.dev` public exposure | **CLOSED 2026-09-08** — accepted risk, `decisions/bge-m3-public-exposure.md`, review 2026-12-07 |
| B6 | `rag.dev` posture undecided (data-bearing, proxy-key only) | no — first input 2026-09-15 |

### B1 — Config repo lives on a personal GitHub account

**Why it blocks:** the fleet config repo is owned by an individual account, not
an organisation. Nobody else can be granted push access without the owner, and
no org admin can recover it. Verified 2026-09-08: a second account tested at
`push: false`, and the owner's own token needed replacing twice to push at all.

This one is upstream of everything else here: with it unresolved, the team
cannot merge a sync PR, fix a runbook, or rotate a credential recorded in the
repo — during exactly the period this file exists to cover.

**Resolution, either is sufficient:**
- transfer the repo to an organisation with at least two admins, or
- add a collaborator with write access **and** confirm they can push and merge.

Adding a collaborator is the smaller change and can be done today; the transfer
is the durable fix.

**Done when:** a second named person has demonstrated a push and a merge to
`main` without the owner present. Not when access is granted — when it is
*exercised*.

### B2 — Long-lived static AWS keys on disk

**Why it blocks:** `AWS_ACCESS_KEY_ID` and `AWS_SECRET_ACCESS_KEY` are static,
long-lived, and sit in a mode-`600` `.env` file on one host with no vault, no
rotation record, and no second holder. If they leak there is no fast revoke path
that someone else can execute, and if the host is lost they are unrecoverable.

Unlike the rest of the credential gap, this has a standard remedy that needs no
new infrastructure, so there is no reason for it to wait on a vault decision.

**Resolution:** replace with an instance role or short-lived credentials. If
neither is possible on this host, then at minimum: rotate them, record the
rotation date, name a second holder, and document the revoke path here.

**Done when:** no static long-lived AWS key remains in any `.env` on the host,
or — fallback — the revoke path is written here and someone other than the owner
has confirmed they can execute it.

See `../decisions/credential-storage.md` for the full nine-credential picture
and the staged migration target. B2 is step 1 of that migration, pulled forward
because it is the highest severity and the least coupled.

### B3 — `sghprod.iohealth.com` certificate expires 2026-09-30 and will not renew

**Why it blocks:** it has 22 days left as of 2026-09-08 and **does not appear in
the Caddyfile**, so Caddy will not renew it — Caddy only manages certs for hosts
it serves. Its DNS still points at this host. The renewal window (30 days) has
already passed unactioned, which is the proof it is unmanaged.

This lands squarely in the leave period, and it fails in the way that wastes the
most time: the service looks healthy, the container is up, the logs are clean,
and every client refuses to connect.

**unknown — nobody knows** what that hostname serves, whether anything still
calls it, or whether it moved elsewhere.

**Two options, decide now:**

| Option | Do | Consequence |
|---|---|---|
| **Keep it** | add a `sghprod.iohealth.com` site block to the Caddyfile pointing at whatever it should serve | Caddy resumes managing and renewing it |
| **Drop it** | remove the DNS record and delete the orphaned cert directory | anything still calling it breaks *now*, while you are here to see it — which is strictly better than during the leave |

**Recommendation: drop it**, unless someone can name what it serves. An
unrouted cert for an unknown service is not worth carrying into a leave, and
failing now with the owner present beats failing on 09-30 with nobody who knows.
If it turns out to be needed, re-adding a route and re-issuing a cert takes
minutes.

**Done when:** either a route exists and `docker logs caddy` shows a successful
renewal, or the DNS record and cert directory are gone and nothing has broken
for a week.

### B4 — internet-facing services with no access log

**Why it blocks:** three hostnames are on public DNS, resolve to this host's
public IP, and Caddy listens on `*:443`. The RAG services behind them are gated
by nothing but an `X-API-Key` header match. **Caddy has zero `log` directives**,
so no request to any of them is recorded — no source IP, no user-agent, no
key-used.

The practical cost was demonstrated on 2026-09-08: a key rotation on the
embedder left **no way to determine which callers broke**. And none of the four
RAG API keys has an identifiable caller — they are off-host and unlogged.

This is a coverage blocker rather than only a security one: whoever covers
cannot answer "who is using this?", "did my change break someone?", or "is this
being probed?" for an internet-exposed service.

**Resolution — DONE 2026-09-08.** JSON access logging enabled on both routed
site blocks, writing to `/data/logs/access.log` inside the `caddy` container
(the persisted `caddy_data` volume), rolled at 50 MiB × 10. Records
`remote_ip`, `User-Agent`, `uri` and `status`. Verified with a probe.

Deliberately **not** stdout: the container's `json-file` driver has no rotation
configured, so stdout logging would grow unbounded.

`scripts/configure_dual_rag_route.sh` was also patched, in both live worktrees,
so that regenerating the `rag.dev` block preserves the log directive. Without
that, the next key rotation would have silently removed logging again.

**Still open:** the caller list. Let the log run, then replace the four
"unknown — nobody knows" rows in `runbooks/rag-stack.md` with real consumers,
**before** rotating any RAG key.

### B5 — internet-facing exposure — CLOSED, accepted risk

**Closed 2026-09-08.** This was raised as a blocker on the assumption that the
exposure was an oversight. It is not: the owner confirmed it is deliberate, and
`bge-m3.dev` staying directly reachable is an explicit choice.

**Recorded in `../decisions/bge-m3-public-exposure.md`** — what is exposed, why
it is acceptable, what it costs, and the six triggers that would reopen it
(including a fixed **2026-12-07** review date, so the acceptance cannot become
permanent by default).

**Scope is `bge-m3.dev` only.** `rag.dev` is a different posture — key-gated at
the proxy, and **data-bearing** rather than stateless. It is recorded as current
state in `../decisions/rag-dev-key-gating.md` and is **not** accepted. See B6.

**What remains, and it is not a blocker:**

- The `[C]` revisit triggers in that decision file are proposed, not confirmed.
  They are the owner's thresholds to set.
- The caller list for the four RAG keys is still `unknown — nobody knows`. That
  is now a task under B4's follow-up, not a decision: let the new access log
  run, then enumerate consumers **before** rotating any RAG key.

**Do not re-raise `bge-m3` as a security finding.** If a future review flags it,
the answer is that decision file — challenge it via the revisit triggers rather
than treating it as unnoticed. This does **not** apply to `rag.dev`, which
remains an open question.

### B6 — `rag.dev` posture undecided

Not a blocker for the leave, but it must not drift into being permanent by
default. `rag.dev` is internet-reachable, gated only by a shared static
`X-API-Key`, and unlike `bge-m3` it has the **retrieval corpus** behind it — so
a key compromise yields data, not just compute. The `bge-m3` acceptance rests on
statelessness and does not transfer.

**Task, dated 2026-09-15** (one week of access logs): enumerate the callers of
all four RAG keys from `/data/logs/access.log`, then replace the four
"unknown — nobody knows" rows in `../runbooks/rag-stack.md`. Only after that
should any RAG key be rotated. Agreed 2026-09-08.

A helper is in `../scripts/rag-callers.sh`.

## If you cannot reach the owner

1. `?` Preferred contact order and channel — how long to wait before escalating.
2. `?` Who is the designated backup, per system, and what can they already do
   without new access?
3. `?` Who can authorise an outage-stopping action that is normally gated (a
   restart of the shared box, taking a model server down, forcing a deploy)?
4. `?` Which decisions must simply wait for the owner, however inconvenient?

## Access held by the owner that nobody else has

The point of this section is to make single points of failure visible *before*
they matter. List the capability, the store, and the granter — never the secret.

Enumerated 2026-09-08 by inspecting the stores on the shared host — names and
locations only, never values. **Fourteen**, where four were expected: twelve
found in the first pass, plus the embedder server key and the cortex route key
found while investigating TLS.

| # | Capability | Where the credential lives | Who can grant it | Backup holder |
|---|---|---|---|---|
| 1 | GitHub push / PR, config repo | `~/.claude-config.env`, mode 600, per host | **nobody but the owner — personal account. See B1** | **none** |
| 2 | Deploy pipeline git identity | deploy user's SSH key on the shared host, mode 600 | `?` | `?` none found |
| 3 | Shared-host root / sudo | `?` | `?` | `?` |
| 4 | Tenant database (ingest source) | `secrets.env` in the deploy config dir, mode 0600 | `?` DBA / platform team | `?` |
| 5 | LLM gateway master key | `LLM-Optimizer/.env`, mode 600 | `?` | `?` |
| 6 | Model server auth key | `LLM-Optimizer/.env`, mode 600 | `?` | `?` |
| 7 | RAG endpoint API key | `LLM-Optimizer/.env`, mode 600 | `?` | `?` |
| 8 | RAG variant + legacy API keys | `.env.parallel`, `.env.legacy-rag`, mode 600 | `?` | `?` |
| 9 | AWS static access keys | `LLM-Optimizer/.env`, mode 600 | `?` | **none. See B2** |
| 10 | RAG / Postgres passwords | `LLM-Optimizer/.env`, mode 600 | `?` | `?` |
| 11 | LLM-Optimizer repo PAT | `?` location not yet found | `?` | `?` |
| 12 | Team container root passwords | supplied at provision time; no store named | `?` | `?` |
| 13 | bge-m3 embedder server key | `LLM-Optimizer/.env.kg-bge-m3`, mode 600 | owner only | **none** — rotated 2026-09-08 out of argv, where `ps` made it world-readable |
| 14 | cortex route key (`/cortex/*`) | **in the Caddyfile itself**, not an env file | owner only | **none** |

**Note on the removed `sghprod` certificate (2026-09-08):** its private key was
backed up to the operator's session scratchpad before deletion. That backup is
a credential at rest in a temporary directory — delete it once the decision is
final, or move it to the chosen secrets store.

Nine of the twelve (5–10) sit in `.env` files on one host with no secrets
manager — see `../decisions/credential-storage.md`, where that is recorded as a
known gap with a staged migration target rather than left to be discovered.

`?` For every row still marked `?`: if the honest answer is "only me", write
that. An explicit "only me" is the finding this table exists to produce; a `?`
just looks like unfinished paperwork.

## Upstream owners

Who to go to when the problem is not ours to fix.

| Area | Owner | Contact via | Notes |
|---|---|---|---|
| Shared GPU host / hardware | `?` | `?` | |
| Networking, DNS, TLS certificates | `?` | `?` | |
| Tenant database | `?` | `?` | read-only access for ingest |
| Identity provider (OIDC) | `?` | `?` | |
| Application code owners | `?` | `?` | who merges a release fix |
| Data / dataset owners | `?` | `?` | the shared read-only tree |

## Standing constraints

Things true regardless of who is covering.

- **The GPU host is shared.** Other teams' work runs on it. A restart, a driver
  change, or filling the disk affects people who were not consulted. A
  `PreToolUse` guard blocks destructive commands, but it is a backstop, not the
  policy.
- **`main` is never committed to directly** in the config repo. All changes go
  via a proposal or sync branch and are merged by a human.
- **Deploys are tag-triggered and record the attempt before the risky steps.**
  A failed deploy does *not* retry itself; it waits for a person. Re-pushing the
  same tag name does nothing — cut the next tag.
- `?` Change-freeze windows, or times when a deploy must not happen.
- `?` Who must be told when a release goes out.

## Incident log

Append; do not rewrite. Dated, one line each, newest last.

- `?` (none recorded yet)
