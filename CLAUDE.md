## Daily memory review

At the start of the first session of each day, before other work, check whether
yesterday's sessions produced anything worth remembering.

1. Find yesterday's transcripts (JSONL, one per session):

       Y=$(date -d yesterday +%F); T=$(date +%F)
       find ~/.claude/projects -name '*.jsonl' -newermt "$Y" ! -newermt "$T"

   Use **ISO dates, not the words `yesterday`/`today`**, in `-newermt`:
   GNU `find` parses `today` as *now*, not midnight, so `! -newermt today`
   filters out nothing and today's own sessions leak in.
   Skip this session's own file. If nothing comes back, say nothing and carry on.
   Transcripts are periodically pruned (see `~/.claude/.last-cleanup`), so a day
   of work can legitimately leave no file.

2. Read them for things that would have saved time if known in advance:
   corrections the user gave, non-obvious infrastructure facts, traps where
   something appeared to work but silently didn't, and decisions whose rationale
   isn't recoverable from the code.

   Each line is one JSON object with a `type` (`user`, `assistant`, plus
   bookkeeping types `attachment`, `queue-operation`, `ai-title`,
   `last-prompt`, `file-history-snapshot`) and, for the first two,
   `message.content` that is either a string or a list of content blocks.
   `cwd` on user/assistant lines says which project the session ran in.
   Filter to the user/assistant text rather than reading the raw file — these
   run to thousands of lines.

3. Memory is **per project**: `~/.claude/projects/<cwd-slug>/memory/`, with its
   own `MEMORY.md` index (e.g. `~/.claude/projects/-workspace-Bara/memory/`).
   Write each fact to the memory directory of the project the session ran in,
   creating the directory and an empty `MEMORY.md` if that project has none yet.
   One fact per file, plus a one-line pointer in that project's `MEMORY.md`.
   Update an existing memory rather than duplicating it; delete ones proven wrong.

4. Report in one or two lines what was saved, or that nothing was.

Do NOT save: what the repo already records (structure, git history, past fixes),
anything that only mattered to that one conversation, or secrets. Prefer the
specific trap over the general lesson — "environment: silently overrides
env_file:" is useful; "be careful with config" is not.

## Response length

Default to short. Lead with the answer or the result; then only what the user
has to act on. Stop there.

Do not restate the request, re-summarise work already reported earlier in the
session, or wrap a two-line answer in headings and tables. Report the finding,
not the search for it — when something is verified, one line saying so beats
the commands that proved it.

Length is earned, not assumed. Go longer only when asked, or when a caveat
would change what the user does next: a blocker, a live credential, a
destructive side effect. "Here is the state of everything" is not such a case.

The failure mode this exists to stop: answering a one-line question with a
full status report, so the user has to say "shortly" over and over to get the
answer out. If the reply needs a heading, ask first whether it needs to exist.

## Who you are working with

@BaraAlSedih.md

That profile carries role, stack, working preferences, environment quirks and
current projects, and applies on every host. Read it before assuming anything
about the setup or about how a reply should be pitched; correct it when it turns
out to be wrong rather than working around it.

## Operational knowledge

Three directories carry what someone covering for the owner would need. Read
the relevant one before diagnosing or changing a system, and propose additions
when a session turns up something they lack.

- `runbooks/<system>.md` — per system: what it does, where it runs, symptom →
  diagnosis → fix, how to verify health, what looks broken but isn't, and what
  must NOT be done. See `runbooks/README.md` for the required sections.
- `decisions/<topic>.md` — why things are as they are; specifically the choices
  that look wrong or arbitrary until explained. See `decisions/README.md`.
- `oncall.md` — escalation paths, upstream owners, and access held by one
  person only.

`BaraAlSedih.md` is context about the *person*; these are the operational
facts, and they must stand on their own without him. Never put a credential
value in any of them — name the store and who grants access.
