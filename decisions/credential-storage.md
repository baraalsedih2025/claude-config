# credential-storage

- **Decided**: 2026-09-08
- **Status**: current — **known policy gap, migration pending**

## What was decided

Nine credentials for the RAG and model-serving stack currently live in
mode-`600` `.env` files on a single host, with **no secrets manager**. This is
recorded as a *known and accepted* gap with a migration target, not as a
sanctioned end state.

It is written down so that whoever finds it does not have to work out whether it
is an oversight, a deliberate choice, or an incident. It is the first of those,
already acknowledged.

## Current state

| Store (mode 600) | Credential names |
|---|---|
| `LLM-Optimizer/.env` | `TEMP_LLM_MASTER_KEY`, `TEMP_LLM_VLLM_KEY`, `RAG_API_KEY`, `AWS_ACCESS_KEY_ID`, `AWS_SECRET_ACCESS_KEY`, `RAG_PG_PASSWORD`, `PG_PASSWORD` |
| `LLM-Optimizer/.env.parallel` | `RAG_V2_API_KEY` |
| `LLM-Optimizer/.env.legacy-rag` | `RAG_LEGACY_API_KEY` |

Names only, deliberately. No value appears in this repo.

What is actually in place today: file permissions (`600`), single-host
containment, `.gitignore` coverage for `.env*`, and a `gitleaks` pre-commit hook
plus a `gitleaks` gate in both `fleet-sync.sh` and `nightly-review.sh`. That is
enough to stop accidental commits. It is not a vault.

## Why it is like this

The stack grew as a research and iteration environment — parallel RAG variants,
a legacy path kept alive for comparison, temporary model servers stood up and
torn down. `.env` files were the fastest thing that worked, and each new variant
copied the pattern rather than introducing infrastructure.

The cost only became visible when the credentials were enumerated for
absence-cover: what looked like a handful turned out to be nine, all held by one
person, on one host, with no second copy and no rotation record.

## What this costs, concretely

- **No rotation story.** Nobody can tell when any of these was last changed, or
  which services would break if one were rotated now.
- **No second holder.** If the host is lost, the credentials are lost with it —
  and `runbooks/backup-restore.md` cannot yet say whether anything is recoverable.
- **No audit trail.** No record of who read a value or when.
- **`AWS_ACCESS_KEY_ID` / `AWS_SECRET_ACCESS_KEY` are long-lived static keys on
  disk.** This is the item an external reviewer flags first, and the one with a
  standard remedy (an instance role or short-lived credentials) that does not
  require a vault to exist first.

## Migration target

In order, because each step is useful even if the next is delayed:

1. **Replace the static AWS keys with an instance role** (or short-lived
   credentials). Independent of everything else here, and removes the
   highest-severity item. Tracked as a blocking pre-leave item in
   `../oncall.md`.
2. **Pick the store**, and use the one the organisation already runs rather than
   introducing a new dependency: `?` AWS Secrets Manager / SSM Parameter Store /
   Vault / 1Password / other — decision owner `?`.
3. **Move the RAG and gateway keys** (`RAG_API_KEY`, `RAG_V2_API_KEY`,
   `RAG_LEGACY_API_KEY`, `TEMP_LLM_MASTER_KEY`, `TEMP_LLM_VLLM_KEY`), fetched at
   process start rather than baked into a file.
4. **Move the database passwords** (`RAG_PG_PASSWORD`, `PG_PASSWORD`).
5. **Record a rotation schedule and a second holder** for each, so this file can
   be closed.

The deployed-stack pattern already in use is the model to copy: non-secret
settings in version-controlled per-environment files, secrets in a separate
mode-`0600` file loaded at runtime and never committed. The gap is that the
secret half currently has no store behind it.

## What this rules out

- **Do not commit any of these files, ever**, including to a branch "just to
  share them". `.gitignore` and the `gitleaks` hooks are what currently stand
  between this gap and a public leak; treat them as load-bearing.
- **Do not paste a value into a chat, ticket, or transcript** to hand it over.
  Transcripts on this host are read by `nightly-review.sh`; a pasted credential
  ends up in the material it scans. (This already happened once, on 2026-09-08,
  and required scrubbing three files.)
- **Do not copy the `.env` files to a second host** as a "backup". That doubles
  the exposure without adding recoverability.
- **Do not treat `600` permissions as equivalent to a vault** when deciding what
  else to put there. New credentials should go to the chosen store, not extend
  this pattern.

## How you would know this was wrong

- If the chosen store lands and the `.env` files persist anyway, the migration
  failed and this file should say so rather than describing an intent.
- If a rotation is ever needed urgently and nobody can determine the blast
  radius, that is the cost being realised — record it in `../oncall.md`'s
  incident log.
- If the count grows past nine, the pattern is still spreading and step 2 should
  be pulled forward.
