#!/usr/bin/env bash
# Tag-triggered deploy, driven FROM this server.
#
# Template. Replace every __PLACEHOLDER__ below. Kept quoted so `bash -n` and
# shellcheck still work on the unfilled template. Every comment marks a failure that
# actually happened -- read before deleting one.
#
# Install to /usr/local/bin/__PROJECT__-deploy, mode 0755, owned root:root.
set -euo pipefail

PROJECT="__PROJECT__"
REPO="https://github.com/__ORG__/__REPO__.git"
STAGING="$HOME/$PROJECT-src"                 # a directory the deploy user OWNS
DEPLOY_DIR="/srv/deployments/$PROJECT"         # path as the HOST sees it
COMPOSE_PATH="$DEPLOY_DIR"                   # path as the COMPOSE RUNNER sees it
SEEN="$HOME/.$PROJECT.seen-tags"
BRANCH_FILE="/etc/__PROJECT__-deploy/$PROJECT.branch"
LOCK="/var/lock/$PROJECT-deploy.lock"
OWNER="__USER__:__GROUP__"                         # who should own the deployed files

# Prefix check with a permissive suffix. An over-narrow pattern
# (`release\.[0-9]+`) silently ignores `release.v1` -- and an ignored tag is
# still marked seen, so the name is consumed and re-pushing it does nothing.
TAG_RE='^release\.[A-Za-z0-9._-]+$'

# Plain host compose. For a nested Docker daemon, use instead:
#   compose() { sudo docker exec -w "$COMPOSE_PATH" __DIND__ docker compose "$@"; }
# and remember COMPOSE_PATH is the path as the DinD sees it, NOT the host path.
compose() { docker compose --project-directory "$COMPOSE_PATH" "$@"; }

log() { echo "$(date -Is) $*"; }

# One run at a time: a build outlasts the timer interval, and two concurrent
# rsyncs into the deploy directory would interleave.
exec 9>"$LOCK"
flock -n 9 || { log "another run holds the lock; skipping"; exit 0; }

[ -d "$STAGING/.git" ] || git clone --bare "$REPO" "$STAGING"
cd "$STAGING"
git fetch --tags --prune --force origin '+refs/heads/*:refs/remotes/origin/*' >/dev/null

current=$(git tag -l | sort)

# FIRST RUN SEEDS WITHOUT DEPLOYING, or every existing tag deploys at once and
# the last one wins.
if [ ! -f "$SEEN" ]; then
    printf '%s\n' "$current" > "$SEEN"
    log "seeded $(printf '%s\n' "$current" | grep -c .) existing tags; no deploy"
    exit 0
fi

# NEVER pick "the newest tag" by --sort=-creatordate. A lightweight tag (what
# the GitHub web UI and a plain `git tag <name>` create) carries no date of its
# own, so git falls back to the COMMIT's date: a tag cut today on an older
# commit sorts as older than yesterday's annotated tag and is skipped forever.
# A set difference against a seen-list is correct for both tag kinds.
new=$(comm -13 "$SEEN" <(printf '%s\n' "$current") || true)
[ -n "$new" ] || exit 0

for tag in $new; do
    if ! [[ "$tag" =~ $TAG_RE ]]; then
        log "tag '$tag' does not match $TAG_RE; ignoring"
        printf '%s\n' "$current" > "$SEEN"
        continue
    fi

    # WHICH BRANCHES MAY DEPLOY HERE. Without this, tags from every branch land
    # in the SAME environment and the last one wins -- a tag cut from a feature
    # branch once replaced a 23-service compose file with that branch's
    # 5-service one and took the stack down. `*` means any branch.
    allowed=$(cat "$BRANCH_FILE" 2>/dev/null) || allowed=""
    if [ -z "$allowed" ]; then
        # A LOOKUP ERROR MUST NOT MARK THE TAG SEEN, or a legitimate release is
        # burned permanently. Leave it unseen; the next run retries.
        log "ERROR: no branch allowlist at $BRANCH_FILE; refusing and NOT marking seen"
        exit 1
    fi

    branches=$(git branch -r --contains "$tag" 2>/dev/null |
               sed 's|^[* ]*origin/||' | grep -v '^HEAD' || true)
    if [ -z "$branches" ]; then
        # Kept even with `*`: a tag whose branch was never pushed is not "any
        # branch", it is a detached commit no branch contains. Push the branch
        # BEFORE the tag.
        log "tag '$tag' is on no remote branch (push the branch first); refusing"
        printf '%s\n' "$current" > "$SEEN"
        continue
    fi
    if [ "$allowed" != "*" ] && ! printf '%s\n' "$branches" | grep -qx "$allowed"; then
        # A GENUINE wrong-branch refusal is marked seen and exits 0 -- otherwise
        # the timer retries it every minute forever.
        log "tag '$tag' is not on origin/$allowed; refusing"
        printf '%s\n' "$current" > "$SEEN"
        continue
    fi

    log "deploying $tag"
    # WRITE THE STATE FILE BEFORE THE RISKY STEPS. Recording only on success
    # means a failing build retries every minute with the stack down; recording
    # the attempt first means a failure stops and waits for a human.
    printf '%s\n' "$current" > "$SEEN"

    rm -rf "$STAGING/checkout"; mkdir -p "$STAGING/checkout"
    git archive "$tag" | tar -x -C "$STAGING/checkout"

    # --exclude=.env   gitignored, so the checkout has none, and --delete would
    #                  destroy the one the compose file depends on.
    # --exclude=.git   a leftover clone in the deploy dir is frozen at whatever
    #                  it last checked out; it has made a later session diff
    #                  live files against a months-old main and reach a
    #                  confidently wrong diagnosis.
    # --chown          rsync -a would preserve the deploy user's ownership and
    #                  erode the team's write access to the deploy directory.
    # Add --exclude for any large host-only data dir. NOTE: anything the compose
    # file bind-mounts must be IN THE TAG, or --delete removes it and the
    # container cannot start (track a .gitkeep for gitignored mount dirs).
    # THESE FLAGS MUST MATCH THE SUDOERS RULE CHARACTER FOR CHARACTER.
    sudo rsync -a --delete --chown="$OWNER" \
        --exclude=.env --exclude=.git \
        "$STAGING/checkout/" "$DEPLOY_DIR/"

    # A RELEASE REBUILDS AND RESTARTS EVERYTHING, unconditionally.
    #   --pull            refresh base images, so a release is not pinned to
    #                     whatever was cached months ago.
    #   --force-recreate  without it, `up -d` is a no-op for a service whose
    #                     image digest and config are identical -- so a release
    #                     can leave containers from the PREVIOUS tag running.
    #   --remove-orphans  drop services the new tag deleted.
    # Do NOT name services explicitly here: `up -d <name>` starts even a
    # profile-gated one, and bootstrap/loader one-shots are usually destructive.
    compose build --pull
    compose up -d --force-recreate --remove-orphans
    log "deployed $tag"
done
