# shellcheck shell=bash
#
# pull.sh — shared "pull main before doing anything" step.
#
# Sourced by scripts/fleet-sync.sh and scripts/nightly-review.sh. Both run
# unattended on a schedule, so without this they would operate on a clone that
# drifts further behind origin/main every day, and a host would keep proposing
# changes against a stale baseline.
#
# Requires the caller to define: log(), die(), and REPO_DIR.
#
# Contract, deliberately narrow:
#   * FAST-FORWARD ONLY. Never merge, never rebase, never force, never reset.
#     A scheduled job must not invent a merge commit or rewrite history in a
#     repo a human is also using.
#   * DIRTY TREE -> SKIP the pull, log loudly, and CONTINUE. The caller's own
#     work (collecting drift, reviewing transcripts) is the point of the run and
#     must not be lost to a housekeeping step. Local changes are never stashed
#     or discarded to make a pull possible.
#   * FAST-FORWARD IMPOSSIBLE -> ABORT the run. Divergence means local commits
#     on main, which is exactly what these scripts are built to prevent, so it
#     needs a human rather than an automatic resolution.
#
# Why it checks out main rather than only updating the ref: ~/.claude/CLAUDE.md,
# skills/ and commands/ are symlinks into this clone's WORKING TREE. Updating
# the main ref alone leaves the working tree untouched, so the live config would
# not change. Fast-forwarding main while it is checked out is what makes an
# incoming change take effect with no reinstall.

# pull_main — fetch origin and fast-forward main. Echoes nothing; logs via log().
# Returns 0 if the caller should continue, non-zero only via die().
pull_main() {
    local branch before after ff_ok=0 dirty=0

    log "--- pull: syncing main from origin ---"

    git -C "$REPO_DIR" remote get-url origin >/dev/null 2>&1 \
        || die "pull: no 'origin' remote configured"

    git -C "$REPO_DIR" fetch -q origin || die "pull: git fetch origin failed"

    git -C "$REPO_DIR" show-ref --verify --quiet refs/remotes/origin/main \
        || die "pull: origin/main does not exist"

    [ -n "$(git -C "$REPO_DIR" status --porcelain)" ] && dirty=1
    branch="$(git -C "$REPO_DIR" rev-parse --abbrev-ref HEAD)"

    if [ "$dirty" = 1 ]; then
        log "pull: ****************************************************************"
        log "pull: WORKING TREE IS DIRTY -- SKIPPING THE PULL"
        log "pull: This clone is NOT being updated from origin/main on this run."
        log "pull: Local changes are never stashed or discarded to force a pull,"
        log "pull: so the run continues against a possibly stale baseline."
        log "pull: Uncommitted paths:"
        git -C "$REPO_DIR" status --porcelain | sed 's/^/pull:     /'
        log "pull: Commit or clear them, then re-run to pick up origin/main."
        log "pull: ****************************************************************"
        return 0
    fi

    before="$(git -C "$REPO_DIR" rev-parse refs/heads/main 2>/dev/null || echo '')"
    after="$(git -C "$REPO_DIR" rev-parse refs/remotes/origin/main)"

    if [ -z "$before" ]; then
        log "pull: no local main branch; creating it at origin/main"
        git -C "$REPO_DIR" branch -q main origin/main || die "pull: cannot create main"
        before="$after"
    fi

    if [ "$before" = "$after" ]; then
        log "pull: already up to date at ${after:0:12}"
        # Still ensure the working tree is on main, so the symlinked live config
        # reflects main rather than a leftover branch from a previous run.
        if [ "$branch" != "main" ]; then
            log "pull: checking out main (was on '$branch') so the live symlinks track it"
            git -C "$REPO_DIR" checkout -q main || die "pull: cannot check out main"
        fi
        return 0
    fi

    # Fast-forward possible only if local main is an ancestor of origin/main.
    if git -C "$REPO_DIR" merge-base --is-ancestor "$before" "$after"; then
        ff_ok=1
    fi

    if [ "$ff_ok" != 1 ]; then
        log "pull: main and origin/main have DIVERGED -- fast-forward impossible"
        log "pull:   local  main        = $before"
        log "pull:   origin/main        = $after"
        log "pull:   merge base         = $(git -C "$REPO_DIR" merge-base "$before" "$after" 2>/dev/null || echo '<none>')"
        log "pull: local commits on main:"
        git -C "$REPO_DIR" log --oneline "$after..$before" 2>/dev/null | sed 's/^/pull:     /'
        log "pull: Refusing to merge, rebase or reset. A human must resolve this."
        die "pull: cannot fast-forward main -- aborting the run"
    fi

    if [ "$branch" != "main" ]; then
        log "pull: checking out main (was on '$branch')"
        git -C "$REPO_DIR" checkout -q main || die "pull: cannot check out main"
    fi

    git -C "$REPO_DIR" merge --ff-only -q "$after" \
        || die "pull: fast-forward merge failed unexpectedly"

    log "pull: fast-forwarded main ${before:0:12}..${after:0:12}"
    log "pull: incoming commits:"
    git -C "$REPO_DIR" log --oneline "$before..$after" | sed 's/^/pull:     /'

    # Which of the paths that actually affect a host changed. These are the ones
    # symlinked into ~/.claude or read by a session, so a change here changes
    # behaviour on this machine.
    local changed watched hit=0
    changed="$(git -C "$REPO_DIR" diff --name-only "$before" "$after")"
    log "pull: config paths affected:"
    for watched in CLAUDE.md BaraAlSedih.md skills/ commands/ runbooks/ decisions/ hosts/ oncall.md scripts/; do
        if printf '%s\n' "$changed" | grep -q "^${watched%/}"; then
            log "pull:     CHANGED  $watched"
            hit=1
        fi
    done
    [ "$hit" = 0 ] && log "pull:     (none of the watched config paths)"

    log "pull: full file list:"
    printf '%s\n' "$changed" | sed 's/^/pull:     /'

    log "--- pull: done ---"
    return 0
}
