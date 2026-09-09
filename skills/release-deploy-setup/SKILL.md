---
name: release-deploy-setup
description: Set up release-triggered (git tag) deployment of a Docker Compose stack onto a server that CI cannot reach, using a poll-from-the-server systemd timer, a least-privilege deploy account, a gitops-style env-config directory with a reload watcher, and a Caddy basic-auth reverse proxy. Use when asked to deploy a project to a self-hosted/private box on release, wire up tag-triggered deploys, add a deploy user and sudoers rules for compose, or reproduce the predict-core / predict-engage deployment pattern on a new server.
---

# Release-triggered deployment onto an unreachable server

This is a working pattern, extracted from the predict-core and predict-engage
deployments on the shared ML dev server. Every warning here corresponds to a
failure that actually happened. Adapt names and paths; do not skip the traps.

## The shape of it

Push a tag -> a systemd timer on the server notices within a minute -> it
checks out the tag into a staging clone it owns -> rsyncs into the deploy
directory -> rebuilds and recreates the Compose stack. Environment config lives
*outside* the deploy directory and is reloaded by a separate watcher. A Caddy
reverse proxy with basic auth is the only thing exposed publicly.

```
GitHub <--(server polls, outbound HTTPS)-- systemd timer
                                              |
                        staging clone (deploy user's home)
                                              | rsync --delete
                                    deploy dir -> docker compose build/up
                                              |
    config dir (outside deploy dir) -> inotify watcher -> narrow recreate
                                              |
                              Caddy :PORT (basic auth) -- the only published port
```

## Step 0 - decide these before writing anything

| Question | Why it changes the work |
|---|---|
| Can CI reach the server? | If yes, use normal CI/CD and stop reading. Prove it - try an SSH connection from a hosted runner and check the server's auth log. |
| What credential is available? | Deploy keys and self-hosted runners need repo **Admin**. Fine-grained PATs may need org approval. A **classic PAT with `repo` scope** usually works with none. Design for the weakest one you can actually get. |
| Is there a nested Docker daemon (DinD)? | If the stack runs inside a DinD container, every compose command is `docker exec -w <path-as-DinD-sees-it> <dind> docker compose ...`, and there are two path views of the same files. See "Nested Docker" below. |
| Does the host have cron? | Many hardened boxes do not. systemd `.timer` is the portable choice. |
| Is a shared deployer already installed? | **Check first.** Look for an existing generic deploy script and a systemd template (`ls /usr/local/bin/*deploy*`, `systemctl list-timers '*deploy*'`). Writing a second poller that races the first for the same deploy directory is a real mistake that has been made here. |

## Step 1 - the deploy account

A dedicated system user per project, e.g. `<project>-deploy`:

```bash
useradd -r -m -d /home/<project>-deploy -s /bin/bash \
  -c "Deploy account for <project>" <project>-deploy
```

- **Do NOT put it in the `docker` group.** That is root-equivalent
  (`docker run -v /:/host` owns the box) and defeats the least-privilege setup.
  Grant the specific `docker` invocations through sudo instead.
- Credentials go in its own home, mode 600:
  ```bash
  su - <project>-deploy
  git config --global credential.helper "store --file=/home/<project>-deploy/.git-credentials"
  printf 'https://<user>:<token>@github.com\n' > ~/.git-credentials
  chmod 600 ~/.git-credentials
  ```
  `--global` and `--file` cannot both be given on the `git config` line itself -
  `--file` belongs *inside* the helper string.
- The staging clone lives in that home too, because the deploy directory is
  usually group-owned and not writable by this account.

## Step 2 - sudoers, exact-match

See `references/sudoers.template`. The rule must list the command lines
**character for character** as the script runs them.

- `visudo -c -f` validates *grammar only*. A rule with a typo'd flag parses
  fine and silently never matches - which in a non-interactive timer becomes a
  password prompt that hangs. Always verify with `sudo -l -U <user>` and diff
  the printed rule against the script's real command line.
- Adding a flag to the script (`--exclude=...`) without updating the rule breaks
  the deploy silently. They change together, always.
- Escaping: only `:` needs `\:` inside a value (`--chown=a\:b`); `=` stays literal.
- Install as `.new`, validate, then `mv` into place at `0440 root:root`.
- Prefer exact commands over wildcards. A wildcard `docker exec` into a DinD
  container is root on every stack on the box.

## Step 3 - the poll script

Copy `references/poll-script.sh` and adapt the header constants. The logic that
matters, and why:

- **Never select "the newest tag" by `--sort=-creatordate`.** Lightweight tags
  (what the GitHub web UI and plain `git tag <name>` create) carry no date of
  their own, so git falls back to the *commit's* date. A tag cut today on an
  older commit sorts as older than yesterday's annotated tag and is skipped
  forever. Keep a `.seen-tags` file and deploy the set difference
  (`comm -13 seen current`) - correct for both tag kinds.
- **Seed the seen-file on first run without deploying**, or every existing tag
  deploys at once and the last one wins.
- **Write the state file BEFORE the risky steps.** Recording only on success
  means a failing build retries every minute with the stack down. Recording the
  attempt first means a failure stops and waits for a human.
- **`flock` the whole run.** A build outlasts the timer interval and two
  concurrent rsyncs into the deploy directory interleave.
- **Validate the tag name against a strict regex.** Make it a *prefix* check
  with a permissive suffix - an over-narrow pattern (`ml-dev\.[0-9]+`) silently
  ignores `ml-dev.v1`, and an ignored tag is still marked seen, so the name is
  consumed and re-pushing it does nothing.
- **Branch allowlist.** Tags from *any* branch otherwise deploy to the same
  environment and the last one wins - this caused a real outage when a tag from
  a feature branch replaced a 23-service compose file with that branch's
  5-service one. Check `git branch -r --contains "$TAG"` after fetch, before any
  checkout. Two rules:
  - a genuine wrong-branch refusal is marked seen and exits 0, or the timer
    retries it every minute forever;
  - a *lookup error* (missing allowlist file, network blip) must **not** be
    marked seen, or a legitimate release is burned permanently.
  - Push the branch before the tag, or no remote branch contains it.
- **rsync flags, each load-bearing:**
  - `--exclude=.env` - gitignored, so the checkout has none, and `--delete`
    would destroy the one compose depends on.
  - `--exclude=.git` - a leftover clone in the deploy directory is frozen at
    whatever it last checked out. A later session diffed live files against a
    months-old `main` and reached a confident, entirely wrong diagnosis. Delete
    any `.git` already sitting there.
  - `--chown=<owner>:<group>` - plain `-a` preserves the deploy user's
    ownership and erodes the team's write access.
  - exclude any large host-only data directory that must not be shipped.
- **A release must force recreation.** `compose up -d` is a no-op for a service
  whose image and config are unchanged, so a tag deploy can leave containers
  from the previous tag running. Use:
  ```
  compose build --pull
  compose up -d --force-recreate --remove-orphans
  ```
- **Anything the compose file bind-mounts must be IN THE TAG**, or the first
  `rsync --delete` removes it and the container cannot start. Track a
  `.gitkeep` for gitignored mount directories.

## Step 4 - schedule it

`references/systemd-units.md` has the `.service` / `.timer` pair.
Two details: the service is `Type=oneshot` **without** `RemainAfterExit` (a
oneshot that stays active makes `OnUnitActiveSec` measure from the *start* of
the last run), and `OnUnitActiveSec=1min` measures from the end so a long build
does not queue runs behind itself.

Logs: `journalctl -u <unit> -f` (needs sudo unless you are in `adm` /
`systemd-journal`).

## Step 5 - environment config, outside the deploy directory

The deploy's `rsync --delete` destroys anything untracked in the deploy
directory - `docker-compose.override.yml` was eaten twice this way. So config
lives beside it, not in it:

```
deployments/config/<project>/<env>/
├── common.env    # shared, non-secret
├── <service>.env # per-service, non-secret
└── secrets.env   # 0600 - passwords, DSNs
```

Services reference these with `env_file:` and `required: false`, so a plain repo
checkout still works. Later files win. See `references/config-reload.md` for the
inotify watcher that reloads on change, and for the three traps that make a
config edit *appear* to work while changing nothing.

## Step 6 - the auth proxy

If the app has no authentication of its own, a Caddy reverse proxy with
`basic_auth` is the only gate - so do not publish the app's own port at all.
See `references/caddy-proxy.md`. The single most important rule:

> **Address the upstream by NAME, never by container IP.** Container IPs are
> reassigned on reboot, and the resulting 502 "connection refused" reads exactly
> like the app being down. The default `bridge` network has no DNS - join the
> proxy to a user-defined bridge the target is also on.

## Nested Docker (DinD), if applicable

- The stack's ports publish only on the DinD container's own interface, never
  the real host - hence proxying rather than publishing.
- **Two path views of the same files.** A host directory bind-mounted into the
  containers has one path on the host and another inside. rsync runs on the
  host and needs the host path; `docker exec <dind> docker compose` needs the
  in-container path. Mixing them builds a decoy directory tree and deploys
  nothing. Check every path against where its command actually executes.
- If the DinD mounts the workspace `:ro`, the stack can read but not write, and
  Docker cannot create a missing bind-mount source.
- Give the DinD container `restart: unless-stopped`, or a reboot takes every
  nested stack down with it.

## Verify - and how not to break the tree doing it

- **Never validate a guard by running the real destructive script.** A guard
  that correctly *allows* the happy path is indistinguishable from one that
  fails open, if what runs on success is `rsync --delete`. That exact test wiped
  a deployed tree. Test the validation logic in isolation, or with the
  destructive steps stubbed.
- Choose inputs that exercise the **refusal** branch (`bogus`, empty string) -
  a "test" tag that happens to match the regex proves nothing.
- Before any `--delete` / `reset --hard` / `rm -rf`, look at what is actually
  there.
- End-to-end: push a real tag on a throwaway branch with the allowlist set to
  that branch, and watch `journalctl -f`.

## Secrets hygiene

- Never `cat` a `.env` or run a broad `env | grep`. A pattern of `AUTH` once
  matched `CLAUDE_CODE_OAUTH_TOKEN` and printed a live token into a transcript.
  Print names (`env | sed -n 's/=.*//p'`) or lengths (`echo "len=${#VAR}"`).
- **`docker compose config` dumps every resolved secret** - it expands
  `env_file` inline. Validate with `docker compose config -q`; read one value
  back with `docker exec <c> printenv <KEY>`.
- Never commit a token. The PAT belongs only in the deploy user's
  `~/.git-credentials`, mode 600.
- If a secret is printed anyway, say so immediately and get it rotated.
