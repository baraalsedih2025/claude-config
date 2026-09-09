# Environment config and reload-on-change

Compose has no equivalent of Kustomize's `configMapGenerator`: `up -d` does
**not** notice that an `env_file`'s *contents* changed, only that the file list
did. So config lives in a watched directory and a watcher forces a recreate.

## Layout

```
deployments/config/<project>/<env>/
├── common.env      # shared, non-secret
├── <service>.env   # per-service, non-secret
└── secrets.env     # 0600 -- passwords, DSNs
```

It sits **outside the deploy directory** because the deploy's `rsync --delete`
destroys anything untracked inside it (`docker-compose.override.yml` was eaten
twice before this was moved out).

Reference them per service, later files winning:

```yaml
services:
  api:
    env_file:
      - path: ../config/<project>/<env>/common.env
        required: false
      - path: ../config/<project>/<env>/api.env
        required: false
      - path: ../config/<project>/<env>/secrets.env
        required: false
```

`required: false` keeps a plain repo checkout working - that directory exists
only on the deploy host.

## The watcher

A small `docker:cli` container running `inotifywait` on the directory:

- **Debounce ~3s.** Editors write in several steps (temp file, rename, chmod)
  and would otherwise fire three deploys per save.
- **Validate before touching anything:** `docker compose config -q`. A typo used
  to recreate every service and only then fail, leaving the stack down.
- **Restart only the services the changed file feeds.** Derive the mapping from
  `compose config --format json`, not from a hand-written table, so it cannot
  drift. Recreating all 19 containers because one LLM key rotated is how a
  running ingest job gets killed.
- **Do not `--force-recreate` by default.** Modern compose recreates a container
  whose `env_file` content changed on its own; forcing it recreates the
  unchanged ones too. Keep it only as a fallback.
- **Never let the watcher exit on a failed recreate**, or one bad edit silently
  stops all future reloads.
- It watches the *directory*, so creating or deleting any file there also fires.

## Five traps that make a config edit appear to work while changing nothing

1. **`environment:` beats `env_file:`.** A key in a service's `environment:`
   block shadows the same key from an env file. The symptom is brutal: the
   watcher fires, containers recreate, the log says "recreate ok", and the value
   inside the container is unchanged. Always verify with a sentinel value -
   `docker exec <c> printenv <KEY>` - never by watching containers restart.

2. **Ports cannot come from an env file.** Compose interpolates `${VAR}` only
   from the `.env` beside `docker-compose.yml`; `env_file` values reach the
   container but are invisible to `ports:`.

3. **A YAML anchor for `env_file` hides every path from a grep-based mapping.**
   With `x-config: &config` + `<<: *config`, no service block contains any
   `*.env` text, so a narrow-restart mapping matches nothing - or worse, matches
   the filename mentioned in a *comment* under an unrelated service and
   restarts only that one, logging success. Write `env_file` out per service,
   and keep `*.env` filenames out of service-block comments.

4. **`compose up -d <name>` starts a profile-gated service.** Profiles only gate
   the implicit all-services set, so naming one explicitly runs it. A bootstrap
   `loader` whose schema drops a restored table was launched this way by a
   password edit. Intersect the watcher's targets with
   `compose config --services`, which respects active profiles.

5. **"I edited the config and nothing restarted" is usually the wrong file.**
   A tag deploy ships the repo's committed *example* config into the deploy
   directory, where it sits next to `docker-compose.yml` looking exactly like
   live config while the real file is two levels up. Name committed examples
   `*.env.example` so nothing loads them - a comment saying "EXAMPLE" on line 1
   is not enough. Diagnose by mtime, not by reading logs:

   ```bash
   find <deployments-root> -name '<file>.env' -printf '%TH:%TM  %p\n' | sort -r
   ```

## Releases vs config changes

They are different operations and should behave differently:

| | command | scope |
|---|---|---|
| **Release** (tag deploy) | `build --pull` then `up -d --force-recreate --remove-orphans` | everything, unconditionally |
| **Config change** (watcher) | `config -q` then `up -d <affected services>` | only what the changed file feeds |

## Secrets

- `secrets.env` is `0600`, never committed, never `cat`ed into a transcript.
- **`docker compose config` dumps every resolved secret** - it expands
  `env_file` entries inline. Use `docker compose config -q` to validate, and
  `docker exec <c> printenv <KEY>` to read one value back.
- Never put an OIDC issuer or similar auth switch in a *shared* file if any
  service gates its `/health` on it - every health probe returns 401, containers
  go unhealthy, and dependent services never start.
