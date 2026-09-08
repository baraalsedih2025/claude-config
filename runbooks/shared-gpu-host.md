# shared-gpu-host

The physical host everything else in these runbooks runs on. Shared with other
teams.

**Status: DOCUMENTED 2026-09-08.** **[M]** machine-verified, **[C]** needs
confirmation, or `unknown — nobody knows`.

Per-host identifiers (fleet name, IP, container names, ports) are in
`../hosts/sgh-server.md`.

## What it is

**[M]** A single AWS instance with 4 × NVIDIA L4 GPUs, carrying **every** system
in these runbooks at once: the predict-core stack (inside a Docker-in-Docker
container), the RAG stack, the model servers, three team workspace containers,
Caddy, and standalone MySQL and Postgres.

**[M] It is shared.** Other people's work runs here. There is no separate
staging host. A reboot, a driver change, or a full disk affects teams who were
not consulted.

## ⚠️ Services bound to all interfaces

**[M] Observed 2026-09-08.** This host has a public IP (see
`../decisions/bge-m3-public-exposure.md`). These listeners are bound to
`0.0.0.0` or `*` rather than loopback:

| Port | Process | What it is |
|---|---|---|
| 80, 443 | `caddy` | the reverse proxy — deliberate, see `tls-dns.md` |
| 22 | `sshd` | host SSH |
| 2200 | `sshd` | second SSH listener — `unknown — nobody knows` why |
| **2222** | `docker-proxy` | **`ml-container` team workspace SSH** |
| **3306** | `docker-proxy` | **standalone MySQL** |
| **5111** | `docker-proxy` | **standalone Postgres** |
| **8030** | `docker-proxy` | container `heuristic_robinson` |
| **9991** | `docker-proxy` | **`ml-container` Jupyter** |
| 4009, 8040, 8110 | `python`/`python3` | `unknown — nobody knows` what these are |

**Recorded as observed, not remediated.** The other two team containers
(`ml-container-team2`, `v3-container`) bind `127.0.0.1` only — so the
`0.0.0.0` binding on `ml-container` is inconsistent with its siblings rather
than a house pattern.

**[M]** Stored memory notes that `ml-container` users have **empty passwords**.
Combined with `0.0.0.0:2222`, that is worth someone's attention.
`unknown — nobody knows` whether a security group or firewall restricts these
ports upstream of the host — nothing on the host does.

## Health check

```bash
nvidia-smi
df -h /
free -g
sudo docker ps --format '{{.Names}}\t{{.Status}}'
systemctl list-timers --all
sudo ss -tlnp | awk '$4 ~ /^(0\.0\.0\.0|\*):/'
```

**[M]** 21+ containers are normal. Multi-week and multi-month uptimes are the
norm here, not a sign of neglect.

## Environment quirks

**[M]** Each of these has cost time:

- **A `PreToolUse` Bash guard** blocks recursive deletes and other destructive
  patterns. It matches on the **command text**, so a script that merely
  *contains* `rm -rf` is refused too. Use per-file `rm -f`.
- **An auto-mode classifier** independently refuses some commands even when
  permissions allow them — `crontab` edits and some `docker exec` calls were
  blocked mid-task on 2026-09-08. Hand the command to a human rather than
  working around it.
- **Python is externally managed (PEP 668).** `pip install --user` fails; use a
  venv. `pre-commit` and `gitleaks` are not installed by default.
- **Two different `/workspace` trees** exist — one at the filesystem root, one
  under the home directory. They are not the same place, and the DinD container
  mounts the home one at the root path *inside itself*.
- **`find`**: pass ISO timestamps, never `yesterday`/`today` — GNU `find` reads
  `today` as *now*.
- **Nested Docker.** The predict-core stack runs inside the `ml-team`
  container. A path has one value on the host and another inside the DinD.

## Users

**[M]** Two users have shells on the host itself. Many more exist **inside** the
team containers, with their own home directories and processes.

**[M] Processes inside a team container belong to that container's user, not to
you.** Example, 2026-09-08: a `llama_cpp.server` with 36 days of uptime, 5.1 GB
RSS, CPU-only, running inside `ml-container` as the in-container user
`nabulsi`, serving that user's own model file. It looked like an orphan from the
host's process list. It is someone's work.

**Check the cgroup and the in-container user before touching any process you did
not start:**

```bash
cat /proc/<pid>/cgroup | grep -oE 'docker[-/][0-9a-f]{12,}'
sudo docker exec <container> getent passwd <uid>
```

## Symptom → diagnosis → fix

> ### ⚠️ MOSTLY UNMEASURED
>
> Host-level failures have not been catalogued. Nothing here is ranked, because
> nothing has been measured. Populate from real incidents only.

| Symptom | Observed cause | Check |
|---|---|---|
| A vLLM server will not start after a restart | its `--gpu-memory-utilization` fraction of the **whole card** must be free at startup, regardless of actual use. Another process had since taken GPU0. | `nvidia-smi`; see `llm-serving.md` |
| A long-uptime service cannot be restarted | its config was never re-applied, so it was never tested. Uptime was load-bearing. | try it deliberately, in a window |

**[M]** That second row generalises and is the most useful host-level lesson
found: **a service with months of uptime is not a service known to start.**

## Do NOT

- **[M] Do not run destructive commands without confirmation.** Shared host,
  other teams, and `backup-restore.md` cannot say whether anything is
  recoverable.
- **[M] Do not kill a process you did not start.** Check its container and its
  in-container user first.
- **[M] Do not change driver or CUDA versions** without an agreed window —
  every team's GPU work breaks at once. See `gpu-capacity.md`.
- **[M] Do not fill the disk.** `unknown — nobody knows` what the quota
  arrangement is, and the shared dataset tree has no known backup.
- **[M] Do not assume a port is internal.** This host has a public IP and
  several services bind all interfaces.
- **[M] Do not reboot casually.** Several services have never been proven to
  start from cold, and at least one was found unable to.

## Undocumented / unknown

- `unknown — nobody knows` — whether a firewall or security group restricts the
  `0.0.0.0` ports listed above.
- `unknown — nobody knows` — what listens on 2200, 4009, 8040 and 8110.
- `unknown — nobody knows` — disk quota, growth rate, or what to delete first
  when it fills.
- `unknown — nobody knows` — who else has `sudo` here.
- `unknown — nobody knows` — whether the instance or its volumes are
  snapshotted at the infrastructure layer.
- `unknown — nobody knows` — the reboot procedure, and which services need
  manual intervention afterwards. Given the above, assume several do.
- `unknown — nobody knows` — which team owns which container beyond the three
  named workspaces.

## Escalation

`unknown — nobody knows` — no hardware, platform or cloud-account owner is
recorded. See `../oncall.md`, where that row is unfilled.
