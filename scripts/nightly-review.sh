#!/usr/bin/env bash
#
# nightly-review.sh — mine the last 24h of Claude Code transcripts for habits
# that are not yet captured in CLAUDE.md or skills/, and open a proposal branch.
#
# Guarantees:
#   * never commits to main
#   * never edits CLAUDE.md, skills/ or commands/ — it only adds one file under
#     proposals/, and aborts if anything else turns up staged
#   * logs to ~/.claude-config-review.log, exits nonzero on any failure
#
# Env:
#   REPO_DIR     default ~/claude-config
#   CLAUDE_DIR   default ~/.claude
#   LOG_FILE     default ~/.claude-config-review.log
#   CLAUDE_BIN   default `claude` from PATH
#   CLAUDE_HOST  stable fleet name for this machine (default: `hostname`)
#   MODEL        default opus
#   NO_PUSH=1    do everything but the push (useful for a first dry run)

set -euo pipefail

REPO_DIR="${REPO_DIR:-$HOME/claude-config}"
CLAUDE_DIR="${CLAUDE_DIR:-$HOME/.claude}"
LOG_FILE="${LOG_FILE:-$HOME/.claude-config-review.log}"
CLAUDE_BIN="${CLAUDE_BIN:-claude}"
MODEL="${MODEL:-opus}"
NO_PUSH="${NO_PUSH:-0}"

# --- host identity ------------------------------------------------------------
#
# CLAUDE_HOST is this machine's stable fleet name. Precedence:
#   1. CLAUDE_HOST already exported in the environment
#   2. CLAUDE_HOST set in ~/.claude-config.env  (override HOST_ENV_FILE to move it)
#   3. `hostname` — fine on real hosts, but an ephemeral ID inside a container
_claude_host_preset="${CLAUDE_HOST:-}"
HOST_ENV_FILE="${HOST_ENV_FILE:-$HOME/.claude-config.env}"
if [ -f "$HOST_ENV_FILE" ]; then
  # shellcheck source=/dev/null
  . "$HOST_ENV_FILE"
fi
CLAUDE_HOST="${_claude_host_preset:-${CLAUDE_HOST:-$(hostname)}}"
# Was it pinned deliberately, or did we fall back to `hostname`?
if [ -n "$_claude_host_preset" ] || [ "$CLAUDE_HOST" != "$(hostname)" ]; then
  CLAUDE_HOST_PINNED=1
else
  CLAUDE_HOST_PINNED=0
fi

DATE="$(date +%F)"
HOST="$CLAUDE_HOST"
BRANCH="proposal/${DATE}-${HOST}"
OUT_REL="proposals/${DATE}-${HOST}.md"

# Cron gets a bare PATH; make sure a node-managed `claude` is still findable.
if [ -d "$HOME/.nvm/versions/node" ]; then
  for d in "$HOME"/.nvm/versions/node/*/bin; do
    [ -d "$d" ] && PATH="$d:$PATH"
  done
fi
PATH="$HOME/.local/bin:$PATH"
export PATH

mkdir -p "$(dirname "$LOG_FILE")"
exec >> "$LOG_FILE" 2>&1

log() { printf '%s [nightly-review] %s\n' "$(date -u +%FT%TZ)" "$*"; }
die() { printf '%s [nightly-review] FAIL: %s\n' "$(date -u +%FT%TZ)" "$*"; exit 1; }

log "=== start (host=$HOST branch=$BRANCH) ==="

command -v "$CLAUDE_BIN" >/dev/null 2>&1 || die "'$CLAUDE_BIN' not on PATH ($PATH)"
[ -d "$REPO_DIR/.git" ] || die "$REPO_DIR is not a git clone"
[ -d "$CLAUDE_DIR/projects" ] || die "$CLAUDE_DIR/projects not found — no transcripts to read"

cd "$REPO_DIR"

# --- 0. clean starting point --------------------------------------------------

[ -z "$(git status --porcelain)" ] || die "working tree at $REPO_DIR is dirty — refusing to run"

git remote get-url origin >/dev/null 2>&1 || die "no 'origin' remote configured — add one first"

log "syncing main"
git checkout -q main || die "cannot check out main"
git pull --ff-only -q origin main || die "pull of origin/main failed"

# --- 1. find transcripts touched in the last 24h ------------------------------
#
# Use /usr/bin/find explicitly: an interactive `find` on some hosts is a shell
# function wrapping bfs, and pass an ISO timestamp rather than the words
# "yesterday"/"today" — bfs rejects those and GNU find reads "today" as *now*.

SINCE="$(date -d '24 hours ago' +%FT%T)"
mapfile -t TRANSCRIPTS < <(
  /usr/bin/find "$CLAUDE_DIR/projects" -name '*.jsonl' -newermt "$SINCE" -print | sort
)

log "found ${#TRANSCRIPTS[@]} transcript(s) modified since $SINCE"

if [ "${#TRANSCRIPTS[@]}" -eq 0 ]; then
  log "nothing to review — exiting cleanly"
  log "=== end ==="
  exit 0
fi

# --- 2. ask Claude, headless --------------------------------------------------
#
# The transcript paths are handed over as a list and Claude reads them with its
# own tools; we do not shovel megabytes of JSONL through argv.

PROMPT_FILE="$(mktemp)"
RESULT_FILE="$(mktemp)"
trap 'rm -f "$PROMPT_FILE" "$RESULT_FILE"' EXIT

{
  echo "You are reviewing Claude Code session transcripts to improve a shared,"
  echo "fleet-wide configuration repo. Today is ${DATE}; host is ${HOST}."
  echo
  echo "## Transcripts to read (JSONL, one JSON object per line)"
  printf '%s\n' "${TRANSCRIPTS[@]}"
  echo
  echo "Each line has a \"type\" (\"user\", \"assistant\", and bookkeeping types"
  echo "such as \"attachment\", \"queue-operation\", \"ai-title\", \"last-prompt\","
  echo "\"file-history-snapshot\"). Only \"user\" and \"assistant\" lines carry"
  echo "\"message.content\", which is either a string or a list of content blocks."
  echo "\"cwd\" says which project the session ran in. These files run to thousands"
  echo "of lines: filter to the user/assistant text with jq or grep rather than"
  echo "reading them whole."
  echo
  echo "## Config that ALREADY exists (do not re-propose any of this)"
  echo
  echo "### CLAUDE.md"
  echo '```markdown'
  cat "$REPO_DIR/CLAUDE.md"
  echo '```'
  echo
  echo "### skills/ present in the repo"
  ls -1 "$REPO_DIR/skills" 2>/dev/null | grep -v '^\.gitkeep$' || echo "(none)"
  echo
  echo "### commands/ present in the repo"
  ls -1 "$REPO_DIR/commands" 2>/dev/null | grep -v '^\.gitkeep$' || echo "(none)"
  echo
  echo "## Your task"
  echo
  echo "Identify what appeared REPEATEDLY across these sessions and is NOT already"
  echo "covered above:"
  echo "  1. corrections the user had to give more than once"
  echo "  2. multi-step workflows worth packaging as a skill or slash command"
  echo "  3. stated preferences about how work should be done"
  echo "  4. non-obvious infrastructure facts or traps where something appeared to"
  echo "     work but silently did not"
  echo
  echo "Rules:"
  echo "  - Output ONLY concrete proposed edits. No summary of the sessions, no"
  echo "    praise, no restating this prompt."
  echo "  - Prefer the specific trap over the general lesson. \"environment:"
  echo "    silently overrides env_file:\" is useful; \"be careful with config\" is not."
  echo "  - One-off details that mattered only to a single conversation are out of"
  echo "    scope. So is anything the repo or git history already records."
  echo "  - Never include secrets, tokens, keys, passwords, connection strings or"
  echo "    hostnames-with-credentials. Redact if you must reference one."
  echo "  - Flag anything that looks specific to a single host, so it can go to"
  echo "    hosts/<host>.md instead of the shared CLAUDE.md."
  echo "  - If nothing meets the bar, say exactly: NO PROPOSALS."
  echo
  echo "## Required output format"
  echo
  echo "For each proposal, in descending order of value:"
  echo
  echo "### <short title>"
  echo "- **Target**: CLAUDE.md | skills/<name>/SKILL.md | commands/<name>.md | hosts/${HOST}.md"
  echo "- **Evidence**: which sessions/transcripts, and how many times it came up"
  echo "- **Proposed edit**: the exact text to add, in a fenced block, ready to paste"
} > "$PROMPT_FILE"

log "invoking: $CLAUDE_BIN -p --model $MODEL --permission-mode plan --output-format text"

# --permission-mode plan keeps the review read-only: it can read transcripts but
# cannot write files. Verified against claude 2.1.233.
if ! "$CLAUDE_BIN" -p \
      --model "$MODEL" \
      --permission-mode plan \
      --output-format text \
      --add-dir "$CLAUDE_DIR/projects" \
      < "$PROMPT_FILE" > "$RESULT_FILE"; then
  die "claude -p exited nonzero"
fi

[ -s "$RESULT_FILE" ] || die "claude -p produced no output"

log "review output: $(wc -c < "$RESULT_FILE") bytes"

# --- 3. write the proposal ----------------------------------------------------

mkdir -p "$REPO_DIR/proposals"
{
  echo "# Config proposals — ${DATE} — ${HOST}"
  echo
  echo "- Generated: $(date -u +%FT%TZ)"
  echo "- Transcripts reviewed: ${#TRANSCRIPTS[@]} (modified since ${SINCE})"
  echo "- Model: ${MODEL}"
  echo
  echo "Automated output. Read it, edit it, then merge to \`main\` by hand."
  echo
  echo "---"
  echo
  cat "$RESULT_FILE"
} > "$REPO_DIR/$OUT_REL"

# --- 4. secret scan before staging anything -----------------------------------

log "scanning proposal for secrets"
if grep -nEi \
  -e '(api[_-]?key|secret|passwd|password|access[_-]?token|refresh[_-]?token|bearer)[[:space:]]*[:=][[:space:]]*[A-Za-z0-9/_+=-]{12,}' \
  -e 'BEGIN [A-Z ]*PRIVATE KEY' \
  -e '\b(sk-ant-|ghp_|gho_|github_pat_|AKIA[0-9A-Z]{16}|xox[abprs]-)' \
  -e '(postgres|postgresql|mysql|mongodb\+srv|redis|amqp)://[^[:space:]/]*:[^[:space:]@]+@' \
  "$REPO_DIR/$OUT_REL"
then
  rm -f "$REPO_DIR/$OUT_REL"
  die "possible secret in generated proposal (locations above) — proposal discarded, nothing committed"
fi
log "secret scan clean"

# --- 5. commit on a proposal branch, never main -------------------------------

git checkout -q -B "$BRANCH" || die "cannot create branch $BRANCH"

[ "$(git rev-parse --abbrev-ref HEAD)" != "main" ] || die "refusing to commit on main"

git add -- "$OUT_REL" || die "git add failed"

# Belt and braces: the only thing staged may be this one proposal file.
STAGED="$(git diff --cached --name-only)"
if [ "$STAGED" != "$OUT_REL" ]; then
  log "unexpected staged paths:"; printf '%s\n' "$STAGED"
  git reset -q
  die "refusing to commit — expected only $OUT_REL to be staged"
fi

if git diff --cached --quiet; then
  log "proposal identical to what is already committed — nothing to do"
  git checkout -q main
  log "=== end ==="
  exit 0
fi

git commit -q -m "proposals: ${DATE} review on ${HOST}" || die "commit failed"
log "committed $(git rev-parse --short HEAD) on $BRANCH"

if [ "$NO_PUSH" = 1 ]; then
  log "NO_PUSH=1 — branch left local"
else
  git push -q -u origin "$BRANCH" || die "push of $BRANCH failed"
  log "pushed $BRANCH to origin"
fi

git checkout -q main
log "=== end (ok) ==="
