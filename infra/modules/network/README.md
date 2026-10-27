# network

A custom-mode VPC and one subnet with Private Google Access, flow logs, and secondary ranges for pods and services.

Used for: Step 1 (nodes without external addresses can still reach Google APIs and gcr.io).

## Inputs

| Name | Description | Type | Default |
| --- | --- | --- | --- |
| `project_id` | Project that owns the network. | `string` | required |
| `name` | Network name; the subnet is NAME-nodes. | `string` | required |
| `region` | Region of the subnet. | `string` | required |
| `nodes_cidr` | Primary range of the subnet (nodes). | `string` | `"10.10.0.0/24"` |
| `pods_cidr` | Secondary range for pods. | `string` | `"10.20.0.0/18"` |
| `services_cidr` | Secondary range for services. | `string` | `"10.30.0.0/22"` |

## Outputs

| Name | Description |
| --- | --- |
| `network` | Self link of the network. |
| `subnetwork` | Self link of the node subnet. |
| `pods_range_name` | Name of the secondary range for pods. |
| `services_range_name` | Name of the secondary range for services. |

## Example

See `infra/environments/lab/main.tf`, which composes this module.

## Tests

yes (`tests/*.tftest.hcl`, mock provider). Run `make test-terraform` from the repository root.
