# GKE Autopilot

## 1. What it is

Google Kubernetes Engine (GKE) is Google Cloud's managed Kubernetes. In **Autopilot** mode Google also manages the machines: you never create or size nodes. You submit pods, and Autopilot provides capacity for them, applies hardened defaults, and bills for the resources your pods request (plus a cluster fee). A **private** cluster gives its nodes internal addresses only.

## 2. Why this repository uses it

The lesson says "use an Autopilot cluster to keep node management out of the way". The learner's focus is identity, not nodes. Autopilot also has Workload Identity Federation for GKE already on, so the keyless access in the lesson works without extra setup.

## 3. Where it appears

| Path | What it does |
| --- | --- |
| `infra/modules/gke-autopilot/main.tf` | The `google_container_cluster` resource. |
| `infra/modules/gke-autopilot/variables.tf` | Inputs, including a check that the API endpoint is never open to `0.0.0.0/0`. |
| `infra/environments/lab/main.tf` | Instantiates it as `demo` with the network from the `network` module. |
| `scripts/deploy.sh` | `gcloud container clusters get-credentials demo --region=...` after the cluster exists. |

## 4. How it works underneath

The **control plane** (the API server and controllers) is run by Google. **Nodes** are virtual machines that Autopilot adds and removes for you. Because there are no node settings to choose, the Terraform resource sets `enable_autopilot = true` and leaves node configuration out entirely (several node-level settings are rejected).

A **private cluster** has nodes with no public addresses. They still need to pull images from `gcr.io` and call Google APIs, which works when the subnet has **Private Google Access** (see `vpc-networking.md`). The control plane keeps an address range of its own (`master_ipv4_cidr_block`, a /28). With `enable_private_endpoint = false` the API endpoint is also reachable from the internet, so **master authorized networks** limit it to the addresses you list.

The **release channel** decides how quickly the cluster's Kubernetes version moves (`REGULAR` here).

## 5. Walkthrough of this repository's use

`infra/modules/gke-autopilot/main.tf`

```hcl
resource "google_container_cluster" "this" {
  #checkov:skip=CKV_GCP_65:Google Groups for RBAC needs a Workspace or Cloud Identity group; the lab uses the owner's own identity
  #checkov:skip=CKV_GCP_66:Binary Authorization needs an attestor and a policy; the lab runs one Google-published image pinned by digest
  #checkov:skip=CKV_GCP_69:Autopilot always runs the GKE metadata server and rejects a node_config block
  #checkov:skip=CKV_GCP_61:Autopilot runs Dataplane V2, which gives intranode visibility itself, and the provider rejects enable_intranode_visibility with enable_autopilot
  #checkov:skip=CKV_GCP_12:Autopilot runs Dataplane V2, which enforces NetworkPolicy; the cluster has no network_policy block to set
  project  = var.project_id
  name     = var.name
  location = var.region

  # Autopilot manages nodes, turns on Workload Identity Federation for GKE and applies hardening defaults.
  enable_autopilot    = true
  deletion_protection = var.deletion_protection
  resource_labels     = var.labels

  network    = var.network
  subnetwork = var.subnetwork

  ip_allocation_policy {
    cluster_secondary_range_name  = var.pods_range_name
    services_secondary_range_name = var.services_range_name
  }

  # Nodes get no external address; the API endpoint stays public but only the listed ranges may reach it.
  private_cluster_config {
    enable_private_nodes    = true
    enable_private_endpoint = false
    master_ipv4_cidr_block  = var.master_cidr
  }

  master_authorized_networks_config {
    dynamic "cidr_blocks" {
      for_each = var.master_authorized_cidrs
      content {
        display_name = cidr_blocks.key
        cidr_block   = cidr_blocks.value
      }
    }
  }

  # No client certificate is issued; users authenticate with their Google identity.
  master_auth {
    client_certificate_config {
      issue_client_certificate = false
    }
  }

  release_channel {
```

- The `#checkov:skip` lines are reviewed exceptions: each says why a scanner recommendation does not apply to Autopilot or the lab (for example, Autopilot always runs the GKE metadata server and rejects a node configuration block).
- `enable_autopilot = true` and `location = var.region` create a **regional** cluster (control plane in several zones).
- `deletion_protection = var.deletion_protection` is false in the lab so `terraform destroy` works.
- `resource_labels` sets labels on the cluster.
- `network` and `subnetwork` place the cluster in the custom VPC; `ip_allocation_policy` names the **secondary ranges** for pod and service addresses.
- `private_cluster_config`: nodes have no public addresses; the endpoint stays public but restricted.
- `master_authorized_networks_config` with `dynamic "cidr_blocks"` writes one allowed range per entry of `var.master_authorized_cidrs` (for example your own address as a /32).
- `master_auth { client_certificate_config { issue_client_certificate = false } }`: no client certificates; people sign in with their Google identity.

`infra/modules/gke-autopilot/main.tf`

```hcl
  release_channel {
    channel = var.release_channel
  }

  # Control-plane and workload logs go to Cloud Logging, where the denials are found.
  logging_config {
    enable_components = ["SYSTEM_COMPONENTS", "WORKLOADS"]
  }
}
```

`logging_config` sends system and workload logs to Cloud Logging, where the audit and container logs are found.

The input check:

`infra/modules/gke-autopilot/variables.tf`

```hcl
variable "master_authorized_cidrs" {
  description = "Ranges allowed to reach the API endpoint, name => CIDR. Your own address as /32 is enough."
  type        = map(string)

  validation {
    condition     = length(var.master_authorized_cidrs) > 0 && alltrue([for c in values(var.master_authorized_cidrs) : can(cidrhost(c, 0)) && c != "0.0.0.0/0"])
    error_message = "Give at least one valid CIDR block, and never 0.0.0.0/0."
  }
```

`length(...) > 0` demands at least one range; `can(cidrhost(c, 0))` is true when the text is a valid CIDR block; `c != "0.0.0.0/0"` forbids "everywhere".

## 6. Try it yourself

```bash
cd infra/modules/gke-autopilot && terraform init -backend=false -input=false >/dev/null && terraform test
```
Expected: `Success! 5 passed, 0 failed.` (autopilot with private nodes; no client certificate; the pool name; an open endpoint rejected; an empty list rejected).

```bash
cd infra/environments/lab && terraform init -backend=false -input=false >/dev/null && GOOGLE_OAUTH_ACCESS_TOKEN=x terraform plan -input=false -lock=false -var-file=lab.tfvars.example | grep -E "^Plan|google_container_cluster.this will"
```
Expected: a line `# module.cluster.google_container_cluster.this will be created` and `Plan: 17 to add, 0 to change, 0 to destroy.`

With a project (not run here): `gcloud container clusters describe demo --region=europe-west1 --format='value(autopilot.enabled, workloadIdentityConfig.workloadPool)'` should print `True` and `PROJECT_ID.svc.id.goog`.

## 7. Mistakes people make

- **Opening the API endpoint to the world.** The module refuses `0.0.0.0/0`.
- **Forgetting Private Google Access** on a private cluster's subnet: pods then cannot pull images.
- **Setting node options on Autopilot.** They are rejected.
- **Leaving the cluster running overnight.** The fee and pod charges continue; the README says to delete it the same day.
- **Assuming Autopilot hides resource requests.** It bills for them, and may raise small requests to its minimums.

## 8. Check yourself

1. Who manages the nodes in Autopilot? *Google.*
2. What does a private cluster change? *Nodes have no public addresses.*
3. What limits who can reach the API endpoint here? *Master authorized networks.*
4. What do the secondary ranges hold? *Pod and service IP addresses.*
5. Is Workload Identity Federation for GKE on by default in Autopilot? *Yes.*

## 9. Further reading

- Autopilot overview: <https://cloud.google.com/kubernetes-engine/docs/concepts/autopilot-overview>
- Private clusters: <https://cloud.google.com/kubernetes-engine/docs/concepts/private-cluster-concept>
- Terraform `google_container_cluster` (provider 8.x): <https://registry.terraform.io/providers/hashicorp/google/latest/docs/resources/container_cluster>
