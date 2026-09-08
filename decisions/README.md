# Decisions

One file per topic, named `<topic>.md`. The record of *why* — specifically the
choices that look wrong, arbitrary, or needlessly awkward until explained.

This exists because the expensive failure is not someone not knowing how a
system works. It is someone seeing a deliberate constraint, assuming it is an
oversight, and "fixing" it.

## Required sections

```markdown
# <topic>

- **Decided**: YYYY-MM-DD
- **Status**: current | superseded by <file> | under review

## What was decided
One or two sentences, stated plainly.

## Why
The reasoning, including the constraint that forced it. If it was a trade-off,
name what was given up.

## What this rules out
The tempting alternative, and what happens if someone does it anyway.

## How you would know it was wrong
The evidence that would justify revisiting. A decision with no falsifier is a
habit, not a decision.
```

## Rules

- **Write the one that already bit someone first.** If a choice has been
  questioned twice, it needs a file.
- **Record the incident, not just the principle.** "`environment:` overrides
  `env_file:`, which silently blanked the tenant DB credentials and failed three
  releases" is usable; "be careful with config precedence" is not.
- **Supersede, don't delete.** A reversed decision keeps its file, marked
  superseded, so the reasoning survives the reversal.
- No secrets, no IPs, no client or organisation names.
