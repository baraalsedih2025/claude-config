# team-containers

Per-team workspace containers on the shared GPU host: isolated home
directories, own SSH and Jupyter ports, own users.

**Status: DOCUMENTED 2026-09-08.** **[M]** machine-verified, **[C]** needs
confirmation, or `unknown — nobody knows`.

Provisioning a new one is covered by the `provision-team-container` skill, which
is the authoritative procedure. This runbook covers the containers that already
exist and how they differ.

## What it does

**[M]** Each team gets a container from the same image, with its own workspace
directory, its own users, a capped RAM limit, and its own SSH and Jupyter ports.
They share the host's GPUs and kernel. If one stops, that team loses its
development environment; other teams are unaffected.

## The three that exist

**[M]** Verified 2026-09-08. All from image `jupyter-cuda-enabled:v4`.

| Container | SSH | Jupyter | Bind address | Uptime |
|---|---|---|---|---|
| `ml-container` | 2222 | 9991 | **`0.0.0.0` + `[::]`** | 2 months |
| `ml-container-team2` | **2224** | 9992 | `127.0.0.1` | 6 weeks |
| `v3-container` | 2225 | 9993 | `127.0.0.1` | 6 weeks |

### ⚠️ Two discrepancies, recorded not fixed

**[M] `ml-container` binds all interfaces; the other two bind loopback.**
On a host with a public IP, that means its SSH and Jupyter ports are exposed
where its siblings' are not. Stored memory also records that this container's
users have **empty passwords**. `unknown — nobody knows` whether anything
upstream of the host restricts those ports.

**[M] `ml-container-team2` is on port 2224, not 2223.** Stored notes say 2223.
The running container says 2224. `unknown — nobody knows` which was intended, or
whether something still tries 2223.

## Health check

```bash
sudo docker ps --format '{{.Names}}\t{{.Status}}\t{{.Ports}}' \
  | grep -E 'ml-container|v3-container'
sudo docker stats --no-stream ml-container ml-container-team2 v3-container
```

**[M]** Multi-week and multi-month uptimes are normal here.

**[M]** To see who is actually working inside one:

```bash
sudo docker exec <container> ps -eo user,etime,cmd --sort=-etime | head
```

## Known layout

**[M]** From stored notes and confirmed where checkable:

| | |
|---|---|
| `ml-container` | the main `/workspace` box; users have **empty passwords**; flat group permissions — **every user can write every other user's folder** |
| `ml-container-team2` | data-analysis box, 128 GiB RAM cap, users `nada`, `jararah` |
| `v3-container` | data-analysis box, 128 GiB cap, **no GPU**, passwordless SSH; users `majed`, `omar`; workspace `workspace-v3`, scripts `scripts-v3` |

**[M]** `ml-container` also hosts unrelated long-running work — e.g. a
`llama_cpp.server` owned by the in-container user `nabulsi`, 36 days uptime.
Containers are not idle sandboxes; treat anything running inside as someone's
live work.

## Symptom → diagnosis → fix

> ### ⚠️ UNMEASURED
>
> No provisioning or workspace failure has been catalogued. The rows below are
> the only observed ones. Do not backfill from guesses.

| Symptom | Observed cause | Check |
|---|---|---|
| A user cannot reach their container over SSH | port differs from what was documented — `team2` is on 2224, not the recorded 2223 | `docker ps` ports column, not the notes |
| A process inside a container looks orphaned | it belongs to an in-container user, not to the host operator | cgroup + `getent passwd <uid>` inside the container |

## Looks broken, isn't

- **[M]** Very long uptimes are normal.
- **[M]** `v3-container` having no GPU is deliberate, not a misconfiguration.
- **[M]** Processes inside these containers owned by unfamiliar usernames are
  normal — those are team members' own jobs.
- **[M]** All three sharing one image tag is normal; they are clones.

## Do NOT

- **[M] Do not kill or restart a container because it looks idle.** Someone's
  multi-week job may be inside it. Check first, and ask that user.
- **[M] Do not treat `ml-container`'s permissions as a template.** Flat group
  write access across all users is the current state of that one box, not a
  pattern to reproduce. The `provision-team-container` skill does per-user
  permissions with ACLs for deliberate cross-access.
- **[M] Do not reuse a port.** Each container needs its own SSH and Jupyter
  pair; 2222/9991, 2224/9992 and 2225/9993 are taken.
- **[M] Do not provision by hand.** Use the skill — it handles the RAM cap,
  ports, users, permissions and verification together, and was written to avoid
  touching the existing teams' containers.
- **[M] Do not assume a stored note is current.** The team2 port was wrong.
  Verify against `docker ps`.

## Undocumented / unknown

- `unknown — nobody knows` — whether anything upstream restricts
  `ml-container`'s `0.0.0.0` ports.
- `unknown — nobody knows` — whether the empty-password arrangement on
  `ml-container` is a deliberate accepted convenience or an oversight. It is
  not recorded as a decision.
- `unknown — nobody knows` — whether `2223` is referenced anywhere that would
  break, given `team2` is actually on 2224.
- `unknown — nobody knows` — whether any team workspace is backed up. See
  `backup-restore.md`; nothing was found.
- `unknown — nobody knows` — the root password store for these containers.
  `oncall.md` lists it as credential #12 with no named store.
- `unknown — nobody knows` — who to contact per team.

## Escalation

`unknown — nobody knows`. Per-team contacts are unrecorded — see `../oncall.md`.
