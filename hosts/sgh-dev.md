# Host: sgh-dev

Per-host overrides for this machine. Not symlinked automatically — append or
`@`-include from the global CLAUDE.md only if you want it active here.

## Repo clones on this box

The live repo on this box is `/home/bara/claude-config` — symlinked into
`~/.claude/CLAUDE.md`, `~/.claude/skills`, `~/.claude/commands`. Edit there.

`/workspace/Bara/claude-config` is a **different** clone: sgh-server's tree,
reachable from here only via a shared mount. It is not this host's repo and
is not symlinked into anything on this box. Do not edit it from here — a
commit made there is attributed to this host but lands in sgh-server's
working tree, not this one's.

## Resolved

- **2026-09-03** — the `bfs` claim in the shared `CLAUDE.md` `find` note was stale, not host-specific (`bfs` is not installed here; `find` resolves to `/usr/bin/find`), so it was deleted rather than moved here; the GNU `today`-parses-as-*now* caveat and the ISO-timestamp rule stay shared. See memory `find-is-bfs-date-filters`.
