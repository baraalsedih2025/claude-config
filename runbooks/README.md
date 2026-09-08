# Runbooks

One file per system, named `<system>.md`. Written for a competent stranger
covering while the owner is unavailable — not for the person who built it.

---

## 🔴 KNOWN GAPS — read these four before anything else

Compiled 2026-09-08 from what the ten runbooks turned up. These are the gaps
that hurt most **during an absence**, put here so nobody has to read all ten
files to find them. Each is a real, verified absence of something — not a
suspicion.

### 1. Nothing alerts when a deploy fails

**[M]** The predict-core deploy worker failed **three consecutive releases**
(v4, v5, v6) with an identical error and nobody noticed for ~18 hours. It was
found only because someone asked why a tag had not deployed.

There is no alerting, no dashboard, and the only record is a local journal on
the host. A failed deploy also does **not** retry — and the tag is permanently
consumed, so the fix is always "cut the next version", never "re-push".

**During an absence:** check the journal deliberately, on a schedule. Nothing
will tell you.
→ `predict-core-deploy.md`

### 2. Nothing is known to be backed up, and one artifact is unrecoverable

**[M]** No backup of the shared dataset tree, the team workspaces, or the stack
databases was found to exist, be verified, or ever have been restored.

Worst case is concrete: the production reranker checkpoint (2.2 GB, single copy,
gitignored) is **unreproducible** — the training data is gone and no seed was
set, so it cannot be retrained to the same model. If that directory is lost, the
deployed reranker can only be replaced by something behaviourally different.

**During an absence:** treat every destructive action on this host as
permanent, because as far as anyone can demonstrate, it is.
→ `backup-restore.md`

### 3. The reboot path is unknown, and several services are not proven startable

**[M]** A model server with 47 days of uptime was found **unable to restart** on
its own card — its config had never been re-applied, so it had never been
tested. It was discovered by accident.

`unknown — nobody knows` how many other services are in the same state, or what
the correct order and manual steps are to bring this host back from cold.

**During an absence:** avoid a reboot if at all possible. If one is forced,
expect several services to need hand-holding and budget hours, not minutes.
→ `shared-gpu-host.md`, `gpu-capacity.md`, `llm-serving.md`

### 4. Escalation is empty, and nobody else can merge a fix

**[M]** Every escalation contact and upstream owner in `../oncall.md` is
unfilled — they are not discoverable from the machine and the owner will supply
them. Separately, the config repo lives on a **personal** GitHub account, so
during an absence nobody else can merge a PR, including any fix these runbooks
prompt.

That combination is the one that makes the rest of this documentation
advisory rather than actionable.

**During an absence:** you can read and diagnose; you may not be able to change
anything or find anyone upstream. Know that before you start.
→ `../oncall.md` (B1, and the `?` rows)

### Also worth knowing

- Symptom tables here are deliberately **thin and marked unmeasured**. An
  earlier draft ranked failure modes from inflated counts; those were wrong and
  were removed. A confident wrong runbook sends someone past the real cause.
- Two traps cost more time than any outage: the **live RAG stack runs from a
  git worktree, not the repo root** (`rag-stack.md`), and **`environment:`
  silently overrides `env_file:`** in Compose (`predict-core-stack.md`).
- The public endpoints are **internet-facing by decision**, not by accident —
  see `../decisions/bge-m3-public-exposure.md` before "fixing" that.

---

A runbook that only says what a system *is* has failed. The part that earns its
place is the part nobody can reconstruct from the code: which failure actually
recurs, what the non-obvious fix is, what looks broken but is fine, and what
must not be touched.

## Required sections

```markdown
# <system>

## What it does
One paragraph. What breaks for whom if it stops.

## Where it runs
Host (fleet name, never an IP), container, unit or timer, ports by role,
repo and branch, config and credential locations by NAME.

## Health check
The exact commands that prove it is working, with the expected output.
A green dashboard is not a health check.

## Symptom -> diagnosis -> fix
| Symptom | Likely cause | Check | Fix |
Most frequent first. Each row must be one someone has actually hit.

## Looks broken, isn't
Alarming-but-normal states: warnings at boot, a service idle by design, a
profile-gated container that is absent on purpose, a log line that always
appears. This section prevents the 2am "fix" that causes the outage.

## Do NOT
Actions that make things worse, are irreversible, or are someone else's to
take. Say why, briefly.

## Escalation
Who to contact when the above runs out. See `../oncall.md`.
```

## Rules

- **No secrets.** Name the credential *store* and who grants access, never a
  value. See `../oncall.md`.
- **No IPs or internal hostnames.** Use the fleet name; per-host specifics
  belong in `../hosts/<CLAUDE_HOST>.md`.
- **Date anything perishable**, so it can be pruned like the profile's projects
  section.
- **Write the fix you actually used**, including the ugly one. A runbook that
  documents the clean theory and omits the real workaround is worse than none.

## Undocumented gaps

A system with no procedure gets a stub marked `UNDOCUMENTED` rather than no
file at all. An absent file reads as "nothing here"; a stub reads as "nobody
knows, and here is what it costs us". Current stubs:

| Runbook | Gap | Clock on it? |
|---|---|---|
| `backup-restore.md` | No evidence any backup of the shared data tree exists, has been verified, or restored | No, but it is the one that bites first |
| `tls-dns.md` | **CLOSED 2026-09-08** — documented; certs, routing and access logs recorded | — |
| `gpu-capacity.md` | Inventory and one failure mode now recorded; **allocation policy, headroom and OOM playbook still missing** | No |

Close a stub by answering its questions and replacing the banner with the
standard sections. Do not delete a stub to tidy up — that hides the gap again.

