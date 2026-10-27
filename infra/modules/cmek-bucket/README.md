# cmek-bucket

A private bucket whose default encryption key is yours, plus `objectUser` on that one bucket for the listed members (the pod's principal).

Used for: Steps 1 and 2 (the encrypted bucket and the pod's role).

## Inputs

| Name | Description | Type | Default |
| --- | --- | --- | --- |
| `project_id` | Project that owns the bucket. | `string` | required |
| `name` | Globally unique bucket name. | `string` | required |
| `location` | Bucket location; must match the key's location. | `string` | required |
| `kms_key_id` | Resource name of the customer-managed key used as the bucket's default. | `string` | required |
| `object_users` | Members that may read and write objects (roles/storage.objectUser on the bucket), keyed by a fixed label. | `map(string)` | `{}` |
| `force_destroy` | Delete the bucket even when it holds objects. True only for a sandbox. | `bool` | `false` |
| `labels` | Labels for the bucket. | `map(string)` | `{}` |

## Outputs

| Name | Description |
| --- | --- |
| `name` | Bucket name. |
| `object_users` | Members granted roles/storage.objectUser on the bucket. |

## Example

See `infra/environments/sandbox/main.tf`, which composes this module.

## Tests

yes (`tests/*.tftest.hcl`, mock provider). Run `make test-terraform` from the repository root.
