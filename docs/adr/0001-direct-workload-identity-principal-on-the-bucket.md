# 1. Bind the bucket role to the workload identity principal directly

Status: accepted, 2026-10-27

## Context

A pod can reach Cloud Storage in two keyless ways: bind a role to the federated principal of its Kubernetes service account, or bind `roles/iam.workloadIdentityUser` so the pod impersonates a Google service account that holds the role. The lesson offers both and its hints use the direct principal.

## Decision

Bind `roles/storage.objectUser` on the bucket to `principal://iam.googleapis.com/projects/NUMBER/locations/global/workloadIdentityPools/PROJECT_ID.svc.id.goog/subject/ns/demo/sa/reader-writer`. The string is built once in `infra/environments/lab/main.tf` (`local.pod_principal`) and by `WorkloadPrincipal.uri` in the tool; a Terraform test and a Python test assert the same literal.

## Consequences

- No Google service account, no impersonation binding, no annotation on the Kubernetes service account.
- The audit log shows the Kubernetes identity (`principalSubject`), which is what step 3 reads.
- The project number, not the id, is required in the principal; the variable, the value object and a CLI check all reject the id with the fix in the message.
- Services that do not accept federated principals need the impersonation route instead.
