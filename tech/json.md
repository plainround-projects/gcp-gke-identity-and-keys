# JSON

## 1. What it is

JSON (JavaScript Object Notation) is a text format for data made of objects (`{"key": value}`), lists (`[1, 2]`), strings, numbers, `true`, `false` and `null`. Almost every web service speaks it. Keys must be in double quotes; there are no comments.

## 2. Why this repository uses it

The audit-log export that `gcloud logging read --format=json` writes is JSON, and the tool reads it to list the denied calls. JSON is also the format of the schema checks behind `kubernetes-validate`.

## 3. Where it appears

| Path | What is JSON |
| --- | --- |
| `tests/fixtures/audit-log.json` | A sample audit-log export (an array of log entries). |
| `src/gke_triage/infrastructure/audit_log.py` | `JsonAuditLogSource` parses an export. |
| `scripts/break-wrong-sa.sh` | Writes the export with `gcloud logging read ... --format=json`. |

## 4. How it works underneath

Programs convert between text and in-memory data: `json.dumps(obj)` makes text, `json.loads(text)` makes data. In Python an object becomes a `dict`, a list a `list`, `null` becomes `None`. Bytes are not a JSON type, which is why Pub/Sub's `data` field is **base64** text: the message bytes are encoded as letters and digits to travel inside JSON.

## 5. Walkthrough of this repository's use

`src/gke_triage/infrastructure/audit_log.py`

```python
class JsonAuditLogSource:
    """Parses an export (a JSON array of log entries) into the denials it contains."""

    def __init__(self, text: str) -> None:
        """`text` is the whole export."""
        self._text = text

    def denials(self) -> Sequence[AuditDenial]:
        """The denied calls; entries that are not audit entries or were allowed are skipped."""
        try:
            entries = json.loads(self._text)
        except ValueError as error:
            raise UnreadableAuditLog("input is not JSON") from error
        if not isinstance(entries, list):
            raise UnreadableAuditLog("expected a JSON array, as `--format=json` prints")
        found: list[AuditDenial] = []
        for entry in entries:
            found.extend(_denials_in(entry))
        return found
```

- `json.loads(self._text)` turns text into Python data. Bad text raises `ValueError`, which becomes the named error `UnreadableAuditLog("input is not JSON")`.
- `isinstance(entries, list)` checks the shape: `gcloud ... --format=json` prints an array.
- Each entry is a dictionary; `_denials_in` picks out the fields it needs and tolerates missing ones.

A trimmed entry from the fixture:

`tests/fixtures/audit-log.json`

```json
    "timestamp": "2026-10-26T10:00:01Z",
    "protoPayload": {
      "serviceName": "storage.googleapis.com",
      "methodName": "storage.objects.create",
      "resourceName": "projects/_/buckets/example-sandbox-0000-files/objects/a.txt",
      "authenticationInfo": {
        "principalSubject": "principal://iam.googleapis.com/projects/123456789012/locations/global/workloadIdentityPools/example-sandbox-0000.svc.id.goog/subject/ns/demo/sa/default"
      },
      "authorizationInfo": [
        {"permission": "storage.objects.create", "granted": false, "resource": "projects/_/buckets/example-sandbox-0000-files/objects/a.txt"}
      ],
      "status": {"code": 7, "message": "PERMISSION_DENIED"}
```

`authorizationInfo` holds the permission and `granted`; `status.code` 7 means `PERMISSION_DENIED`.

## The whole sample export, entry by entry

**JSON** is a text format for data, made of **objects** (`{ "name": value, ... }`: named values, like a form), **arrays** (`[ a, b ]`: ordered lists), texts in double quotes, numbers, `true`/`false` and `null`. Names must be in double quotes, items are separated by commas, and a comma after the last item is an error. `gcloud logging read ... --format=json` prints an array of log-entry objects.

`tests/fixtures/audit-log.json`

```json
[
  {
    "timestamp": "2026-10-26T10:00:01Z",
    "protoPayload": {
      "serviceName": "storage.googleapis.com",
      "methodName": "storage.objects.create",
      "resourceName": "projects/_/buckets/example-sandbox-0000-files/objects/a.txt",
      "authenticationInfo": {
        "principalSubject": "principal://iam.googleapis.com/projects/123456789012/locations/global/workloadIdentityPools/example-sandbox-0000.svc.id.goog/subject/ns/demo/sa/default"
      },
      "authorizationInfo": [
        {"permission": "storage.objects.create", "granted": false, "resource": "projects/_/buckets/example-sandbox-0000-files/objects/a.txt"}
      ],
      "status": {"code": 7, "message": "PERMISSION_DENIED"}
    }
  },
  {
    "timestamp": "2026-10-26T10:00:09Z",
    "protoPayload": {
      "serviceName": "storage.googleapis.com",
      "methodName": "storage.objects.create",
      "resourceName": "projects/_/buckets/example-sandbox-0000-files/objects/a.txt",
      "authenticationInfo": {
        "principalSubject": "principal://iam.googleapis.com/projects/123456789012/locations/global/workloadIdentityPools/example-sandbox-0000.svc.id.goog/subject/ns/demo/sa/default"
      },
      "authorizationInfo": [
        {"permission": "storage.objects.create", "granted": false, "resource": "projects/_/buckets/example-sandbox-0000-files/objects/a.txt"}
      ],
      "status": {"code": 7, "message": "PERMISSION_DENIED"}
    }
  },
  {
    "timestamp": "2026-10-26T10:01:00Z",
    "protoPayload": {
      "serviceName": "storage.googleapis.com",
      "methodName": "storage.objects.get",
      "resourceName": "projects/_/buckets/example-sandbox-0000-files/objects/a.txt",
      "authenticationInfo": {
        "principalSubject": "principal://iam.googleapis.com/projects/123456789012/locations/global/workloadIdentityPools/example-sandbox-0000.svc.id.goog/subject/ns/demo/sa/reader-writer"
      },
      "authorizationInfo": [
        {"permission": "storage.objects.get", "granted": true, "resource": "projects/_/buckets/example-sandbox-0000-files/objects/a.txt"}
      ],
      "status": {}
    }
  },
  {
    "timestamp": "2026-10-26T10:02:00Z",
    "protoPayload": {
      "serviceName": "storage.googleapis.com",
      "methodName": "storage.objects.get",
      "resourceName": "projects/_/buckets/example-sandbox-0000-files/objects/a.txt",
      "authenticationInfo": {"principalEmail": "operator@example.org"},
      "status": {"code": 7, "message": "PERMISSION_DENIED"}
    }
  },
  {"timestamp": "2026-10-26T10:03:00Z", "textPayload": "not an audit entry"}
]
```

The file is the array `[ ... ]` of five entries.

1. **10:00:01Z**: a `storage.objects.create` call by the pod's principal on the `default` Kubernetes service account. `authorizationInfo` has one check, `granted: false`, and `status.code` is 7: denied.
2. **10:00:09Z**: the same denial a few seconds later. The tool counts these together (`2x`).
3. **10:01:00Z**: a `storage.objects.get` by the right account, `granted: true`, `status` is an empty object `{}`: allowed. It must be left out of the result.
4. **10:02:00Z**: a call by a person (`principalEmail`, no `principalSubject`) with `status.code` 7 but no `authorizationInfo` at all. The tool records a denial with an empty permission.
5. **10:03:00Z**: `{"timestamp": ..., "textPayload": "not an audit entry"}`, a log line with no `protoPayload`. It must be skipped.

Field by field: `timestamp` is when it happened (UTC, ISO 8601); `protoPayload` is the audit record; `serviceName` and `methodName` say which API call it was; `resourceName` is the object (`projects/_/buckets/BUCKET/objects/NAME`, where `_` stands for "any project"); `authenticationInfo` says who; `authorizationInfo` lists each permission checked with `granted`; `status.code` is the result as a number (0 means success, 7 is `PERMISSION_DENIED`).

## 6. Try it yourself

```bash
.venv/bin/python -c "
import json
entries = json.load(open('tests/fixtures/audit-log.json'))
print(len(entries), entries[0]['protoPayload']['status']['code'])"
```
Expected: `5 7`

```bash
echo '{"a": 1,}' | .venv/bin/python -c "import json,sys; json.load(sys.stdin)" 2>&1 | tail -1
```
Expected: a `JSONDecodeError` complaining about the trailing comma (on Python 3.13: `Illegal trailing comma before end of object: line 1 column 8 (char 7)`; older versions word it differently). A trailing comma is not valid JSON.

```bash
.venv/bin/gke-triage audit tests/fixtures/audit-log.json | head -1 | cut -c1-40
```
Expected: `2x  principal://iam.googleapis.com/proj`

## 7. Mistakes people make

- **Trailing commas or single quotes.** Not valid JSON.
- **Assuming the right shape.** A valid document can be an object when you expected an array; the reader checks.
- **Reading `principalEmail` only.** Kubernetes identities use `principalSubject`.
- **Putting secrets in exports.** The sample is made-up data.

## 8. Check yourself

1. Can JSON contain comments? *No.*
2. What does `gcloud logging read --format=json` print? *An array of log-entry objects.*
3. What does `json.loads` raise for bad text? *`ValueError`.*
4. Why check `isinstance(entries, list)`? *Valid JSON may have another shape.*
5. What does status code 7 mean in an audit entry? *PERMISSION_DENIED.*

## 9. Further reading

- JSON: <https://www.json.org/>
- Python `json`: <https://docs.python.org/3.12/library/json.html>
- LogEntry format: <https://cloud.google.com/logging/docs/reference/v2/rest/v2/LogEntry>

