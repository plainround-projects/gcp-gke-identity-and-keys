# gke-autopilot

An Autopilot cluster with private nodes, a public API endpoint restricted to the ranges you list, and Workload Identity Federation for GKE (always on in Autopilot).

Used for: Step 1 (the cluster).

## Inputs

| Name | Description | Type | Default |
| --- | --- | --- | --- |
| `project_id` | Project that owns the cluster. | `string` | required |
| `name` | Cluster name. | `string` | required |
| `region` | Region of the cluster. | `string` | required |
| `network` | Self link of the VPC network. | `string` | required |
| `subnetwork` | Self link of the subnet. | `string` | required |
| `pods_range_name` | Secondary range name for pods. | `string` | required |
| `services_range_name` | Secondary range name for services. | `string` | required |
| `master_cidr` | A /28 for the control plane's private side, not used by anything else. | `string` | `"172.16.0.0/28"` |
| `master_authorized_cidrs` | Ranges allowed to reach the API endpoint, name => CIDR. Your own address as /32 is enough. | `map(string)` | required |
| `release_channel` | RAPID, REGULAR or STABLE. | `string` | `"REGULAR"` |
| `deletion_protection` | Refuse to delete the cluster. False in a sandbox so the teardown works. | `bool` | `false` |
| `labels` | Labels for the cluster. | `map(string)` | `{}` |

## Outputs

| Name | Description |
| --- | --- |
| `name` | Cluster name. |
| `location` | Cluster region. |
| `workload_pool` | The workload identity pool of the project: PROJECT_ID.svc.id.goog. |

## Example

See `infra/environments/lab/main.tf`, which composes this module.

## Tests

yes (`tests/*.tftest.hcl`, mock provider). Run `make test-terraform` from the repository root.
