# 2. Authorize the Cloud Storage service agent on the key before the bucket exists

Status: accepted, 2026-10-27

## Context

A bucket with a customer-managed default key cannot be created unless Cloud Storage's own service agent may already use that key. The pod never touches the key: Cloud Storage calls Cloud KMS with its agent.

## Decision

`module.key` grants `cryptoKeyEncrypterDecrypter` on the key to the service agent (looked up with `google_storage_project_service_account`, which also creates the agent), and `module.bucket` declares `depends_on = [module.key]`. The pod's principal gets a role on the bucket only. A test fails if the dependency or the single use of the pod principal changes.

## Consequences

- The three failure layers stay separate: the pod's IAM role (authorization), the agent's role and the key's state (key).
- The first apply needs credentials (the data source), so the offline plan supplies the agent's email as a variable.
- Disabling the key version in step 5 makes reads fail without touching IAM, which is the point of the step.
