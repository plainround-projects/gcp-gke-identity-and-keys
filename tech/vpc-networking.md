# VPC networking (networks, subnets, Private Google Access, firewall rules)

## 1. What it is

A **VPC** (Virtual Private Cloud) network is your private network inside Google Cloud. It has **subnets**: address ranges (written in **CIDR** form such as `10.10.0.0/24`, meaning the first 24 bits fixed, 256 addresses) in one region. A **firewall rule** allows or denies traffic by direction, source or destination range, and protocol. **Private Google Access** lets machines that have no public address still reach Google's own APIs and image registries.

## 2. Why this repository uses it

A private GKE cluster has nodes without public addresses. The pod's image comes from `gcr.io` and its commands call `storage.googleapis.com`, so the subnet must allow Google API access. The deny-all rule documents that nothing reaches the cluster except what GKE itself allows.

## 3. Where it appears

| Path | What it does |
| --- | --- |
| `infra/modules/network/main.tf` | A custom VPC, one subnet with two secondary ranges, flow logs, Private Google Access, and a deny-all ingress firewall rule. |
| `infra/modules/network/variables.tf` | Default ranges: nodes `10.10.0.0/24`, pods `10.20.0.0/18`, services `10.30.0.0/22`; each checked with `cidrhost`. |
| `infra/environments/lab/main.tf` | Creates it as `lab` and passes it to the cluster. |

## 4. How it works underneath

- **Custom mode** (`auto_create_subnetworks = false`) means no subnets exist until you create them.
- A subnet has one **primary range** for node addresses and may have **secondary ranges**. GKE uses one secondary range for pod addresses and one for service addresses.
- Every network has two invisible rules: allow all egress, deny all ingress. A firewall rule with a **priority** number (lower number wins; 0 to 65535) overrides them. Priority 65534 is nearly the lowest, so GKE's own allow rules (created at higher priority) win and everything else hits the explicit deny.
- **Flow logs** record samples of connections for the subnet. A `flow_sampling` of `0.5` keeps half.
- With Private Google Access, traffic from an address without a public IP to Google API addresses stays on Google's network.

## 5. Walkthrough of this repository's use

`infra/modules/network/main.tf`

```hcl
resource "google_compute_network" "this" {
  project                 = var.project_id
  name                    = var.name
  auto_create_subnetworks = false
}

# GKE adds its own allow rules for the cluster. Everything else is denied explicitly, with logging, at the lowest priority.
resource "google_compute_firewall" "deny_all_ingress" {
  project   = var.project_id
  name      = "${var.name}-deny-all-ingress"
  network   = google_compute_network.this.id
  direction = "INGRESS"
  priority  = 65534

  source_ranges = ["0.0.0.0/0"]

  deny {
    protocol = "all"
  }

  log_config {
    metadata = "INCLUDE_ALL_METADATA"
  }
}

# Private Google Access lets nodes without external addresses reach Google APIs and gcr.io, which the pod needs.
resource "google_compute_subnetwork" "nodes" {
  project                  = var.project_id
  name                     = "${var.name}-nodes"
  region                   = var.region
  network                  = google_compute_network.this.id
  ip_cidr_range            = var.nodes_cidr
  private_ip_google_access = true

  secondary_ip_range {
    range_name    = "pods"
    ip_cidr_range = var.pods_cidr
  }

  secondary_ip_range {
    range_name    = "services"
    ip_cidr_range = var.services_cidr
  }

  log_config {
    aggregation_interval = "INTERVAL_10_MIN"
    flow_sampling        = 0.5
    metadata             = "INCLUDE_ALL_METADATA"
```

- `ip_cidr_range = var.nodes_cidr`: the node range. The two `secondary_ip_range` blocks name `pods` and `services`; the cluster module refers to these names.
- `private_ip_google_access = true`: the line that lets private nodes pull `gcr.io` images and call Cloud Storage.
- `log_config`: flow logs every 10 minutes, half the packets sampled, all metadata included.
- The firewall: `direction = "INGRESS"`, `priority = 65534`, `source_ranges = ["0.0.0.0/0"]` and `deny { protocol = "all" }` deny every incoming connection that nothing more specific allows; `log_config` records the denials.

The input checks:

`infra/modules/network/variables.tf`

```hcl
variable "nodes_cidr" {
  description = "Primary range of the subnet (nodes)."
  type        = string
  default     = "10.10.0.0/24"

  validation {
    condition     = can(cidrhost(var.nodes_cidr, 0))
    error_message = "nodes_cidr must be a CIDR block."
  }
```

`can(cidrhost(var.nodes_cidr, 0))` is true when the text is a valid CIDR block.

## 6. Try it yourself

```bash
cd infra/modules/network && terraform init -backend=false -input=false >/dev/null && terraform test
```
Expected: `Success! 4 passed, 0 failed.`

```bash
terraform console <<< 'cidrhost("10.20.0.0/18", 0)' 2>/dev/null
```
Expected: `"10.20.0.0"`. Also try `cidrhost("10.20.0.0/18", 16383)`, which gives `"10.20.63.255"`, the last of 16,384 addresses.

```bash
python3 -c "import ipaddress; n = ipaddress.ip_network('10.10.0.0/24'); print(n.num_addresses, n[0], n[-1])"
```
Expected: `256 10.10.0.0 10.10.0.255`

## 7. Mistakes people make

- **Overlapping ranges** between the node, pod and service ranges.
- **A private cluster without Private Google Access.** Image pulls hang.
- **A deny rule with a higher priority than the allow rules.** Priority numbers run the other way: lower wins.
- **Opening `0.0.0.0/0` to the API endpoint.** The cluster module refuses it.
- **Forgetting that a firewall rule is stateful.** Replies to allowed connections are allowed.

## 8. Check yourself

1. How many addresses are in a /24? *256.*
2. What does Private Google Access allow? *Machines without public addresses to reach Google APIs.*
3. Which firewall priority wins, 100 or 65534? *100; lower numbers win.*
4. What are secondary ranges used for here? *Pod and service addresses.*
5. What is a custom-mode network? *One with no automatic subnets.*

## 9. Further reading

- VPC overview: <https://cloud.google.com/vpc/docs/vpc>
- Private Google Access: <https://cloud.google.com/vpc/docs/private-google-access>
- Firewall rules: <https://cloud.google.com/firewall/docs/firewalls>
- VPC flow logs: <https://cloud.google.com/vpc/docs/flow-logs>
