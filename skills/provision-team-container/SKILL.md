---
name: provision-team-container
description: >-
  Provision an isolated Docker container workspace for a new team or set of users
  on a SHARED GPU host, by cloning an existing ML/CUDA container. Use when asked to
  "set up a workspace for another team", "give team X their own container", "copy our
  container with less RAM", or similar. Handles a capped RAM limit, a separate
  workspace folder, its own SSH/Jupyter ports, passwordless team users plus a
  password-protected root, per-user folder permissions (incl. cross-access via ACLs),
  and full verification — without touching the existing team's container.
---

# Provision an isolated team container on a shared GPU host

This skill reproduces a vetted procedure for standing up a second (third, …) team's
container next to an existing ML/CUDA container on the **same shared host**, keeping
the two fully isolated.

## Guiding principles

- **Shared box = be careful.** All inspection is read-only. Never restart, `commit`,
  or `rm` the *existing* team's container without explicit confirmation — `docker commit`
  briefly PAUSES a running container and can disrupt training.
- **Isolate everything**: separate container name, workspace mount, host ports, and
  scripts dir. Reuse only the *image*.
- **Confirm the security-relevant decisions** with the user before running (see below);
  don't silently pick.
- **Verify with real tests**, not just config inspection (actually write files as each
  user, actually query the GPU).

## Step 0 — Inspect the existing setup (read-only)

Identify the reference container and copy its shape:

```bash
docker ps                                   # find the reference container name
REF=<reference-container>                   # e.g. ml-container
docker inspect "$REF" --format '{{range .Mounts}}{{.Type}} {{.Source}} -> {{.Destination}}
{{end}}'
docker inspect "$REF" --format 'Mem: {{.HostConfig.Memory}} Runtime: {{.HostConfig.Runtime}}'
docker inspect "$REF" --format '{{json .NetworkSettings.Ports}}'
docker inspect "$REF" --format 'Cmd: {{json .Config.Cmd}}'   # the boot command to mirror
free -h; nproc                              # host capacity
cat <scripts-dir>/setup-ssh.sh              # how login is currently configured
```

Note especially the **login model**. A common pattern is empty-password SSH
(`PermitEmptyPasswords yes` + `passwd -d root`). Flag it: it means anyone reaching the
port logs in with no credential.

## Step 1 — Confirm decisions with the user (AskUserQuestion)

These genuinely change the steps — ask, don't assume:

1. **Image source** — *rebuild fresh from the base image* (no impact on the running
   container, no inherited runtime accounts; RECOMMENDED) vs *`docker commit` the live
   one* (captures runtime-installed libs, but pauses the source container and drags in
   its user accounts).
2. **Auth for the new users** — *SSH public keys* (secure; RECOMMENDED) vs *empty
   passwords* (matches a legacy setup but insecure).
3. **GPU access** — none (data-analysis workloads) vs shared `--gpus all`.
4. **Port bind scope** — `127.0.0.1` (localhost/tunnel only; RECOMMENDED, especially with
   passwordless login) vs `0.0.0.0` (network-reachable).
5. **RAM cap**, **new usernames**, and the **root password**.

## Step 2 — Host folders + scripts (isolated copies)

```bash
mkdir -p /home/ubuntu/workspace-<team>/<UserA> /home/ubuntu/workspace-<team>/<UserB>
cp -r /home/ubuntu/scripts /home/ubuntu/scripts-<team>
rm -f /home/ubuntu/scripts-<team>/*.log        # don't carry the source team's logs
```

Then install the two templates from this skill's `scripts/` dir, editing the
placeholders (`__ROOT_...__` handled via env, usernames, UIDs, workspace path):

- `scripts/setup-ssh.sh` — passwordless users, but **root requires a password**
  (does NOT run `passwd -d root`).
- `scripts/setup-users.sh` — creates the team users passwordless, **locks any inherited
  base-image accounts**, and sets per-folder ownership/permissions with an ACL for
  asymmetric cross-access. Idempotent, so it survives a container recreate.

`chmod +x` both.

## Step 3 — Check ports are free, then launch

```bash
ss -ltnp | grep -E ':<ssh-port>|:<jup-port>' && echo IN-USE || echo free

docker run -d --name <team>-container \
  --restart unless-stopped \
  --memory=<N>g --memory-swap=<N>g \
  --gpus all \                                   # omit if no GPU
  -p 127.0.0.1:<ssh-port>:22 -p 127.0.0.1:<jup-port>:8888 \
  -e ROOT_PASSWORD='<root-pw>' \
  -v /home/ubuntu/workspace-<team>:/workspace-<team> \
  -v /home/ubuntu/scripts-<team>:/scripts \
  <base-image> \
  /bin/bash -c "/scripts/setup-users.sh && /scripts/setup-ssh.sh && /scripts/start-jupyter.sh && service ssh start && tail -f /dev/null"
```

The boot script chain may run `apt-get install acl` on first boot — wait for
`setup-users.sh` to exit before verifying (poll `docker exec <c> pgrep -f setup-users.sh`).
Foreground `sleep` is blocked in the harness; poll in a `run_in_background` Bash loop.

## Step 4 — Verify (real checks, report the outputs)

```bash
docker inspect <c> --format '{{.HostConfig.Memory}}'          # == <N> GiB in bytes
docker exec <c> grep -iE '^(PermitRootLogin|PasswordAuthentication|PermitEmptyPasswords)' /etc/ssh/sshd_config
docker exec <c> bash -lc 'for u in root <userA> <userB>; do printf "%-10s " $u; passwd -S $u|awk "{print \$2}"; done'
#   expect: root=P (password), users=NP (empty) or key-only; inherited accounts=L (locked)
docker exec <c> bash -lc 'ls -la /workspace-<team>; getfacl -p /workspace-<team>/<UserB>'
# real write tests with runuser -u <user> -- bash -c 'touch .../.wtest && rm .../.wtest'
docker exec <c> nvidia-smi --query-gpu=index,name --format=csv,noheader     # if GPU
docker exec <c> bash -lc 'curl -s -o /dev/null -w "%{http_code}\n" http://localhost:8888/'  # Jupyter
```

## Changing a port later (SSH or Jupyter)

Docker port mappings are fixed at create time — you cannot re-map a running container.
To move a port you **recreate** the container with new `-p` flags. This is safe *because*
the boot scripts (`setup-users.sh` / `setup-ssh.sh`) are idempotent and re-provision
users/permissions on every boot, and all data lives on host mounts — so users,
permissions, and workspace files all survive.

1. Capture the live config first: `docker inspect <c>` for `HostConfig.PortBindings`,
   `.Config.Cmd`, mounts, `HostConfig.Memory`, `HostConfig.RestartPolicy`, and any
   **runtime** env vars (e.g. `ROOT_PASSWORD`). Image-baked env (CUDA vars) need not be
   re-specified.
2. Pick a free port away from common defaults (3306 MySQL, 5432 Postgres, 6379 Redis,
   27017 Mongo): `ss -ltnp | grep -E ':<newport>' && echo IN-USE || echo free`. Keep the
   team's existing convention (e.g. SSH 2222/2223/2224).
3. `docker stop <c> && docker rm <c>`, then re-run the exact Step 3 command with only the
   changed `-p` (container-internal port stays 22 / 8888).
4. Verify: port mapping (`docker ps`), `sshd`/Jupyter up, and a **real login test** on the
   new port. Then update the connect commands and the `project`-type memory.

## Permission model reference

- Workspace root: `root:root 755` → everyone reads/traverses the whole workspace.
- Each user's folder: `<user>:<user> 755` → owner read+write, others read-only.
- **Asymmetric cross-access** (e.g. a lead who edits everyone's folder): add an ACL
  instead of a shared group —
  `setfacl -R -m u:<lead>:rwx <folder>` plus `setfacl -R -d -m u:<lead>:rwx <folder>`
  (the `-d` default entry keeps files created later writable by the lead). Groups
  can't express "A into B's folder but not B into A's" cleanly; ACLs can.

## Wrap-up

- Write/update a `notes.md` report in the requesting user's workspace folder with:
  inspection findings, decisions, exact steps, permission table, isolation table
  (old vs new), risks, and an **APPLIED — results** section with the verification table.
- Give the user the connect commands (`ssh -p <port> <user>@127.0.0.1`, Jupyter tunnel).
- Save a `project`-type memory recording the new container's name, ports, workspace path,
  users, and RAM cap.

See `scripts/setup-ssh.sh` and `scripts/setup-users.sh` in this skill directory for the
ready-to-edit templates.
