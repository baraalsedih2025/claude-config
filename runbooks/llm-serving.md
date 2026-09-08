# llm-serving

Self-hosted model serving: the Qwen chat model, the bge-m3 embedder, and the
LiteLLM gateway in front of them.

**Status: DRAFT from machine inspection, 2026-09-08.** Every claim is tagged:

- **[M]** evidenced from the machine — read directly off the running host
- **[C]** needs the owner's confirmation — inferred, or a *why* the host cannot answer

## What it does

**[M]** Serves an OpenAI-compatible chat endpoint (Qwen 3.5 9B, FP8) and a
text-embedding endpoint (BAAI/bge-m3), fronted by a LiteLLM gateway that gives
callers one base URL and one key format. **[C]** The RAG stack is the primary
consumer; if this stops, retrieval and the public-facing RAG endpoint lose their
model backend.

## Where it runs

**[M]** All on the shared GPU host. Fleet name in `../hosts/sgh-server.md`.

| Component | How it runs | Listens | Uptime seen |
|---|---|---|---|
| Qwen 3.5 9B FP8 | container `qwen35`, `vllm/vllm-openai:latest` | container `:8000` → host `:8200` | 43 h |
| bge-m3 embedder | container `kg-bge-m3`, **plain `docker run`, not compose** | `127.0.0.1:8000`, **public via `bge-m3.dev…`** | rebuilt 2026-09-08 |
| LiteLLM gateway | **host** process in `LLM-Optimizer/.venv`, config `deploy/qwen-litellm/litellm_config.yaml` | `127.0.0.1:8200` | 15 days |
| ONNX embedding server | container | `:7997` (also `:7998`) | 19 days |

**[M]** Qwen serve flags, verbatim:

```
--model /models/Qwen3.5-9B-FP8 --served-model-name qwen3.5-9b
--max-model-len 32768 --gpu-memory-utilization 0.88 --max-num-seqs 128
--enable-auto-tool-choice --tool-call-parser …
```

**[C]** Note the gateway (host, `127.0.0.1:8200`) and the `qwen35` container's
published port (`:8200` on a bridge address) are the **same port number on
different interfaces**. That is confusing at 2am and worth confirming it is
deliberate rather than a collision waiting to happen.

## ⚠️ The embedder is internet-facing

**[M] Verified 2026-09-08.** Caddy proxies a public hostname
(`bge-m3.dev.iohealth.com`, public DNS → this host's public IP) straight to
`127.0.0.1:8000`, and **Caddy applies no key check on that route**. The only
authentication is the vLLM server's own `VLLM_API_KEY`.

That makes this container's key the sole thing between the internet and the
embedding endpoint. It is also why the key must never be in argv (see Do NOT).

**[M]** Its key was rotated on 2026-09-08. **[M] Nobody could tell who broke**:
the only 401s logged were the operator's own probes from the Docker bridge
(`172.17.0.1`), because Caddy has **no access logging**. See `tls-dns.md`.

**unknown — nobody knows** which external callers use this endpoint.

## GPU inventory and pinning

**[M]** 4 × NVIDIA L4, 23,034 MiB each:

| GPU | Used | What is on it |
|---|---|---|
| 0 | 6,665 MiB | bge-m3 embedder (1,790), RAG rest-api/reranker (3,416), unified RAG (1,440) |
| 1 | 18,628 MiB | Qwen 3.5 9B FP8 (18,620) — **81% of the card** |
| 2 | 0 MiB | **idle** |
| 3 | 0 MiB | **idle** |

**[C] This contradicts the plan of record.** On 2026-08-27 the instruction was
to quantise to FP8 and "deploy on GPU 2,3 alone". Today Qwen is on GPU **1**,
and 2 and 3 are empty. Either the plan changed, or something moved and nobody
noticed. **This is the single most important thing for you to confirm** — half
the GPU capacity is currently unused while GPU1 sits at 81%.

**[M]** `--gpu-memory-utilization 0.88` on a 23 GB card reserves ~20 GB, and
18.6 GB is resident. **[C]** So headroom on GPU1 is thin by *design*, not by
accident — vLLM pre-allocates its KV cache. This matters for the OOM question
below: idle-looking free memory on GPU1 is not available.

**[M]** GPU assignment for the RAG containers is variable-driven, defaulting to
GPU 0 for both embedding and rerank in the live compose file
(`PARALLEL_EMBEDDING_GPU_DEVICE:-0`, `PARALLEL_RERANK_GPU_DEVICE:-0`). **[C]**
That is why three processes share GPU0 — confirm it is intended, since GPU2/3
are free.

**[M]** A `llama_cpp.server` has been running **36 days**, 5.1 GB RSS, CPU-only
(no GPU allocation, no listening port). It is **not part of this stack and not
ours to stop**: it runs *inside* the `ml-container` team workspace as the
in-container user `nabulsi` (UID 1008), serving that user's own
`qwen2.5-7b-instruct` GGUF. Its parent is the container's `tail -f /dev/null`
keepalive.

**Do not kill it.** It consumes no GPU. Ask that user before touching it — on a
shared box another person's 36-day process is presumed intentional.

## Health check

**[M]** These are the shapes; **[C]** exact expected output needs your
confirmation.

```bash
nvidia-smi --query-gpu=index,memory.used,utilization.gpu --format=csv
sudo docker ps --filter name=qwen35 --format '{{.Names}} {{.Status}}'
curl -s http://127.0.0.1:8200/v1/models        # gateway: lists qwen3.5-9b
```

**[C]** What is the authoritative check that the *gateway* is healthy rather
than just listening — does it need a key even for `/v1/models`?

## Symptom → diagnosis → fix

> ### ⚠️ MOSTLY UNMEASURED
>
> An earlier draft ranked failure modes by frequency. Those counts were wrong —
> they counted substring matches across all transcript text, including the
> assistant's own repeated output, not incidents. Filtered to the owner's own
> messages there was **one** OOM mention and **one** auth mention. Nothing can
> be ranked from that, so the invented rows are gone.
>
> A confident wrong runbook sends someone past the real cause at 2am. The one
> row below is evidenced because it was hit and fixed on 2026-09-08.

**Evidenced — the startup memory check, hit 2026-09-08:**

| Symptom | Cause | Check | Fix |
|---|---|---|---|
| vLLM exits at startup: `Engine core initialization failed`, and above it `ValueError: Free memory on device cuda:0 (17.1/22.05 GiB) on startup is less than desired GPU memory utilization (0.92, 20.28 GiB)` | vLLM demands its `--gpu-memory-utilization` **fraction of the whole card** be free *at startup*, regardless of how little it goes on to use. Other processes had since occupied GPU0. | `nvidia-smi --query-gpu=index,memory.used,memory.total --format=csv` | Pass an explicit `--gpu-memory-utilization` that fits current free memory, or start it on an empty card |

**Why this one matters more than it looks.** The embedder had 47 days of uptime
and *could not have been restarted* on that card — the container as configured
would have failed this check on any restart, reboot, or host maintenance. Its
uptime was load-bearing. It was only discovered because the container was
recreated for a credential rotation.

**Two general lessons, both [M]:**

- **A long-uptime service is not a proven-startable service.** If a config was
  never re-applied, it was never tested. Check the others for the same latent
  failure before a reboot forces the issue.
- **The `--gpu-memory-utilization` check is about the card, not the model.**
  bge-m3 actually used ~1.8 GB while demanding 20.3 GB be free. Reading actual
  usage in `nvidia-smi` tells you nothing about whether it can restart.

**Not observed, listed as places to look** rather than known failure modes: OOM
on long requests against GPU1, FP8 weights failing to load, gateway-vs-model key
confusion, and the gateway being reachable while the model behind it is not.

## Looks broken, isn't

- **[M] GPU2 and GPU3 at 0 MiB.** Idle, not faulty — but see the contradiction
  above; this may be a real misconfiguration rather than a normal state.
- **[M] GPU1 at 81% with 0% utilisation.** Normal for vLLM: memory is
  pre-allocated at startup, compute is idle between requests. Do **not** read
  high memory + zero utilisation as a stuck process.
- **[M] Multi-week uptimes** (47 days on the embedder) are the norm here, not a
  sign of something forgotten. **[C]** Confirm.

## Do NOT

- **[M/C] Do not stop the bge-m3 embedder or the gateway to free GPU memory.**
  The RAG stack's ingest path defaults to it (`EMBEDDING_BASE_URL` ->
  `localhost:8000`). GPU2/3 are free — use those instead.
- **[M] `kg-bge-m3` is NOT compose-managed.** It is a plain `docker run` with
  `--restart unless-stopped`. There is no compose file to recreate it from, so
  its full spec must be read from `docker inspect` before any change. Recreating
  it from memory will lose the GPU pinning, the port binding and the env file.
- **[C] Do not restart `qwen35` casually.** Load time for FP8 weights plus KV
  cache allocation is minutes, and callers 502 throughout. Confirm the number.
- **[M] Never pass an API key as a command-line argument.** `kg-bge-m3` did
  until 2026-09-08, which made the key readable by **any** user on this shared
  host via `ps` — not just root. It is now supplied via `--env-file` from a
  mode-600 file. vLLM reads `VLLM_API_KEY`. See
  `../decisions/credential-storage.md`.
- **[C] Do not change driver or CUDA versions** — shared host, other teams.
  See `gpu-capacity.md`.

## Escalation

`?` See `../oncall.md`. Model-gateway credential owner is unfilled.
