# bge-m3-public-exposure

- **Decided**: 2026-09-08
- **Status**: current — **accepted risk, deliberate**
- **Review by**: **2026-12-07** (90 days — see trigger 6)

## Scope

**This file covers `bge-m3.dev.iohealth.com` only.**

`rag.dev.iohealth.com` is a *different posture* — key-gated at the proxy, and
not an accepted risk. It is recorded separately in `rag-dev-key-gating.md`.
Do not merge the two: the distinction between "open, guarded by the model
server's own key" and "gated at the proxy per caller" is the one that matters
when reasoning about either.

## What was decided

`bge-m3.dev.iohealth.com` stays directly reachable from the public internet,
gated only by the model server's own API key. This is the owner's explicit
decision, not an oversight.

This file exists so nobody "fixes" it. An earlier reading of the same facts
raised the exposure as a blocking security item; it is not. What was genuinely
missing was the record of the decision, plus access logging — both now in place.

## What is exposed [M, verified 2026-09-08]

| | |
|---|---|
| Host | `bge-m3.dev.iohealth.com` → public DNS → this host's public IP |
| Proxy gate | **none** — Caddy applies no key check on this route |
| Actual gate | the vLLM server's own `VLLM_API_KEY` |
| Backend | `127.0.0.1:8000`, container `kg-bge-m3` |
| Surface | OpenAI-compatible embedding API: `/v1/embeddings`, `/v1/models` |

Reachability is proven, not assumed: Caddy runs `network=host` on `*:80`/`*:443`,
and Let's Encrypt renewal requires inbound internet access to succeed.

### What it does NOT expose — the basis for accepting it

The endpoint serves a **stateless model**. It holds no corpus, no documents and
no database; it embeds whatever text a caller submits and returns vectors. The
retrieval corpus, pgvector, the reranker and the cortex service are all behind
`rag.dev` with separate gates.

**A compromise of this key yields compute, not data.** That is the whole
argument, and it is why this is acceptable while a data-bearing service in the
same position would not be.

## Why this is acceptable

- Stateless model, no data behind it.
- The key now lives in a mode-600 env file. Until 2026-09-08 it was passed as
  `--api-key` in the container's command line, where `ps` made it readable by
  **every user** on this shared host. That was the real defect, and it is fixed.
- Direct reachability is operationally useful: callers off this host can embed
  without a tunnel or proxy hop. That is why it was built this way.
- Access logging is now enabled, so abuse becomes visible rather than silent.

## What this costs, accepted knowingly

- **Compute theft is the real exposure.** Anyone with the key can consume GPU
  time. The embedder shares **GPU0** with the reranker and the unified RAG
  service, so sustained abuse degrades retrieval for legitimate users rather
  than merely wasting spare capacity.
- **The key is the entire perimeter.** No IP allowlist, no mTLS, no VPN.
- **No history.** Access logging began 2026-09-08; nothing is known about
  callers or probing before that date.

## What this rules out

- **Do not close the host, add an IP allowlist, or move it behind a VPN**
  without talking to the owner. Callers depend on direct reachability.
- **Do not remove the key gate** on the assumption the network is trusted. It
  is not; the key is the only control.
- **Do not put the key in argv, a commit, an image layer, a ticket or a chat
  message.** On a public endpoint that is equivalent to publishing it.
- **Do not extend this decision to any other host.** It rests on the backend
  being stateless. Adding a data-bearing service to the same open pattern needs
  its own decision.

## How you would know this was wrong

Any one of these should reopen the decision:

1. Access logs show request volume or source diversity that does not match
   known callers — i.e. someone else holds the key.
2. GPU0 contention becomes attributable to external embedding traffic rather
   than to the reranker and unified RAG.
3. The key leaks, or is found in a repo, image layer, or transcript.
4. The embedder gains any stateful or data-bearing capability — at that point
   the "compute, not data" argument fails and this must be revisited
   immediately.
5. A compliance or audit requirement lands that treats an internet-reachable ML
   endpoint as in scope.
6. **2026-12-07 arrives.** A fixed review date, because an accepted risk with
   no expiry becomes permanent by default. On that date, re-read this file
   against the access logs and either renew the acceptance with a new date or
   change the posture. Renewing is a decision too — record it.

## Related

- `rag-dev-key-gating.md` — the other host, deliberately kept separate.
- `credential-storage.md` — this decision raises that one's severity: the key
  is a public-perimeter credential, not an internal one.
- `../runbooks/tls-dns.md` — certificates, routing, access-log configuration.
- `../runbooks/llm-serving.md` — the embedder itself.
