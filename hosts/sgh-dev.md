# Host: sgh-dev

Per-host overrides for this machine. Not symlinked automatically — append or
`@`-include from the global CLAUDE.md only if you want it active here.

## Resolved

- **2026-09-03** — the `bfs` claim in the shared `CLAUDE.md` `find` note was stale, not host-specific (`bfs` is not installed here; `find` resolves to `/usr/bin/find`), so it was deleted rather than moved here; the GNU `today`-parses-as-*now* caveat and the ISO-timestamp rule stay shared. See memory `find-is-bfs-date-filters`.
