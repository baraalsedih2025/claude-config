# Host naming

## The rule

The operator chooses the name. It is never read off the machine, and never
falls back to `hostname`.

## Why

Everything a host can tell you about itself is regenerated when the host is
rebuilt:

| Host type | `hostname` returns | Problem |
|---|---|---|
| Docker container | `e5ae148be928` | New ID on every recreate |
| EC2 instance | `ip-172-31-40-218` | Derived from a private IP, dies with the instance |

The name is a durable identity, and it lands in three places:

- `hosts/<NAME>.md` — the file holding this box's facts
- `sync/<date>-<NAME>` — so a PR says which host proposed the change
- `CLAUDE_HOST` in `~/.claude-config.env` — suppresses the container warning

Rebuild a container with an ID-derived name and the old `hosts/` file is
orphaned while a new one appears under a new random name. The box loses its
memory even though it is the same box.

## Choosing

Anchor on role, then environment, then index — only as far as needed to
disambiguate:

| Signal | Example |
|---|---|
| Role | `build`, `web`, `db`, `ci` |
| Region or env | `prod-eu`, `staging-us` |
| Index, if genuinely several identical boxes | `-01`, `-02` |

Lowercase, hyphens, no dots (they read as domain separators in branch names),
no slashes.

`dev-local` is a fine and honest name for a single dev container. Do not
invent structure for one machine.

## No slashes

A `/` in the name breaks two things, and only one is obvious:

1. The proposal path becomes `proposals/<date>-a/b.md` while only
   `proposals/` exists, so the redirect fails and the run aborts. A
   `mkdir -p "$(dirname ...)"` fixes this.
2. The branch becomes `sync/<date>-a/b`, which git accepts as a **nested
   ref**. The `mkdir -p` does not fix this, and it will not surface until
   someone tries to reason about the refs.

Rename rather than patch around it.

## Renaming later

Cheap: update `~/.claude-config.env`, `git mv` the host file, fix the
`# Host:` heading, grep for stragglers. Two-line change.

Expensive once pushed: the old name is in commit history and branch names
forever. Do it before the first push.

The scripts re-source `~/.claude-config.env` on each run, so a rename needs
no scheduler restart.

## After a rename

Do not retrofit an existing PR's branch to the new name. A branch created
under the old identity should stay under it — merge it, then let the next run
branch off the updated main under the correct name. Retrofitting produces a
branch whose name never matched the commit that created it.
