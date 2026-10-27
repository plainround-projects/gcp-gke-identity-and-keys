# project-services

Enables the APIs the lab needs and leaves them enabled on destroy.

Used for: Step 1 (cluster, key and bucket need their APIs).

## Inputs

| Name | Description | Type | Default |
| --- | --- | --- | --- |
| `project_id` | Id of the existing project. | `string` | required |
| `services` | APIs to enable. | `list(string)` | required |

## Outputs

| Name | Description |
| --- | --- |
| `enabled_services` | APIs enabled by this module. |

## Example

See `infra/environments/lab/main.tf`, which composes this module.

## Tests

yes (`tests/*.tftest.hcl`, mock provider). Run `make test-terraform` from the repository root.
