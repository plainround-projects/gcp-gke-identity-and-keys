# Cloud Logging and audit logs

## 1. What it is

Cloud Logging stores logs from Google Cloud. **Cloud Audit Logs** are a special family of those logs that record *who did what to which resource*. **Admin Activity** logs record changes to configuration and are always on. **Data Access** logs record reads and writes of data (for example an object read in Cloud Storage); for most services, including Cloud Storage, they are **off by default** and must be turned on. An audit entry keeps the caller, the method, the resource, the permission checked and whether it was granted.

## 2. Why this repository uses it

Step 3 asks the learner to find the permission-denied entry for the default service account in the logs. That entry exists only if Cloud Storage data access logging is on. The repository switches it on with Terraform and then reads the entries with `gcloud logging read`.

## 3. Where it appears

| Path | What it does |
| --- | --- |
| `infra/modules/audit-logs/main.tf` | Turns on `ADMIN_READ`, `DATA_READ` and `DATA_WRITE` for `storage.googleapis.com`. |
| `scripts/break-wrong-sa.sh` | Reads denial entries (status code 7) for the bucket into a JSON file. |
| `scripts/prove.sh` | Prints the principal the pod used. |
| `src/gke_triage/infrastructure/audit_log.py`, `domain/audit.py` | Parse such an export and keep only the denied calls. |
| `tests/fixtures/audit-log.json` | A sample export. |

## 4. How it works underneath

An audit entry is a JSON document. The parts used here:

- `protoPayload.authenticationInfo.principalSubject`: who called, as a `principal://` string (for a Kubernetes identity). For ordinary accounts it is `principalEmail` instead.
- `protoPayload.methodName`: what was attempted, for example `storage.objects.create`.
- `protoPayload.resourceName`: the object or bucket.
- `protoPayload.authorizationInfo[]`: the permission checked and `granted: true/false`.
- `protoPayload.status.code`: `7` means `PERMISSION_DENIED` (the number comes from Google's standard error codes).

`gcloud logging read 'FILTER' --format=json` returns such entries as a JSON array. A **filter** like `protoPayload.serviceName="storage.googleapis.com" AND protoPayload.status.code=7` selects them.

## 5. Walkthrough of this repository's use

`infra/modules/audit-logs/main.tf`

```hcl
resource "google_project_iam_audit_config" "storage" {
  project = var.project_id
  service = "storage.googleapis.com"

  dynamic "audit_log_config" {
    for_each = toset(var.log_types)
    content {
      log_type = audit_log_config.value
    }
```

`google_project_iam_audit_config` sets the audit configuration of one service in the project. It is authoritative for that service: it replaces any existing configuration for it. `dynamic "audit_log_config"` writes one block per log type.

Reading denials:

`scripts/break-wrong-sa.sh`

```bash
gcloud logging read "protoPayload.serviceName=\"storage.googleapis.com\" AND protoPayload.status.code=7 AND protoPayload.resourceName:\"$BUCKET\"" \
  --limit=20 --freshness=1h --format=json >"$CAPTURES/wrong-service-account-audit.json"
"$ROOT/.venv/bin/gke-triage" audit "$CAPTURES/wrong-service-account-audit.json" || true
"$ROOT/.venv/bin/gke-triage" classify "$CAPTURES/wrong-service-account.txt"
```

`--freshness=1h` limits the search to the last hour; `--format=json` writes the entries to a file; `gke-triage audit FILE` summarizes them.

The parser:

`src/gke_triage/infrastructure/audit_log.py`

```python
def _denials_in(entry: Any) -> list[AuditDenial]:
    payload = entry.get("protoPayload") if isinstance(entry, dict) else None
    if not isinstance(payload, dict):
        return []
    authentication = payload.get("authenticationInfo") or {}
    principal = authentication.get("principalSubject") or authentication.get("principalEmail") or "unknown"
    status = payload.get("status") or {}
    status_code = status.get("code")
    results = []
    for authorization in payload.get("authorizationInfo") or []:
        if is_denial(status_code, authorization.get("granted")):
            results.append(
                AuditDenial(
                    principal=str(principal),
                    permission=str(authorization.get("permission", "")),
                    resource=str(authorization.get("resource") or payload.get("resourceName", "")),
                    method=str(payload.get("methodName", "")),
                    timestamp=str(entry.get("timestamp", "")),
                )
            )
    if not results and is_denial(status_code, None):
        results.append(
            AuditDenial(
                str(principal),
                "",
                str(payload.get("resourceName", "")),
                str(payload.get("methodName", "")),
                str(entry.get("timestamp", "")),
            )
        )
    return results
```

- It reads `protoPayload` safely: `entry.get("protoPayload") if isinstance(entry, dict) else None`, so odd entries are skipped instead of crashing.
- `authentication.get("principalSubject") or authentication.get("principalEmail") or "unknown"` takes the first non-empty identity.
- `is_denial(status_code, granted)` (in the domain) says a call was denied when `granted` is false or the status code is 7.
- Each denied permission becomes one `AuditDenial`.

## 6. Try it yourself

```bash
.venv/bin/gke-triage audit tests/fixtures/audit-log.json; echo "exit=$?"
```
Expected:
```text
2x  principal://iam.googleapis.com/projects/123456789012/locations/global/workloadIdentityPools/example-sandbox-0000.svc.id.goog/subject/ns/demo/sa/default  storage.objects.create  projects/_/buckets/example-sandbox-0000-files/objects/a.txt
1x  operator@example.org    projects/_/buckets/example-sandbox-0000-files/objects/a.txt
exit=1
```
(`2x` means the same denial appears twice. The second line has an empty permission column because that fixture entry has no permission list. The allowed call in the fixture is not listed. Exit status 1 means denials were found.)

```bash
.venv/bin/python -m pytest tests/unit/infrastructure/test_adapters.py -q -p no:cacheprovider
```
Expected: all pass (`7 passed`).

With a project (not run here): `gcloud logging read 'protoPayload.serviceName="storage.googleapis.com" AND protoPayload.status.code=7' --limit=5 --freshness=1h --format=json | .venv/bin/gke-triage audit -`.

## 7. Mistakes people make

- **Looking for Data Access logs that were never turned on.** For Cloud Storage they are off by default.
- **Reading `principalEmail` for a Kubernetes identity.** Those entries use `principalSubject`.
- **Searching without a time limit.** Add `--freshness`.
- **Expecting entries instantly.** There is a delay of a minute or so.
- **Switching on all data access logs for all services in a busy project.** They can be large and cost money.

## 8. Check yourself

1. Which audit logs are on by default? *Admin Activity.*
2. What does status code 7 mean? *PERMISSION_DENIED.*
3. Where is the caller named for a pod? *`authenticationInfo.principalSubject`.*
4. What does `--format=json` give `gke-triage audit`? *An array of log entries to parse.*
5. Why does the module use an audit config resource? *Data access logging for Cloud Storage is off until configured.*

## 9. Further reading

- Cloud Audit Logs: <https://cloud.google.com/logging/docs/audit>
- Configure data access audit logs: <https://cloud.google.com/logging/docs/audit/configure-data-access>
- Logging query language: <https://cloud.google.com/logging/docs/view/logging-query-language>
