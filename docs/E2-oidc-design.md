# E2 — OIDC design (writing-only deliverable, no infrastructure)

This lab authenticates to LocalStack with static test creds
(`AWS_ACCESS_KEY_ID=test`, account `000000000000`) — fine for an emulator,
never acceptable against real AWS. This document is the production
alternative: GitHub Actions' OIDC token exchange, so CI never holds a
long-lived AWS credential at all.

## The production `configure-aws-credentials` step

This would replace the static-creds block in `golden-ci.yml`'s
`tflocal-apply` job (or its real-AWS equivalent) when deploying to real
infrastructure instead of LocalStack:

```yaml
# --- production OIDC auth (NOT active on LocalStack — see below) -----------
# On real AWS, this step replaces AWS_ACCESS_KEY_ID=test/AWS_SECRET_ACCESS_KEY=test
# entirely. GitHub's own OIDC provider issues a short-lived token scoped to
# this exact repo+ref; AWS exchanges it for temporary credentials via the
# trust policy below. No AWS secret ever lives in GitHub — nothing to leak,
# nothing to rotate.
# - name: Configure AWS credentials (OIDC)
#   uses: aws-actions/configure-aws-credentials@<pinned-sha>
#   with:
#     role-to-assume: arn:aws:iam::<ACCOUNT_ID>:role/github-actions-deploy
#     aws-region: us-east-1
#     # No access-key-id / secret-access-key inputs at all — that's the point.
permissions:
  id-token: write   # required for the OIDC token exchange above
  contents: read
```

Why this isn't active in this repo today: LocalStack's freemium tier has
no real IAM/STS trust-policy evaluation to exchange an OIDC token against
— `AWS_ACCESS_KEY_ID=test` is LocalStack's own documented substitute, and
building against a real AWS account+role just to exercise OIDC would be
outside this lab's LocalStack-only scope. The design below is what
`golden-ci.yml` would need the day this platform actually deploys to real
AWS.

## The actual IAM trust policy

```json
{
  "Version": "2012-10-17",
  "Statement": [
    {
      "Effect": "Allow",
      "Principal": {
        "Federated": "arn:aws:iam::<ACCOUNT_ID>:oidc-provider/token.actions.githubusercontent.com"
      },
      "Action": "sts:AssumeRoleWithWebIdentity",
      "Condition": {
        "StringEquals": {
          "token.actions.githubusercontent.com:aud": "sts.amazonaws.com",
          "token.actions.githubusercontent.com:sub": "repo:nebyathhailu/regional-health-platform:ref:refs/heads/main"
        }
      }
    }
  ]
}
```

The `sub` claim is the whole control: it's the one condition standing
between "any GitHub Actions run anywhere" and "specifically this repo, on
specifically its `main` branch, assuming this role."

## What breaks if `sub` is `repo:<org>/*` instead

Widening the condition to `repo:nebyathhailu/*` (or worse, dropping the
org scope too) changes the trust boundary from *this one repo's protected
branch* to *every repository in the org, on every branch, in every PR from
every fork*. Concretely:

- **Any repo in the org can assume this deploy role.** A teammate's
  unrelated side-project repo, a fork someone created for a school
  assignment, a throwaway test repo — all of them would satisfy
  `repo:nebyathhailu/*` and could assume the same production-deploy role
  this platform uses, with zero relationship to this codebase.
- **Any branch, not just `main`, would qualify** if the `ref:` portion
  were also widened or dropped — a feature branch a contributor pushes
  (including one from a fork's pull_request context, which carries a
  *different* subject format entirely and needs its own explicit
  handling, not just a wildcard) could trigger a workflow that assumes
  the deploy role, entirely outside branch-protection review.
- **The blast radius of one compromised repo becomes every repo in the
  org.** If a single low-stakes repo in the org gets a malicious PR merged
  (a supply-chain compromise in one of *its* dependencies, say), the
  attacker's CI run in that unrelated repo can now assume this platform's
  production AWS role — the isolation the narrow `sub` was providing
  collapses into "whichever repo in the org has the weakest defenses is
  now everyone's weakest link."
- **It stops being least-privilege by design and becomes least-privilege
  by accident** — it might still be fine today because no other repo in
  the org happens to try assuming the role, but that's an absence of
  attackers, not a control. The narrow `sub` is what makes the trust
  policy itself the enforcement point, rather than hoping nobody else in
  the org ever pushes a workflow that references this role's ARN.

The fix, if broader access is genuinely needed, is never a wildcard — it's
an explicit list of `StringEquals` values (or `StringLike` with a
narrowly-scoped pattern, e.g. one additional named repo), so every
repo/branch that can assume the role is a deliberate, reviewable decision
rather than "everything that happens to match a glob."
