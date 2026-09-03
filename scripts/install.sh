#!/usr/bin/env bash
#
# install.sh — onboard this machine onto the shared Claude config repo.
#
# Clones (or pulls) the repo, then symlinks the well-known Claude Code paths at
# ~/.claude to the repo copies. Idempotent: safe to re-run any number of times.
# Nothing is ever overwritten or deleted without first being moved into
# ~/.claude/backups/<UTC timestamp>/.
#
# Usage:
#   scripts/install.sh                       # run from an existing clone
#   REPO_URL=<git-url> scripts/install.sh    # clone fresh, then link
#
# Env:
#   REPO_URL   git remote to clone from if REPO_DIR does not exist yet
#   REPO_DIR   where the clone lives          (default: ~/claude-config)
#   CLAUDE_DIR Claude Code home               (default: ~/.claude)
#   CLAUDE_HOST stable fleet name for this machine (default: `hostname`)
#   DRY_RUN=1  print what would happen, change nothing

set -euo pipefail

REPO_DIR="${REPO_DIR:-$HOME/claude-config}"
CLAUDE_DIR="${CLAUDE_DIR:-$HOME/.claude}"
REPO_URL="${REPO_URL:-}"
DRY_RUN="${DRY_RUN:-0}"

BACKUP_DIR="$CLAUDE_DIR/backups/$(date -u +%Y%m%dT%H%M%SZ)"

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

log()  { printf '[install] %s\n' "$*"; }
die()  { printf '[install] ERROR: %s\n' "$*" >&2; exit 1; }
run()  { if [ "$DRY_RUN" = 1 ]; then printf '[dry-run] %s\n' "$*"; else "$@"; fi; }

# A bare 12-hex-digit hostname is a Docker container ID: it changes on every
# recreate, which orphans hosts/<name>.md and scatters proposal branches. Warn
# loudly, but do not fail — a first run on a fresh container should still work.
if [ "$CLAUDE_HOST_PINNED" = 0 ] && printf '%s' "$CLAUDE_HOST" | grep -qE '^[0-9a-f]{12}$'; then
  log "WARNING: CLAUDE_HOST is unset and hostname '$CLAUDE_HOST' looks like a"
  log "WARNING: container ID, not a fleet name. It will change when this"
  log "WARNING: container is recreated. Pin a stable name with:"
  log "WARNING:     echo 'CLAUDE_HOST=my-fleet-name' >> $HOST_ENV_FILE"
fi

# --- 1. get or update the repo ------------------------------------------------

if [ -d "$REPO_DIR/.git" ]; then
  log "repo present at $REPO_DIR — pulling"
  if [ "$DRY_RUN" = 1 ]; then
    printf '[dry-run] git -C %s pull --ff-only\n' "$REPO_DIR"
  elif ! git -C "$REPO_DIR" remote get-url origin >/dev/null 2>&1; then
    log "no 'origin' remote configured — skipping pull, using working copy as-is"
  elif ! git -C "$REPO_DIR" pull --ff-only; then
    die "pull failed (local commits or dirty tree?). Resolve in $REPO_DIR, then re-run."
  fi
elif [ -n "$REPO_URL" ]; then
  log "cloning $REPO_URL -> $REPO_DIR"
  run git clone "$REPO_URL" "$REPO_DIR"
else
  die "$REPO_DIR is not a git clone and REPO_URL is unset. Set REPO_URL=<git-url>."
fi

for required in CLAUDE.md skills commands; do
  [ -e "$REPO_DIR/$required" ] || die "repo is missing $required — wrong REPO_DIR?"
done

# --- 2. symlink ~/.claude paths to the repo -----------------------------------

run mkdir -p "$CLAUDE_DIR"

# link_one <repo-relative source> <absolute target under ~/.claude>
link_one() {
  local src="$REPO_DIR/$1" dest="$2" name="$1"

  # Already pointing where we want it: nothing to do (idempotency).
  if [ -L "$dest" ] && [ "$(readlink -f "$dest" 2>/dev/null)" = "$(readlink -f "$src")" ]; then
    log "$name already linked correctly — skipping"
    return
  fi

  # Anything else in the way gets backed up first, never clobbered.
  if [ -e "$dest" ] || [ -L "$dest" ]; then
    run mkdir -p "$BACKUP_DIR"
    log "backing up existing $dest -> $BACKUP_DIR/"
    if [ "$DRY_RUN" = 1 ]; then
      printf '[dry-run] mv %s %s/\n' "$dest" "$BACKUP_DIR"
    else
      # cp -a first so a mid-run failure still leaves a copy behind.
      cp -a "$dest" "$BACKUP_DIR/" || die "backup of $dest failed — refusing to touch it"
      rm -rf "$dest"
    fi
  fi

  log "linking $dest -> $src"
  run ln -s "$src" "$dest"
}

link_one CLAUDE.md "$CLAUDE_DIR/CLAUDE.md"
link_one skills    "$CLAUDE_DIR/skills"
link_one commands  "$CLAUDE_DIR/commands"

# --- 3. per-host file ---------------------------------------------------------

HOST_FILE="$REPO_DIR/hosts/$CLAUDE_HOST.md"
if [ ! -e "$HOST_FILE" ]; then
  log "note: no hosts/$CLAUDE_HOST.md in the repo (fine — create one if this host needs overrides)"
else
  log "per-host file present: hosts/$CLAUDE_HOST.md (not auto-linked; include it from CLAUDE.md if wanted)"
fi

if [ -d "$BACKUP_DIR" ]; then
  log "backups written to $BACKUP_DIR"
fi
log "done."
