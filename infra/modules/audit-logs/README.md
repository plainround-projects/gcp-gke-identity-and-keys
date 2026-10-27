# audit-logs

Turns on the data-access audit logs of Cloud Storage so that denied calls appear in Cloud Logging.

Used for: Step 3 (finding the denial for the default service account).

## Inputs

| Name | Description | Type | Default |
| --- | --- | --- | --- |
| `project_id` | Project whose Cloud Storage data access is logged. | `string` | required |
| `log_types` | Audit log types to enable. | `list(string)` | `["ADMIN_READ", "DATA_READ", "DATA_WRITE"]` |

## Outputs

| Name | Description |
| --- | --- |
| `log_types` | Enabled audit log types. |

## Example

See `infra/environments/sandbox/main.tf`, which composes this module.

## Tests

yes (`tests/*.tftest.hcl`, mock provider). Run `make test-terraform` from the repository root.
