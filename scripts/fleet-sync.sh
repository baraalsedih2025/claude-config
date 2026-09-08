#!/usr/bin/env bash
#
# fleet-sync.sh — collect this host's Claude config drift, classify it, and open
# a PR against main for review.
#
# install.sh symlinks ~/.claude/CLAUDE.md, skills/ and commands/ into this repo,
# so any local edit to the live config shows up here as an uncommitted change.
# This script packages those changes as one reviewable PR per host per day.
#
# Guarantees:
#   * never commits to main, never pushes main, never merges, never --no-verify
#   * fails closed if gitleaks or gh is missing — no regex fallback for secrets
#   * exits 0 and opens NO PR when the tree is clean (no empty nightly PRs)
#   * reuses today's branch and today's PR instead of opening a second
#   * logs to ~/.claude-fleet-sync.log
#
# Env:
#   REPO_DIR       default ~/claude-config
#   CLAUDE_DIR     default ~/.claude
#   LOG_FILE       default ~/.claude-fleet-sync.log
#   CLAUDE_BIN     default `claude` from PATH
#   MODEL          default claude-sonnet-5   (classification only; advisory)
#   EFFORT         default medium            (reasoning effort for MODEL)
#   EXPECT_ORIGIN  default the fleet repo; set to '' to skip the origin check
#   CLAUDE_HOST    stable fleet name for this machine (default: `hostname`)
#   NO_PUSH=1      do everything but the push and the PR
#   NO_PR=1        push the branch but do not open a PR

set -euo pipefail

REPO_DIR="${REPO_DIR:-$HOME/claude-config}"
CLAUDE_DIR="${CLAUDE_DIR:-$HOME/.claude}"
LOG_FILE="${LOG_FILE:-$HOME/.claude-fleet-sync.log}"
CLAUDE_BIN="${CLAUDE_BIN:-claude}"
MODEL="${MODEL:-claude-sonnet-5}"
EFFORT="${EFFORT:-medium}"
NO_PUSH="${NO_PUSH:-0}"
NO_PR="${NO_PR:-0}"
EXPECT_ORIGIN="${EXPECT_ORIGIN-https://github.com/baraalsedih2025/claude-config}"

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
BRANCH="sync/${DATE}-${HOST}"
PR_TITLE="sync: ${HOST} ${DATE}"

# Cron gets a bare PATH; make sure node-managed `claude`, and anything installed
# into ~/.local/bin (gitleaks, gh), are still findable.
if [ -d "$HOME/.nvm/versions/node" ]; then
  for d in "$HOME"/.nvm/versions/node/*/bin; do
    [ -d "$d" ] && PATH="$d:$PATH"
  done
fi
PATH="$HOME/.local/bin:$PATH"
export PATH

mkdir -p "$(dirname "$LOG_FILE")"
exec >> "$LOG_FILE" 2>&1

log()  { printf '%s [fleet-sync] %s\n' "$(date -u +%FT%TZ)" "$*"; }
die()  { printf '%s [fleet-sync] FAIL: %s\n' "$(date -u +%FT%TZ)" "$*"; exit 1; }

# Individual temp files, cleaned with a plain `rm -f` — same idiom as
# nightly-review.sh. Deliberately not a mktemp -d: a recursive delete in a trap
# that fires on every exit path is a worse failure mode than ten named files.
F_CHANGED="$(mktemp)"; F_DIFF="$(mktemp)";     F_MAINCHG="$(mktemp)"
F_CONFL="$(mktemp)";   F_CLASS="$(mktemp)";    F_CPROMPT="$(mktemp)"
F_CERR="$(mktemp)";    F_GLJSON="$(mktemp)";   F_GLLOG="$(mktemp)"
F_BODY="$(mktemp)"
trap 'rm -f "$F_CHANGED" "$F_DIFF" "$F_MAINCHG" "$F_CONFL" "$F_CLASS" \
             "$F_CPROMPT" "$F_CERR" "$F_GLJSON" "$F_GLLOG" "$F_BODY"' EXIT

log "=== start (host=$HOST branch=$BRANCH repo=$REPO_DIR) ==="

# A bare 12-hex hostname is a container ID: it changes on every recreate, which
# scatters sync branches under names nobody can trace back to a machine.
if [ "$CLAUDE_HOST_PINNED" = 0 ] && printf '%s' "$HOST" | grep -qE '^[0-9a-f]{12}$'; then
  log "WARNING: CLAUDE_HOST unset and hostname '$HOST' looks like a container ID."
  log "WARNING: pin it with: echo 'CLAUDE_HOST=my-fleet-name' >> $HOST_ENV_FILE"
fi

# --- 0. preflight: tools, repo, origin ---------------------------------------
#
# gitleaks and gh are hard requirements. A sync that cannot scan for secrets
# must not commit, and one that cannot open a PR would push a branch nobody
# reviews — both fail closed rather than quietly degrade.
command -v gitleaks >/dev/null 2>&1 || die "gitleaks not on PATH ($PATH) — refusing to run (no regex fallback)"
command -v gh       >/dev/null 2>&1 || die "gh not on PATH ($PATH) — refusing to run"
command -v git      >/dev/null 2>&1 || die "git not on PATH ($PATH)"

[ -d "$REPO_DIR/.git" ] || die "$REPO_DIR is not a git clone"
cd "$REPO_DIR"

git remote get-url origin >/dev/null 2>&1 || die "no 'origin' remote configured — add one first"
ORIGIN_URL="$(git remote get-url origin)"
log "origin: $ORIGIN_URL"

if [ -n "$EXPECT_ORIGIN" ]; then
  # Compare with any .git suffix and trailing slash normalised away, so the
  # https and https+.git spellings of the same remote both pass.
  _norm() { printf '%s' "${1%/}" | sed -e 's/\.git$//'; }
  if [ "$(_norm "$ORIGIN_URL")" != "$(_norm "$EXPECT_ORIGIN")" ]; then
    die "origin is '$ORIGIN_URL', expected '$EXPECT_ORIGIN' — refusing to guess (set EXPECT_ORIGIN='' to skip)"
  fi
fi

# Prove the credential actually WORKS rather than that `gh auth status` is
# happy. status exits nonzero over cosmetic complaints -- a classic PAT with
# `repo` (all this script needs) is reported as "Missing required token scopes:
# read:org", and any other stale account stored in hosts.yml also fails it.
# `gh api user` is the real test: it either authenticates or it does not.
GH_LOGIN="$(gh api user --jq .login 2>/dev/null || true)"
[ -n "$GH_LOGIN" ] || die "gh cannot authenticate — set GH_TOKEN (see $HOST_ENV_FILE) or run 'gh auth login'"
log "authenticated to github as $GH_LOGIN"

# --- 0a. pull main from origin, before reading any local state ---------------
#
# Without this the clone drifts behind origin/main every day and this host keeps
# proposing changes against a stale baseline. Fast-forward only; a dirty tree
# skips the pull and continues; divergence aborts. See scripts/lib/pull.sh.
_LIB="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)/lib/pull.sh"
[ -f "$_LIB" ] || die "missing $_LIB — refusing to run without the pull step"
# shellcheck source=lib/pull.sh
. "$_LIB"
pull_main

# --- 0b. credential-shaped files, BEFORE the clean-tree exit ------------------
#
# This runs on every invocation, including runs with nothing to sync, and that
# ordering is deliberate. .gitignore hides .env/*.key/*.pem from `git status`,
# so a credential sitting in the config repo leaves the tree looking CLEAN --
# and a check placed after the clean-tree exit would never once run against the
# only case it exists to catch. Fail loudly instead: a stray credential here is
# worth a failed nightly run, and no PR is opened either way.
log "checking for credential-shaped files present in the tree"
CRED_HITS="$(
  /usr/bin/find "$REPO_DIR" -path "$REPO_DIR/.git" -prune -o -type f \
    \( -name '.env' -o -name '.env.*' -o -name '*.env' \
       -o -name '*.pem' -o -name '*.key' -o -name '*.p12' -o -name '*.pfx' \
       -o -name '*.crt' -o -name '*.cer' -o -name 'id_rsa*' -o -name 'id_ed25519*' \
       -o -name '*credentials*' -o -name '.netrc' -o -name '.pgpass' \
       -o -name '*.kubeconfig' -o -name 'kubeconfig' \) -print 2>/dev/null \
    | grep -v '\.env\.example$' || true
)"
if [ -n "$CRED_HITS" ]; then
  log "credential-shaped files found:"
  printf '%s\n' "$CRED_HITS" | sed 's/^/    /'
  die "credential-shaped file present in $REPO_DIR — remove or relocate it, then re-run"
fi
log "no credential-shaped files present"

# --- 1. state: is there anything to sync? ------------------------------------

STATUS="$(git status --porcelain)"

if [ -z "$STATUS" ]; then
  log "working tree clean — nothing to sync, no branch, no PR"
  log "=== end (ok, clean) ==="
  exit 0
fi

log "working tree is dirty:"
printf '%s\n' "$STATUS" | sed 's/^/    /'

CURRENT_BRANCH="$(git rev-parse --abbrev-ref HEAD)"
log "current branch: $CURRENT_BRANCH"
log "recent history:"
git log --oneline -5 | sed 's/^/    /'

log "fetching origin"
git fetch -q origin || die "git fetch failed"

# Record the divergence point BEFORE moving off the current branch, so we can
# report which files main also touched since this host last pulled.
BASE="$(git merge-base HEAD origin/main 2>/dev/null || true)"
BEHIND=0; AHEAD=0
if [ -n "$BASE" ]; then
  read -r BEHIND AHEAD < <(git rev-list --left-right --count origin/main...HEAD | awk '{print $1" "$2}')
fi
log "HEAD is $BEHIND behind and $AHEAD ahead of origin/main"

# Paths changed locally: tracked modifications plus untracked additions. The
# porcelain status code is two columns wide, so cut from column 4.
git status --porcelain | cut -c4- | sed 's/^"//; s/"$//' | sort -u > "$F_CHANGED"
log "changed paths: $(wc -l < "$F_CHANGED" | tr -d ' ')"

# Full diff of tracked modifications, for the log and for classification.
git diff > "$F_DIFF" || true
log "tracked diff: $(wc -c < "$F_DIFF" | tr -d ' ') bytes"
if [ -s "$F_DIFF" ]; then
  log "----- begin diff -----"
  sed 's/^/    /' "$F_DIFF"
  log "----- end diff -----"
fi

# --- 2. which files main also moved since this host last pulled ---------------
#
# These are the hand-merge candidates: changed here AND changed on main.
: > "$F_CONFL"
if [ -n "$BASE" ]; then
  git diff --name-only "$BASE" origin/main | sort -u > "$F_MAINCHG"
  comm -12 "$F_CHANGED" "$F_MAINCHG" > "$F_CONFL" || true
fi
if [ -s "$F_CONFL" ]; then
  log "also changed on origin/main since this host last pulled:"
  sed 's/^/    /' "$F_CONFL"
else
  log "no overlap with origin/main changes"
fi

# --- 3. classify fleet-wide vs host-local (advisory) --------------------------
#
# Advisory only: a classification failure must not block a sync that has already
# passed its secret scan, so this degrades to a note in the PR body.
: > "$F_CLASS"
if command -v "$CLAUDE_BIN" >/dev/null 2>&1; then
  {
    echo "You are triaging uncommitted changes in a shared, fleet-wide Claude Code"
    echo "config repo. Host is ${HOST}; today is ${DATE}."
    echo
    echo "Shared, fleet-wide paths:  CLAUDE.md, skills/, commands/"
    echo "Host-only path:            hosts/${HOST}.md"
    echo
    echo "## Changed paths"
    cat "$F_CHANGED"
    echo
    echo "## Diff of tracked changes"
    echo '```diff'
    head -c 60000 "$F_DIFF"
    echo '```'
    echo
    echo "## Task"
    echo "For each changed path say whether it is FLEET-WIDE (belongs in the shared"
    echo "files, true of every host) or HOST-LOCAL (true only of ${HOST}, belongs in"
    echo "hosts/${HOST}.md)."
    echo
    echo "Then flag any content inside a SHARED file that reads host-specific: an"
    echo "absolute path only this box has, a hostname, a container name, a port, a"
    echo "package that is not installed everywhere. Do NOT propose moving it and do"
    echo "not rewrite anything — just name the file, quote the line, say why."
    echo
    echo "Never echo a secret, token, key or credential. Redact if you must refer to one."
    echo "Be terse: markdown bullets, no preamble, no summary of this prompt."
  } > "$F_CPROMPT"

  log "classifying with $CLAUDE_BIN -p --model $MODEL --effort $EFFORT"
  # --permission-mode plan keeps this read-only: it reasons over the diff handed
  # to it on stdin and cannot write into the repo it is describing.
  if "$CLAUDE_BIN" -p --model "$MODEL" --effort "$EFFORT" \
       --permission-mode plan --output-format text \
       < "$F_CPROMPT" > "$F_CLASS" 2>"$F_CERR"; then
    log "classification: $(wc -c < "$F_CLASS" | tr -d ' ') bytes"
  else
    log "WARNING: classification failed (stderr below) — continuing without it"
    sed 's/^/    /' "$F_CERR" || true
    printf '_Classification unavailable: `%s -p` exited nonzero on this run._\n' "$CLAUDE_BIN" > "$F_CLASS"
  fi
else
  log "WARNING: $CLAUDE_BIN not on PATH — continuing without classification"
  printf '_Classification unavailable: `%s` not found on PATH._\n' "$CLAUDE_BIN" > "$F_CLASS"
fi

# --- 4. secret scan, before anything is staged --------------------------------
#
# Two passes, because they catch different things:
#   * gitleaks over the working tree — content that looks like a credential
#   * a filename pass — a whole .env/key/cert sitting in the tree, which a
#     content scanner can miss and which .gitignore would hide from review
log "scanning working tree with gitleaks $(gitleaks version 2>/dev/null || echo '?')"
# --exit-code 2 separates "found a leak" (2) from "the scanner itself failed"
# (any other nonzero). Both still refuse to commit, but they are different
# problems and collapsing them hides a broken scanner behind a secret warning.
# --report-format is explicit because gitleaks infers it from the report path's
# extension, and an extensionless temp file makes it exit "Unknown report format".
GL_RC=0
gitleaks dir "$REPO_DIR" \
  --no-banner --redact --exit-code 2 \
  --report-format json --report-path "$F_GLJSON" >"$F_GLLOG" 2>&1 || GL_RC=$?
case "$GL_RC" in
  0) log "gitleaks clean" ;;
  2) log "gitleaks found secrets — nothing staged, nothing committed:"
     sed 's/^/    /' "$F_GLLOG"
     die "possible secret in working tree — resolve, then re-run" ;;
  *) log "gitleaks failed to run (exit $GL_RC):"
     sed 's/^/    /' "$F_GLLOG"
     die "secret scan could not complete — refusing to commit unscanned changes" ;;
esac

# (the credential-filename pass ran in step 0b, before the clean-tree exit)

# --- 5. branch off origin/main, reusing today's branch if it exists -----------

# switch_to <branch> [start-point]
#
# An untracked local file that the TARGET ref already tracks makes plain
# `git checkout` abort with "untracked working tree files would be overwritten"
# -- and that is the normal case on the second run of a day: run 1 committed
# hosts/<host>.md onto the branch, someone went back to main, and the live
# config recreated the file as untracked. Those files are precisely the drift
# being collected and the local copy is the newer one, so set them aside,
# switch, and lay them back on top; git then sees a modification instead of a
# collision. Never -f: that would discard the drift this script exists to keep.
switch_to() {
  local br="$1" start="${2:-}" target kept=() f rc=0
  target="${start:-$br}"

  while IFS= read -r f; do
    [ -n "$f" ] || continue
    if git cat-file -e "$target:$f" 2>/dev/null; then
      mv -- "$f" "$f.fleetsync-keep" && kept+=("$f")
    fi
  done < <(git ls-files --others --exclude-standard)

  [ "${#kept[@]}" -gt 0 ] && log "set aside ${#kept[@]} untracked file(s) that $target already tracks"

  if [ -n "$start" ]; then
    git checkout -q -B "$br" "$start" || rc=$?
  else
    git checkout -q "$br" || rc=$?
  fi

  for f in "${kept[@]}"; do
    mv -f -- "$f.fleetsync-keep" "$f" || rc=1
  done
  return "$rc"
}

if git show-ref --verify --quiet "refs/heads/$BRANCH"; then
  log "reusing existing local branch $BRANCH"
  switch_to "$BRANCH" || die "cannot check out $BRANCH"
elif git show-ref --verify --quiet "refs/remotes/origin/$BRANCH"; then
  log "reusing existing remote branch origin/$BRANCH"
  switch_to "$BRANCH" "origin/$BRANCH" || die "cannot track origin/$BRANCH"
else
  log "creating $BRANCH off origin/main"
  switch_to "$BRANCH" origin/main || die "cannot create $BRANCH off origin/main (conflicting local changes?)"
fi

[ "$(git rev-parse --abbrev-ref HEAD)" != "main" ] || die "refusing to operate on main"

git add -A || die "git add failed"

STAGED="$(git diff --cached --name-only)"
if [ -z "$STAGED" ]; then
  log "nothing staged after add (all changes ignored by .gitignore) — no PR"
  git checkout -q "$CURRENT_BRANCH" 2>/dev/null || true
  log "=== end (ok, nothing to commit) ==="
  exit 0
fi
log "staged paths:"; printf '%s\n' "$STAGED" | sed 's/^/    /'

# Belt and braces: .gitignore should already exclude these, but a committed
# credential is the one mistake a later commit cannot undo.
if printf '%s\n' "$STAGED" | grep -qEi '(^|/)(\.env($|\..*)|.*\.(pem|key|p12|pfx|crt|cer)|id_rsa.*|id_ed25519.*|\.netrc|\.pgpass|.*credentials.*|kubeconfig)$'; then
  log "refusing: a staged path is credential-shaped"
  git reset -q
  die "credential-shaped path staged — nothing committed"
fi

if git diff --cached --quiet; then
  log "staged tree identical to $BRANCH — nothing new to commit"
else
  git commit -q -m "sync: ${HOST} ${DATE}

Config drift collected from ${HOST} by scripts/fleet-sync.sh.
Review before merging; nothing here has been merged to main." \
    || die "commit failed"
  log "committed $(git rev-parse --short HEAD) on $BRANCH"
fi

if [ "$NO_PUSH" = 1 ]; then
  log "NO_PUSH=1 — branch left local, no PR"
  log "=== end (ok, local only) ==="
  exit 0
fi

git push -q -u origin "$BRANCH" || die "push of $BRANCH failed"
log "pushed $BRANCH"

# --- 6. open the PR, or push into today's existing one ------------------------

if [ "$NO_PR" = 1 ]; then
  log "NO_PR=1 — branch pushed, PR not opened"
  log "=== end (ok, no PR) ==="
  exit 0
fi

EXISTING_PR="$(gh pr list --head "$BRANCH" --state open --json number --jq '.[0].number' 2>/dev/null || true)"
if [ -n "$EXISTING_PR" ] && [ "$EXISTING_PR" != "null" ]; then
  log "PR #$EXISTING_PR already open for $BRANCH — pushed into it, not opening a second"
  log "=== end (ok, existing PR #$EXISTING_PR) ==="
  exit 0
fi

{
  echo "Config drift collected automatically from **${HOST}** on ${DATE} by"
  echo "\`scripts/fleet-sync.sh\`. Nothing has been merged; \`main\` is untouched."
  echo
  echo "## What changed on this host"
  echo
  echo '```'
  printf '%s\n' "$STATUS"
  echo '```'
  echo
  echo "## Fleet-wide vs host-local"
  echo
  echo "Classified by \`claude -p --model ${MODEL} --effort ${EFFORT}\`. Advisory — confirm before merging."
  echo
  cat "$F_CLASS"
  echo
  echo "## Also changed on \`main\` since this host last pulled"
  echo
  if [ -s "$F_CONFL" ]; then
    echo "These will need hand-merging:"
    echo
    echo '```'
    cat "$F_CONFL"
    echo '```'
  else
    echo "None — no overlap with \`main\`."
  fi
  echo
  echo "## Provenance"
  echo
  echo "- Host: \`${HOST}\` (pinned: $([ "$CLAUDE_HOST_PINNED" = 1 ] && echo yes || echo "no — from \`hostname\`"))"
  echo "- Branch: \`${BRANCH}\`, branched off \`origin/main\`"
  echo "- HEAD was ${BEHIND} behind / ${AHEAD} ahead of \`origin/main\` at collection time"
  echo "- Secret scan: \`gitleaks dir\` clean, plus a credential-filename pass"
  echo "- Log: \`${LOG_FILE}\` on ${HOST}"
} > "$F_BODY"

PR_URL="$(gh pr create --base main --head "$BRANCH" --title "$PR_TITLE" --body-file "$F_BODY" 2>&1)" \
  || die "gh pr create failed: $PR_URL"
log "opened PR: $PR_URL"
log "=== end (ok) ==="
