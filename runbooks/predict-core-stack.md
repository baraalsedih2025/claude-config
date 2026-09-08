# predict-core-stack

The predict-core Compose stack — 21 services running inside the
Docker-in-Docker container on the shared host.

**Status: DOCUMENTED 2026-09-08.** **[M]** machine-verified, **[C]** needs
confirmation, or `unknown — nobody knows`.

Deployment is a separate system: see `predict-core-deploy.md`.

## What it does

**[M]** An ML/analytics platform: ingest pipelines, anomaly and claim-anomaly
detection, a feature-extraction and transform chain, a scheduler (API, worker,
cron), a jobs service, a profile service, an agent API, and Postgres plus
RabbitMQ behind them. **[C]** Which of these are business-critical versus
experimental — `unknown — nobody knows`.

## Where it runs

**[M]** All services run **inside** the `ml-team` Docker-in-Docker container,
not on the host.

| | |
|---|---|
| Compose project | `predict-core` |
| Compose file | `/workspace/deployments/predict-core/docker-compose.yml` *as the DinD sees it* |
| Same file on the host | `<home>/workspace/deployments/predict-core/docker-compose.yml` |
| Services | 21 (19 deployed + 2 profile-gated) |
| Profile-gated | `mlstudio-api`, `mlstudio-worker` — `profiles: ["mlstudio"]`, intentionally not deployed |
| Config dir | `deployments/config/predict-core/<DEPLOY_ENV>/` |
| Current env | `DEPLOY_ENV=ml-dev` |

**[M]** To run any compose command you must be inside the DinD and use the DinD
path:

```bash
sudo docker exec -w /workspace/deployments/predict-core ml-team \
  docker compose ps
```

## Configuration layers

**[M]** Three sources, and the precedence between them has caused three
separate incidents.

| Layer | File | Read by |
|---|---|---|
| Compose interpolation `${VAR}` | the deploy dir's `.env` **only** | Compose, at parse time |
| Non-secret app settings | `config/predict-core/<env>/common.env` | the container at runtime |
| Secrets | `config/predict-core/<env>/secrets.env`, mode 0600 | the container at runtime |
| Agent-only settings | `config/predict-core/<env>/agent.env` | the agent container only, loaded last |

**[M] The rule that keeps being violated:** `environment:` in the compose file
**wins over** `env_file:`. And `${...}` interpolates **only** from the deploy
directory's `.env` — never from an `env_file`. So a key listed under
`environment:` with a `${VAR:-}` default resolves to an empty string and
silently overrides whatever the config directory says.

**[M]** The compose file states this rule for `DATA_ROOT` and then broke it for
the tenant DB. See the symptom table.

**[M]** `common.env` and `secrets.env` live **outside** the deploy directory, so
they survive the deploy rsync. `.env` is inside it but excluded from rsync.
Everything else in the tree is overwritten on every release.

## Health check

```bash
sudo docker exec ml-team docker ps -a \
  --filter label=com.docker.compose.project=predict-core \
  --format '{{.Names}}\t{{.Status}}'
```

**[M]** Expect 19 running; most report `(healthy)`. `scheduler-cron`,
`scheduler-worker`, `worker` and `agent` have no healthcheck, so they show
`Up` without `(healthy)` — that is not a fault.

**[M]** A container that is compose-managed carries a
`com.docker.compose.config-hash` label. One that does **not** was created by
hand and will never be updated by a release:

```bash
sudo docker exec ml-team docker inspect <name> \
  --format '{{index .Config.Labels "com.docker.compose.config-hash"}}'
```

Empty output means the container is an impostor. That check is how two
squatting containers were found on 2026-09-08.

## Dependency chain

**[M]** Verified from the compose file. This is why one broken service takes
several others down:

```
agent  ->  engine  ->  analyzer, anomaly, transform, feature-extraction
                            \
                             ->  postgres, rabbitmq  (service_healthy)
```

**[M]** `engine` requires all four of `analyzer`, `anomaly`, `transform`,
`feature-extraction` to be **healthy**. `agent` requires `engine` healthy. So a
single unhealthy analyzer leaves `engine` and `agent` stuck in `created` — a
three-service outage from one root cause.

## Symptom → diagnosis → fix

**[M] Every row below was observed on 2026-09-07/08.**

| Symptom | Root cause observed | Check |
|---|---|---|
| `dependency failed to start: container predict-core-analyzer is unhealthy`, deploy exits 1 | `analyzer` raised `RuntimeError: Data directory not found: …/final_data` and exited at startup. `DATA_ROOT` in `common.env` named a path that **nothing mounted** into the container. A mount is the only thing that makes a path exist; an env file cannot. | `docker logs predict-core-analyzer` inside the DinD |
| Broke **v4, v5 and v6** — three consecutive releases, identical error | same as above, undetected for ~18 hours | the deploy journal grep in `predict-core-deploy.md` |
| `Conflict. The container name "/predict-core-transaction-pipeline" is already in use` | two hand-created containers held names the compose file claims (`agent`, `transaction-pipeline`). They carried a valid `com.docker.compose.service` label, so **`--remove-orphans` did not remove them** — orphan detection matches on the service label, and the label named a real service. | the `config-hash` check above |
| `transaction-pipeline` healthy but ingestion unavailable; `POST /transaction/v1/run` returns 400 | `TENANT_DB_HOST/_USER/_NAME/_PASSWORD` were listed under `environment:` with `${VAR:-}` defaults, resolving to **empty strings** that silently overrode `secrets.env`. `db_storage_from_env()` treats empty as missing. | `docker inspect` the container's env — the vars were *present but empty* |
| Data-pipelines tab shows "unavailable" while the service is healthy | the agent reads `TRANSACTION_API_BASE_URL`, which was **absent from `common.env`** while every other service had its URL. The agent returned "not configured". | `printenv` in the agent container |
| Deploy overwrote a fix that was working | the fix existed only in the deploy directory; `rsync --delete` restored the repo version | compare deploy dir against `git archive <tag>` |

**[M]** The pattern across four of those six: **the failure was in configuration
that looked correct on disk.** In three cases the file was right and something
else overrode or ignored it. Read the *container's* environment, not the file.

## Looks broken, isn't

- **[M]** `mlstudio-api` / `mlstudio-worker` absent — profile-gated on purpose.
  Naming them in `up -d` would start them and pull a multi-GB image.
- **[M]** `scheduler-cron`, `scheduler-worker`, `worker`, `agent` showing `Up`
  without `(healthy)` — they define no healthcheck.
- **[M]** `AUTH DISABLED … OIDC_ISSUER is not set` in service logs is the
  current expected state. **[C]** Confirm that is intended for this
  environment.
- **[M]** `postgres` in state `created` rather than `running` **is** a fault —
  it means a `compose up` aborted midway. Not a normal state.
- **[M]** A container named `<hex>_predict-core-<service>` is a Docker rename
  artifact from a failed recreate, not a real service.

## Do NOT

- **[M] Do not put a key in `environment:`** if a config file should own it. It
  will silently shadow the file and edits to the file will appear to do nothing.
  This has caused three incidents.
- **[M] Do not read a config file and assume that is what the service got.**
  Inspect the container's environment.
- **[M] Do not `--force-recreate` a single service** and expect it to be
  isolated. It force-recreates that service's dependencies too. Doing this on
  `agent` on 2026-09-08 cascaded into postgres and rabbitmq, hit a leftover
  renamed container, and left four services stopped. Use `--no-deps` if you mean
  one service.
- **[M] Do not delete a container that lacks a `config-hash`** without finding
  out who made it. Two such containers were someone's manual workaround for the
  failing deploys, not junk.
- **[M] Do not fix anything only in the deploy directory.** It is overwritten by
  the next release. The fix belongs in the repo, on the branch that gets tagged.
- **[M] Do not assume `--remove-orphans` cleans up hand-made containers.** It
  does not, if they carry a matching service label.

## Undocumented / unknown

- `unknown — nobody knows` — which of the 21 services are business-critical.
- `unknown — nobody knows` — whether anything monitors service health between
  deploys. Nothing was found, and a three-release outage went unnoticed.
- `unknown — nobody knows` — who created the two squatting containers on
  2026-09-07, and whether the state they held mattered.
- `unknown — nobody knows` — whether other services besides `analyzer` need the
  shared-data mount. They start without it; they may fail when a job touches
  that path.
- `unknown — nobody knows` — whether the tenant database has a read-only
  service account or the pipeline uses a privileged one.
- **[C]** Whether `OIDC_ISSUER` being unset is intended here.

## Escalation

`unknown — nobody knows`. See `../oncall.md`; the tenant database is
credential #4 with no recorded granter or backup holder.
