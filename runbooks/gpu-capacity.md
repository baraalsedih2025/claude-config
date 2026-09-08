# gpu-capacity

> ## ⚠️ UNDOCUMENTED — NO PROCEDURE EXISTS
>
> Placeholder for a procedure that has never been written. It is here so the
> gap is **visible** rather than absent.
>
> **Status**: partially documented 2026-09-08 — the inventory and one measured
> failure mode are now recorded below. **The procedure is still missing**:
> allocation policy, headroom margins, arbitration and the OOM playbook remain
> `unknown — nobody knows`. Owner: `unknown — nobody knows`.

## Observed inventory [M, 2026-09-08]

Recorded so the gap is at least anchored to facts. **4 × NVIDIA L4, 23,034 MiB
each.**

| GPU | Used | What is on it |
|---|---|---|
| 0 | ~6.5 GB | bge-m3 embedder, RAG rest-api/reranker, unified RAG — **three processes** |
| 1 | 18,628 MiB | Qwen 3.5 9B FP8 — **81% of the card** |
| 2 | 0 MiB | **idle** |
| 3 | 0 MiB | **idle** |

**[M] The placement does not match the plan of record.** On 2026-08-27 the
stated intent was to serve the FP8 Qwen on GPUs 2 and 3. It is on GPU 1, and
2 and 3 are empty. The owner confirmed on 2026-09-08 that this is **drift —
nobody noticed**. Intended placement is GPU 2/3; moving it is pending a
maintenance window and is **not yet done**.

So the current state is: half the GPU capacity idle, while GPU 0 carries three
contending processes and GPU 1 sits at 81%.

**[M] The RAG containers' GPU assignment defaults to card 0** for both
embedding and rerank (`PARALLEL_EMBEDDING_GPU_DEVICE:-0`,
`PARALLEL_RERANK_GPU_DEVICE:-0` in the live compose file). That is why three
processes share GPU 0 while two cards are free. `unknown — nobody knows`
whether that default was chosen or inherited.

## The startup memory check — the one measured failure [M]

**Observed 2026-09-08.** vLLM requires its `--gpu-memory-utilization` fraction
of the **whole card** to be free *at startup*, regardless of how little it goes
on to use:

```
ValueError: Free memory on device cuda:0 (17.1/22.05 GiB) on startup is less
than desired GPU memory utilization (0.92, 20.28 GiB)
```

The embedder had been running 47 days and **could not have been restarted** on
that card — GPU 0 had filled up since it started. Its uptime was load-bearing,
and this was only discovered because the container was recreated for an
unrelated reason.

Two lessons, both generalising beyond this service:

- **A long-uptime service is not a proven-startable service.** If a config was
  never re-applied, it was never tested.
- **Actual usage tells you nothing about restartability.** The embedder used
  ~1.8 GB while demanding 20.3 GB be free.

`unknown — nobody knows` how many of the other GPU services would fail the same
check today. Nothing has tried them.

## Why this gap matters

**Correction to an earlier draft of this file:** it claimed OOM was "the second
most frequent failure (≈666 references)". That number was wrong — it counted
substring matches across all transcript text, including the assistant's own
repeated output. Filtered to the owner's own messages there is **one** mention
of an OOM condition. OOM frequency here is `unknown — nobody knows`.

What is true without any counting: model servers are pinned to specific GPUs,
models are quantised to fit, servers have been taken down on some cards to make
room for others, and capacity is arbitrated live from memory by one person.
None of that is written down.

There is no documented answer to any of:

- which GPU is allocated to what, and who decided
- how much headroom a card needs before a long request OOMs it
- who may take a model server down to free a card, and who they must tell
- what happens to another team's running job when they do

The consequence is that capacity is arbitrated live, from memory, by one person.
Someone covering will either refuse to act — leaving a service down — or free a
card and interrupt work they could not see.

## Risk if this is needed before it is written

| Scenario | Consequence today |
|---|---|
| Model OOMs under a long request | `?` No documented headroom margin, so no way to know if config or load is at fault |
| A card is needed for a new deployment | `?` No allocation map; someone guesses which server to stop |
| Two teams need the same GPU | `?` No arbitration rule and no written owner |
| A model server is stopped to free memory | `?` Unknown what depended on it, or who to notify |
| Driver or CUDA upgrade required | `?` Affects every team on the box; no maintenance-window process |

## Questions that must be answered

1. What is the current GPU inventory, and what is pinned to each card today?
2. What headroom does each served model actually need, including worst-case
   context length — not just idle footprint?
3. Which quantisations are in use and why (fp8 was chosen at least once); what
   was traded away?
4. Who may stop a model server to reclaim a card, and who must be told first?
5. Is there any scheduler or reservation mechanism, or is it convention only?
6. What is the OOM playbook: reduce context, lower batch size, requantise, or
   move cards? In what order?
7. How is utilisation observed — is anything recorded over time, or only
   `nvidia-smi` at the moment of asking?
8. Who owns driver and CUDA upgrades, and how is a window agreed with the other
   teams on the shared box?

## Do NOT

- Do not stop a model server to free GPU memory without knowing what reads from
  it. It may be serving the public-facing endpoint.
- Do not assume idle GPU memory is available headroom — a long request can claim
  it, which is how the OOMs happen.
- Do not change a driver or CUDA version on the shared host without an agreed
  window. Every team's work runs on the same cards.
- Do not resize or requantise a served model in place as a first response to
  OOM without recording what the previous configuration was.

## Escalation

`?` Unknown — shared GPU host owner is unfilled in `../oncall.md`.
