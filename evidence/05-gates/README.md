# C5 — gates that actually block

Three deliberately-insecure PRs, one per gate, each confirmed genuinely
red — never merged, left open as the proof.

| Gate | Deliberate insecure change | PR | Result |
|---|---|---|---|
| `trivy config` | Dockerfile's non-root `USER node` directive removed | [#5](https://github.com/RigbeWeleslasie/db-capacity-engineering-lab/pull/5) | `trivy config` fails (`AVD-DS-0002`, container runs as root) |
| `gitleaks` | A randomly-generated, never-valid AWS access key + secret key pair committed to `red-pr-demo/leaked-credential-demo.txt` | [#16](https://github.com/RigbeWeleslasie/db-capacity-engineering-lab/pull/16) | `gitleaks` fails (`generic-api-key`, entropy 4.68) — see `gitleaks.json` (the healthy, zero-finding scan of `main`'s real history) for contrast |
| `zizmor` | `ci.yml`'s reusable-workflow `uses:` line unpinned from a commit SHA to the moving branch `@main` | [#17](https://github.com/RigbeWeleslasie/db-capacity-engineering-lab/pull/17) | `zizmor` fails (`unpinned-uses`, High confidence) — see `zizmor.txt` for both the clean scan of the fixed, pinned `ci.yml` and the actual finding against the unpinned version |

Note on the gitleaks red-PR: the first attempt used AWS's own official
documentation example key/secret (`AKIAIOSFODNN7EXAMPLE` /
`wJalrXUtnFEMI/K7MDENG/bPxRfiCYEXAMPLEKEY`) — verified locally that
gitleaks does **not** flag it, because that exact value is excluded from
gitleaks' own default rules (it's used so widely as a documented
placeholder that treating it as a real leak signal would be pure noise).
Switched to a randomly-generated pair with the same shape instead, which
gitleaks does flag — a small, real lesson about not assuming a scanner's
default ruleset catches literally anything matching a pattern.

## What each gate does NOT catch (one sentence each)

- **`gitleaks`** doesn't catch a secret that's *correctly* resolved at
  runtime but logged or returned in an API response by application code —
  it only scans source/history, never live process output (which is
  exactly why `api/secrets.js` disciplines itself to log only ARN +
  VersionId, never the value, as a separate control).
- **`trivy config`** evaluates the Terraform *as written*, not as
  actually applied — a misconfiguration introduced only via a `-var`
  override at apply time (not committed anywhere) never appears in a
  static scan of the repo.
- **`trivy image`** vulnerability data is only as fresh as trivy's own
  CVE database at scan time — a vulnerability disclosed the day after a
  scan runs is invisible until the next scan, so a point-in-time "0
  HIGH/CRITICAL" result is a snapshot, not a permanent guarantee.
- **`zizmor`** analyzes workflow YAML statically — it can't see that a
  pinned-by-SHA action's *maintainer* has been compromised and pushed a
  malicious commit to that exact SHA before you pinned to it; pinning
  stops a tag being silently moved out from under you, not a
  already-compromised commit.

## Supply-chain layering beyond pinning

Per the brief's "guard the guards" framing — pinning alone doesn't stop a
compromised maintainer or a zero-day in a scanner's own logic, so:

- **Integrity:** every action/reusable-workflow reference in this repo's
  own `ci.yml` is pinned by full commit SHA (see the file's own pin-history
  comment) — the opposite of what PR #17 above deliberately breaks.
- **Blast radius:** the scan jobs in `golden-ci.yml` run with
  `permissions: contents: read` and no secrets exposed to the scanning
  steps themselves — a compromised scanner step has nothing to exfiltrate.
- **Detection:** not yet added — `step-security/harden-runner` (egress
  audit) is a real gap here, not implemented in this lab's timeframe. If
  added, it would surface a compromised step "phoning home" even though
  it can't prevent an unknown zero-day.
