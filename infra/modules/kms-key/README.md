# kms-key

A key ring and an encryption key with 90-day rotation and a 24-hour destruction window, and `cryptoKeyEncrypterDecrypter` on that key for the listed members (the Cloud Storage service agent).

Used for: Steps 1 and 5 (the customer-managed key and its kill switch).

## Inputs

| Name | Description | Type | Default |
| --- | --- | --- | --- |
| `project_id` | Project that owns the key ring. | `string` | required |
| `location` | Location of the key ring; a regional bucket needs a key in the same region. | `string` | required |
| `key_ring_name` | Key ring name. Key rings cannot be deleted once created. | `string` | required |
| `key_name` | Key name. | `string` | required |
| `rotation_period` | How often a new key version becomes primary, in seconds with an s suffix (90 days by default). | `string` | `"7776000s"` |
| `destroy_scheduled_duration` | How long a version waits between a destroy request and the irreversible destruction (at least 24 hours). | `string` | `"86400s"` |
| `encrypter_decrypter_members` | Members that may use the key to encrypt and decrypt (the Cloud Storage service agent), keyed by a fixed label. | `map(string)` | `{}` |
| `labels` | Labels for the key. | `map(string)` | `{}` |

## Outputs

| Name | Description |
| --- | --- |
| `id` | Key resource name, projects/P/locations/L/keyRings/R/cryptoKeys/K. |
| `key_name` | Key name. |
| `key_ring_name` | Key ring name. |
| `encrypter_decrypter_members` | Members that may use the key. |

## Example

See `infra/environments/sandbox/main.tf`, which composes this module.

## Tests

yes (`tests/*.tftest.hcl`, mock provider). Run `make test-terraform` from the repository root.
