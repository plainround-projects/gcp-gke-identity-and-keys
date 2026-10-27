# 3. A rule-based classifier over captured error text

Status: accepted, 2026-10-27

## Context

Step 6 asks for a triage table that tells identity, authorization and key failures apart from the error text. The wording comes from Cloud Storage and `gcloud` and changes between versions.

## Decision

`gke_triage.domain.triage.classify` is a pure function of the text with one rule per message family, ordered from most to least specific (key first, then the IAM "does not have PERMISSION access" form, then missing credentials, then unknown). Fixtures under `tests/fixtures/` hold the lesson's texts; the CLI classifies a file or standard input and renders the table from `captures/*.txt`.

## Consequences

- A new wording is a fixture, a failing test and a rule.
- The key rule is the least certain: the lesson elides the exact text, so the rule matches "Cloud KMS key ... disabled/destroyed" and any `cloudkms.*` permission denial, and the README tells the owner to capture the real text.
- Unrecognized text is reported as `unknown`, never guessed.
