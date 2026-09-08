# Testing the pre-commit hook

## Why this needs its own page

The hook test failed on the first host by **passing**. A fabricated AWS key
was staged, gitleaks reported no leaks, the commit went through, and the hook
looked broken. It was not — the test credential was undetectable.

An installed-but-non-firing hook is worse than no hook, because it will be
trusted.

## Use a GitHub PAT, not an AWS key

gitleaks 8.x does not flag a bare `AKIA…` string. Not the AWS-published
example one, and not a randomly generated one either — its AWS rule needs
surrounding context.

Test with a fabricated `ghp_` token instead. That trips the `github-pat` rule
reliably.

Also avoid any vendor's *published example* credential — several are in
gitleaks' own allowlist, which is a second way to get a vacuous pass.

## The AKIA coverage gap

If the org policy names access keys explicitly, the default ruleset is not
sufficient. Add to `.gitleaks.toml`:

```
(AKIA|ASIA|AIDA|AROA|AGPA|ANPA|ANVA|APKA)[0-9A-Z]{16}
```

The full prefix set, not just `AKIA` — a temporary `ASIA` key leaks
identically. Allowlist the AWS-published example so a doc example does not
wedge someone's commit later.

If replacing a hand-rolled regex scan with gitleaks, ship this rule in the
**same commit**. Otherwise history contains a window where the swap is a net
downgrade.

## Test procedure

1. Stage a fabricated `ghp_` token in a scratch file
2. Attempt a commit — it must be refused
3. Confirm `HEAD` is unchanged
4. Hide gitleaks from `PATH`, retry — it must refuse rather than pass
   (fail-closed)
5. Stage clean content — it must pass
6. Unstage and delete the scratch file
7. Confirm `git status` shows only intended paths

## If a test commit slips through

Use `git reset --soft HEAD~1`. Never `--hard` — there are usually uncommitted
edits in the tree that `--hard` destroys silently.

## Ship the hook in the repo

Put it at `hooks/pre-commit` in the repo, not only `.git/hooks/`, and have
`install.sh` install it on every host it onboards. Otherwise the check is
per-machine and the next node has no protection.

Back up any existing hook before replacing it. Keep it idempotent.

## Scan the source, not just the output

Scanning a *generated* file catches a token in the output. It does nothing
about a token in the input that the model already read and could paraphrase.

Scan transcripts before the model sees them. Use `--exit-code` to distinguish
"found a secret" from "scanner broke", and fail the run on either.

## The gitignore pattern trap

`.env.*` matches files *starting* with `.env.` — it does not match
`.claude-config.env` or `something.env`. Two live API keys sat one
`git add -A` away from being committed because of exactly this.

Use `*.env` plus an explicit `!.env.example`, and verify with
`git check-ignore` rather than assuming the pattern works.

A file living outside the repo tree is the real protection; the gitignore
entry is defence for the day someone copies it inside.
