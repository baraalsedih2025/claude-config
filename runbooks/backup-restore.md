# backup-restore

> ## ⚠️ UNDOCUMENTED — NO PROCEDURE EXISTS
>
> This file is a placeholder for a procedure that has never been written or
> tested. It is here so the gap is **visible** rather than absent. Do not read
> the empty sections as "nothing to do" — read them as "nobody currently knows".
>
> **Status**: undocumented as of 2026-09-08. Owner: `?`

## 🔴 Item 1: `checkpoint-205` — unreproducible, single copy, back up today

**[M] Verified 2026-09-08. This is the highest-priority backup item on the
host, and it is not theoretical.**

The production reranker checkpoint used by the cortex retrieval service:

```
LLM-Optimizer-cortex/reranker/checkpoints/bge-reranker-v2-m3_prod/checkpoint-205
  2.2 GB — model.safetensors, model.safetensors.sha256, trainer_state.json
```

| Property | Finding |
|---|---|
| Copies on this host | **exactly one** (filesystem-wide search) |
| In git? | **no** — gitignored, and zero files tracked under `reranker/checkpoints` |
| Reproducible by retraining? | **NO** |

**Why not reproducible [M]:** the training code survives
(`reranker/train.py`, `run_prod_training.sh`, ~20 supporting scripts), but

1. **the training data is gone** — `run_prod_training.sh` consumes
   `reranker/data/train_${TAG}.jsonl`; the directory `reranker/data/` **does not
   exist** and there are **zero `.jsonl` files** anywhere under `reranker/`;
2. **no seed is set** — no `set_seed`, `manual_seed` or `random_state` anywhere
   in `train.py`, so re-mining the samples would produce a different training
   set and a different model;
3. `trainer_state.json` records metrics only (epoch 1.0, step 205, 42 log
   entries) — not the recipe, not the data manifest.

So if this directory is lost, the deployed reranker cannot be rebuilt — only
replaced by a different model with different behaviour. `rag-stack.md` pins it
as `CKPT_DIR`.

**Do this today, before anything else in this file:** copy those three files off
this host, verify the copy against `model.safetensors.sha256`, and record where
it went. That is a 2.2 GB copy — minutes of work against an unrecoverable loss.

**[C]** Is the *training data* recoverable from anywhere (another host, an
object store, a colleague)? If yes, reproducibility is restorable and this drops
in severity. If no, the checkpoint is a permanent one-of-one artifact and should
be treated as production data, not as a build output.

## Why this is the broader gap to close

The shared GPU host holds a read-only dataset tree that multiple teams' runs
depend on, plus per-team workspaces, plus the databases behind the deployed
stack. Across every transcript on this host there is **no evidence of a backup
ever being taken, verified, or restored** — no snapshot command, no restore
drill, no retention policy.

That means nobody can currently answer the only question that matters during an
incident: *if this tree is gone, do we get it back, and how much of it?*

Until that is answered, every destructive action on the shared host must be
treated as **permanently destructive**. That is the working assumption, and it
is why the `PreToolUse` guard blocks recursive deletes rather than warning about
them.

## Risk if this is needed before it is written

| Scenario | Consequence today |
|---|---|
| Dataset tree deleted or corrupted | `?` Possibly unrecoverable. Multiple teams' pipelines read it. |
| A team workspace lost | `?` Unknown whether anything outside that container holds a copy. |
| Deployed stack's database lost | `?` No documented dump schedule or restore path. |
| Host instance terminated | `?` Unknown whether any volume survives, or how long a rebuild takes. |
| Ransomware / accidental mass-chmod | `?` No known clean point to roll back to. |

An untested backup is not a backup. If one exists but has never been restored
from, this file should say that plainly rather than imply safety.

## Questions that must be answered

1. Does any backup of the shared dataset tree exist? Taken by whom, to where,
   how often?
2. Is it *verified* — has a restore ever been performed, even partially?
3. Retention: how far back can we go, and what is the recovery point objective?
4. Are the stack's databases dumped on a schedule, and where do the dumps land?
5. Do per-team workspaces have any copy, or is the container the only one?
6. Who is authorised to perform a restore, and does it need anyone upstream?
7. Is the underlying storage snapshotted at the infrastructure layer,
   independently of anything on the host?
8. If the answer to (1) is "no": is that a deliberate accepted risk, or an
   oversight? If deliberate, that belongs in `../decisions/`.

## Do NOT

- Do not assume the shared data tree is recoverable. Nothing on this host
  demonstrates that it is.
- Do not delete, move, or mass-`chmod` anything under the shared dataset tree
  to reclaim space or "tidy up". Other teams read it, and there is no known
  restore path.
- Do not test a restore procedure onto live paths. If one is written, it gets
  drilled onto a scratch location first.

## Escalation

`?` Unknown — see `../oncall.md`. This is precisely the kind of gap that
section exists to surface.
