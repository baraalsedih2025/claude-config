# rag-stack

The retrieval stack: embeddings, hybrid retrieval, reranking, a REST API, an MCP
server and a pgvector database — plus the `cortex` local variant.

**Status: DRAFT from machine inspection, 2026-09-08.** Claims are tagged:

- **[M]** evidenced from the machine
- **[C]** needs the owner's confirmation

---

# 🛑 THIS STACK IS INTERNET-FACING — DELIBERATELY

**[M] Verified 2026-09-08. Do not infer this from a cert table — it is the
single most important fact about this stack.**

This is reachable from the public internet **by design**, not by accident. The
exposure is an **accepted risk**, recorded in
`../decisions/bge-m3-public-exposure.md` (and `rag-dev-key-gating.md`). `bge-m3.dev` staying directly
reachable is an explicit decision by the owner.

**Do not "fix" it.** Do not close the host, add an IP allowlist, or move it
behind a VPN without talking to the owner. If you think the exposure is wrong,
argue it against the revisit triggers in that decision file — do not treat it
as something nobody noticed.

```
rag.dev.iohealth.com      -> public DNS -> 51.112.42.49  (this host's public IP)
bge-m3.dev.iohealth.com   -> public DNS -> 51.112.42.49
Caddy                     -> network=host, listening on *:80 and *:443
```

Inbound reachability is **proven, not assumed**: Let's Encrypt issued and
renews these certificates, and ACME validation requires the internet to reach
port 80/443 on this host.

**The only control in front of the RAG services is an `X-API-Key` header
match in Caddy.** There is no IP allowlist, no mTLS, no VPN requirement, and no
OIDC on this path. Anyone on the internet with the right header value reaches
the service; without it they get a 401. `bge-m3.dev` has **no Caddy key check
at all** — its only gate is the vLLM server's own key.

### What follows from this, and did not follow from "internal-only"

- **A leaked key is an internet-wide exposure**, not a lateral-movement problem.
  Four RAG keys exist and **none has an identifiable caller** — see the API keys
  section below.
- **The keys are the perimeter.** Treat every one as a production credential:
  never in argv, never in a commit, never pasted into a ticket or chat.
- **Access logging is on** (added 2026-09-08), JSON to `/data/logs/access.log`
  in the `caddy` volume. It did not exist before, so there is **no history**
  before that date — assume nothing about who has been calling, or whether the
  endpoints were probed.
- **A "quick test" endpoint is a public endpoint here.** Anything bound into
  Caddy is exposed, immediately, to everyone.
- **What may be written in this repo is constrained by this.** No key values,
  no corpus contents, no enumeration of internal paths beyond what is already
  documented.

**What the embedder does not expose:** it is a **stateless model**. No corpus,
no documents, no database — it embeds submitted text and returns vectors. The
corpus, pgvector, reranker and cortex service are behind `rag.dev` with separate
key gates. A compromise of the embedder key yields **compute, not data** — which
is the basis on which the exposure was accepted.

Full TLS, DNS, routing and certificate detail: `tls-dns.md`.
The decision and its revisit triggers: `../decisions/bge-m3-public-exposure.md` (and `rag-dev-key-gating.md`).

---

# 🛑 READ THIS FIRST — THE LIVE STACK IS NOT THE REPO ROOT

**If you change one thing before touching this stack, make it this.** Editing
the repo root does **nothing**. The running containers come from a git worktree.

```
LIVE compose file:
  /home/ubuntu/LLM-Optimizer/.worktrees/rag-final-v2-integrated/docker-compose.parallel.yml

LIVE branch:          rag-final-v2-integrated  @ 4464f75
LIVE compose project: llm-optimizer-parallel

REPO ROOT is on:      gpu-config  @ a986320   <-- NOT RUNNING
REPO ROOT compose:    /home/ubuntu/LLM-Optimizer/docker-compose.yml   <-- NOT RUNNING
```

**How to tell in one command**, without trusting this file:

```bash
sudo docker inspect llm-optimizer-parallel-rag-rest-api-1 \
  --format '{{index .Config.Labels "com.docker.compose.project.config_files"}}'
```

That prints the only compose file that matters. Do that before every change.

**The tell-tale is the container names.** The repo-root compose sets
`container_name: rag-postgres`, `rag-embeddings`, `rag-rest-api`,
`rag-mcp-server`. What is actually running is
`llm-optimizer-parallel-rag-*-1`. Different names = different compose project =
your edit is not in the running system.

**This is the trap that costs the most time on this stack.** Someone edits the
root compose file, runs `docker compose up`, sees "up to date" or starts a
*second* parallel stack, and concludes the change had no effect — or worse,
concludes the system is broken.

---

## What it does

**[M]** Serves retrieval and reranking over a pgvector corpus, exposed three
ways: a REST API, an MCP tool endpoint, and a dashboard.

**[M] It is internet-facing, gated only by an `X-API-Key` header.** Verified
2026-09-08: the hostname resolves on public DNS to this host's public IP, Caddy
listens on `*:443`, and Let's Encrypt renewal proves inbound reachability. An
earlier assumption that this was internal-only was wrong. Full detail and the
consequences are in `tls-dns.md`.

## Worktrees

The live-vs-root warning is at the top of this file. What belongs here is the
full list, because choosing the wrong one deploys the wrong lineage.

**[M]** Six worktrees:

```
LLM-Optimizer                              [gpu-config]
LLM-Optimizer-cortex                       [cortex]
LLM-Optimizer-rerank-gap                   [reranker-prod-gap]
.worktrees/catalog-pull                    [catalog-pull-endpoints]
.worktrees/parallel-rag-main               [parallel-rag-main]
.worktrees/rag-final-v2-integrated         [rag-final-v2-integrated]  <- LIVE
```

**[M] Which are actually live, verified 2026-09-08** by cwd, argv and container
labels — three of the six, not one:

| Worktree | Branch | Last commit | Live? |
|---|---|---|---|
| `LLM-Optimizer` | `gpu-config` | 2026-08-16 | **LIVE** — 10 cwd refs, 10 containers |
| `.worktrees/rag-final-v2-integrated` | `rag-final-v2-integrated` | 2026-08-19 | **LIVE** — the 4 RAG containers |
| `LLM-Optimizer-cortex` | `cortex` | 2026-08-27 | **LIVE** — serves unified RAG on `:8320` |
| `LLM-Optimizer-rerank-gap` | `reranker-prod-gap` | 2026-08-16 | idle — **identical commit `a986320` to `gpu-config`**, no unique work |
| `.worktrees/parallel-rag-main` | `parallel-rag-main` | 2026-08-18 | idle |
| `.worktrees/catalog-pull` | `catalog-pull-endpoints` | **2026-09-06** | idle, but the newest commit of all six |

**[M] There is no `main` branch in this repo, and no `origin/HEAD`.** So "is
this branch merged?" cannot be answered — there is nothing to merge into. Any
tool or habit that assumes `main` exists here will mislead you.

**Dead-candidate assessment:** only `rerank-gap` is safely dead — it is a second
checkout of a commit that `gpu-config` already has. `catalog-pull` is idle but
carries the newest commit on the repo, which reads as work in progress, not
abandonment. `parallel-rag-main` predates the live `rag-final-v2-integrated` and
is probably superseded, but **unknown — nobody knows** for certain.

**Nothing has been deleted.** `LLM-Optimizer-cortex` being live is the reason
that matters: it looks like a stale side-checkout and it is serving traffic.

## Where it runs

**[M]** Shared GPU host; all published on loopback except where noted.

| Service | Container | Port | Uptime | Health |
|---|---|---|---|---|
| REST API | `llm-optimizer-parallel-rag-rest-api-1` | `:8081` → 8080 | 2 weeks | healthy |
| Embeddings | `…-rag-embeddings-1` | `:7998` → 7997 | 2 weeks | healthy |
| MCP server | `…-rag-mcp-server-1` | `:8091` → 8090 | 2 weeks | *no healthcheck* |
| pgvector | `…-rag-postgres-1` (`pgvector/pgvector:pg16`) | `:5434` → 5432 | 2 weeks | healthy |
| Dashboard | `rag-dashboard` | `:8092` → 8090 | 3 hours | — |
| Unified RAG | **host** process, `.venv-qwen`, `rag.unified_rag_service` | `127.0.0.1:8320` | 11 days | — |
| Reverse proxy | `caddy:2` | — | 11 days | **[C]** terminates TLS? |

**[M]** `caddy` is running. **[C]** If it fronts the public hostname it owns the
certificate, which makes `tls-dns.md` its runbook — confirm.

## Configuration, and how it actually reaches the containers

**[M] No `env_file:` directive exists in any compose file here.** Values arrive
by `${VAR}` interpolation at `compose up` time, from the shell environment and
the `.env` beside the compose file.

**[C] The consequence is the second big trap:** these containers have been up
two weeks. Their environment is frozen at whatever the shell held *then*. The
`.env` files on disk today may differ, and reading a file will not tell you what
a running container received. Inspect the container.

**[M]** Confirmed live in the containers: `PG_PASSWORD`, `RERANK_TOKENIZER_PATH`,
`EMBEDDING_TOKENIZER_PATH`. Compose requires `RAG_PG_PASSWORD` (`:?` — hard
fail if unset), plus model directories mounted read-only.

**[M] `.env` is the live file for the running containers.** Verified by hashing
the running container's `PG_PASSWORD` and comparing against each file on disk —
`.env` matches exactly. No guesswork.

**[M] The other two are not env files at all.** Each is a **single line**
holding one key:

| File | Contents | Mode |
|---|---|---|
| `.env` | the real config — `RAG_API_KEY`, `RAG_PG_PASSWORD`, `PG_PASSWORD`, AWS keys, LLM gateway keys | 600 |
| `.env.parallel` | `RAG_V2_API_KEY` only (1 line) | 600 |
| `.env.legacy-rag` | `RAG_LEGACY_API_KEY` only (1 line) | 600 |

They exist because `configure_dual_rag_route.sh` reads one key from each to
build the Caddy routing table. Do not expect them to configure a service.

**[M] Fixed 2026-09-08:** `.env.parallel` and `.env.legacy-rag` were **not
gitignored** — untracked but unignored, one `git add -A` from committing two
live API keys. `.gitignore` covered only `.env`. Now `.env*` with
`!.env.example`. Nothing had been committed.

## Local variant: cortex / `prerun_production.sh`

**[M]** `LLM-Optimizer-cortex/deploy/local-stack/prerun_production.sh`, 190
lines, branch `cortex`. Its own header states: *"The production server runs THIS
SCRIPT and nothing else on the retrieval side."*

**[M]** Four phases: (1) verify every input and print what is missing and where
to put it, (2) embed all lanes by starting the service once and letting startup
compute and persist every missing embedding, (3) wire `/retrieve`, `/mcp`,
`/recipe`, `/summarize`, (4) verify end to end — health, both retrieval
branches, MCP handshake and call, all three recipe selections.

**[M]** Idempotent: a healthy service on `$PORT` is left alone unless
`RESTART=1`.

**[M]** Key inputs and defaults:

| Var | Default | Note |
|---|---|---|
| `PORT` | `8320` | **production used `28320`** |
| `DATA_ROOT` | in-repo `data/production-assets/agnostic-synth`, else sibling checkout | corpora ship in-repo now |
| `T2_ROOT` | in-repo `…/track2-e2e`, else sibling | viz corpus |
| `MOH_DB` | `deploy/local-stack/moh-local-viewer/moh_local.db` | |
| `CKPT_DIR` | `reranker/checkpoints/bge-reranker-v2-m3_prod/checkpoint-205` | pinned checkpoint |
| `EMBED_URL` | `http://127.0.0.1:7997/v1/embeddings` | the bge-m3 embedder — **so this depends on `llm-serving.md`** |
| `GPU` | `0` | |
| `POLICY` | `two_lane` | `two_lane` \| `two_lane_ops` \| `full` |

**[M]** First run is slow because phase 2 computes every embedding; later
restarts are seconds because the cache persists under `CACHE_DIR`. **[C]** How
long is the cold run, and what should someone conclude if it appears to hang?

**[M] `checkpoint-205` exists in exactly one place on this host and is
gitignored** — 2.2 GB (`model.safetensors`, its `.sha256`, `trainer_state.json`)
at `LLM-Optimizer-cortex/reranker/checkpoints/bge-reranker-v2-m3_prod/checkpoint-205`.
Zero files are tracked under `reranker/checkpoints`, so it is **not in the repo
and not recoverable from git**. A filesystem-wide search found no second copy.

This is a **backup task, not a runbook entry** — see `backup-restore.md`. The
runbook cannot tell someone how to restore an artifact that has no second copy.

**[C]** Is it reproducible by retraining (is the training data and recipe still
available), or is this the only artifact? That determines whether it needs
backing up or merely documenting.

**[C]** When would a stranger need this path rather than the containers?

## API keys — four of them, and no known callers

**[M] Verified 2026-09-08.** Caddy validates every key by `X-API-Key` header
match. The applications themselves do not check these keys — Caddy is the gate.

| Key | Stored in | Routes to | Caller |
|---|---|---|---|
| `RAG_API_KEY` ("current") | `.env` | `127.0.0.1:8081` hybrid | **unknown — nobody knows** |
| `RAG_V2_API_KEY` | `.env.parallel` | `127.0.0.1:8081` — **same backend** | **unknown — nobody knows** |
| `RAG_LEGACY_API_KEY` | `.env.legacy-rag` | `127.0.0.1:8080` legacy service | **unknown — nobody knows** |
| cortex key (`/cortex/*`) | in the Caddyfile | `127.0.0.1:8320` unified RAG | **unknown — nobody knows** |
| anything else | — | `401 Unauthorized` | — |

**[M] There are four keys, not three.** The `/cortex/*` path has its own key,
easy to miss because it is a path prefix on the same hostname rather than a
separate host.

**[M] No caller for any key is identifiable.** A repo-wide search finds the key
*names* only in the scripts that write them; no client config, service or job on
this host presents them. Combined with **no access logging in Caddy** (see
`tls-dns.md`), there is no way to enumerate consumers — they are off-host and
unlogged.

**[M] `RAG_API_KEY` and `RAG_V2_API_KEY` route to the identical backend**
(`:8081`), so the v2 key is functionally redundant today. It presumably existed
to shift traffic between a v1 and v2 service during the parallel rollout, and
the split has since collapsed. **[C]** Confirm before retiring it — a caller you
cannot see may depend on it.

**[M] The legacy service is still running and serving traffic** — a container
on `:8080`, up 19 days, reachable with the legacy key. It is not dormant.

### Rotating any of these keys

**[M] You cannot currently tell who you will break.** This was demonstrated on
2026-09-08 when the `bge-m3` server key was rotated: the only 401s that appeared
were the operator's own probes from the Docker bridge, because nothing logs
external callers. Enable access logging *first* (see `tls-dns.md`), gather a
week of evidence, then rotate.

## Health check

**[M]** Shapes; **[C]** expected output needs confirming.

```bash
sudo docker ps --filter name=llm-optimizer-parallel --format '{{.Names}} {{.Status}}'
curl -s localhost:8081/health          # REST API
curl -s localhost:8320/health          # unified RAG (host process)
```

### Retrieval quality — the tooling exists, the automation does not

**[M] Verified 2026-09-08.** `LLM-Optimizer-cortex/eval/` holds **41 Python
scripts and 46 result JSON files**, with real IR metrics — `eval_retrieval.py`
reports `Prec@k`, `MRR` and `Hit@1` against an analytical random baseline.
Test sets include `rerank_cases500`, `rerank_mutual`, and several fusion
comparisons.

So the earlier worry that quality was unmeasured was wrong: it has been measured
substantially, by hand.

**[M] What is missing is automation.** Nothing runs any of these on a schedule,
nothing gates a deploy on them, and no result is compared against a stored
baseline. A silently degraded reranker would still pass every health check —
because the health checks only prove processes are listening.

**Highest-value cheap win on this stack:** pick one eval script and one test
set, run it on a schedule, and store the number. The tooling is already written.

**[C]** Which script and test set are the authoritative ones? There are 41, and
a stranger cannot tell which represents production.

## Symptom → diagnosis → fix

> ### ⚠️ UNMEASURED — no ranked failure modes yet
>
> **This section is deliberately close to empty, and that is the honest state.**
>
> An earlier draft carried a ranked table of failure modes with frequencies.
> Those numbers were wrong: they came from counting substring matches across all
> transcript text, which counted the assistant's own repeated output, not
> incidents. Filtered to the owner's own messages, the real evidence was **one**
> mention of an OOM condition and **one** of an auth failure — nowhere near
> enough to rank anything.
>
> A confident wrong runbook is worse than a thin one. Someone covering at 2am
> will follow a ranked table straight past the actual cause. So the invented
> rows are gone.

**Two entries are evidenced, from a change made on 2026-09-08:**

| Symptom | Cause | Check | Fix |
|---|---|---|---|
| Edited compose, nothing changed in the running system | You edited the repo root; the live stack is the worktree | the `config_files` label command above | Edit the worktree's `docker-compose.parallel.yml` |
| Config edit not applied after a container recreate | No `env_file:` anywhere — env is interpolated at `compose up` time, so a long-running container's env is frozen from the shell that started it | `docker inspect <c> --format '{{.Config.Env}}'` | Recreate the container from a shell with the right env loaded |

**Populate the rest only from real incidents.** When something is diagnosed
here, `scripts/nightly-review.sh` will draft the entry — that is what it is for.
Do not backfill this table from guesses.

Candidate areas that have *not* been observed failing, listed as places to look
rather than as known failure modes: TLS expiry on the public hostname (see
`tls-dns.md`), the three-way API key split, an empty pgvector corpus, and the
MCP container having no healthcheck so it never reports unhealthy.

## Looks broken, isn't

- **[M]** MCP server has **no healthcheck**, so `docker ps` never says
  "healthy" for it. Absence of healthy ≠ unhealthy.
- **[M]** Repo root sits on `gpu-config`, which is *not* what is running. That
  is normal here, not a mistake to correct.
- **[M]** Two-week container uptimes with a much newer dashboard (3 h) is normal.
- **[M]** Everything binds loopback — unreachable from outside is expected;
  external access is via the proxy.

## Do NOT

- **[M] Do not edit `LLM-Optimizer/docker-compose.yml` expecting the live stack
  to change.** It is a different compose project. Edit the worktree's
  `docker-compose.parallel.yml`.
- **[C] Do not `docker compose down` from the repo root.** With a different
  project name it will not stop the live stack — and if run with the right
  project name it stops the public-facing service. Be sure which you are doing.
- **[M] Do not read a `.env` file and assume that is the running config.**
  Inspect the container.
- **[C] Do not delete a worktree** to tidy up until you know which lineage is
  live. Five of six are not running; one of them is.
- **[C] Do not restart the unified RAG host process** without knowing whether
  the cache is warm — a cold start recomputes all embeddings.

## Escalation

`?` See `../oncall.md`. DNS/TLS and data-owner rows are unfilled.
