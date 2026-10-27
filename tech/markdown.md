# Markdown

## 1. What it is

Markdown is a way of writing formatted text in a plain text file. You type ordinary characters and a few marks, and a program turns them into headings, lists, tables, links and code blocks. A file ending in `.md` is a Markdown file. GitHub shows `README.md` below the file list of a repository, formatted. The dialect used here is GitHub Flavored Markdown, which adds tables and fenced code blocks to the original.

## 2. Why this repository uses it

A repository has to explain itself. The lesson asks for a README with run, test and deploy instructions, an architecture document with a diagram, a record of each decision, and operating notes. All of it is Markdown, so it lives next to the code, is reviewed with the code, and changes in the same commit. The triage table in `docs/triage-table.md` is produced by the program from real error texts.

## 3. Where it appears

| Path | What it is |
| --- | --- |
| `README.md` | The front page: what the project is, how to run, test and deploy it, the "Done when" table, the project structure, what is simplified, the verification record. |
| `ARCHITECTURE.md` | The components, the hierarchy diagram (see `mermaid.md`), the pattern, trade-offs, failure modes and limits. |
| `CHANGELOG.md` | What changed in each version. |
| `docs/adr/000N-*.md` | Architecture decision records: one decision each, with context, the decision and the consequences. |
| `docs/triage-table.md` | The lesson's triage table: symptom, exact error text, layer, first check, fix. |
| `infra/modules/*/README.md`, `infra/environments/lab/README.md` | One page per Terraform module: inputs, outputs, example, tests. |
| `tech/*.md` | These notes. |

## 4. How it works underneath

A Markdown file is just text. A renderer (GitHub, an editor preview) reads it line by line and applies the rules. Nothing is run; there are no variables or loops. The marks used in this repository:

- `#`, `##`, `###` at the start of a line make headings of decreasing size. The text after the marks is the title. A blank line separates paragraphs.
- `-` or `*` at the start of a line makes a bullet; `1.` makes a numbered item. Indenting nests a list.
- `**bold**` is bold. Backticks make `code` inside a sentence.
- Three backticks on a line of their own start a **fenced code block**, three more end it. The word after the opening backticks (for example `bash`) names the language, for colors. Inside, nothing is formatted.
- `[text](address)` is a link. The address can be a file in the repository (`ARCHITECTURE.md`) or a web address. `#name` after a file name jumps to a heading.
- A **table** has a header row of cells between `|`, a divider row `| --- | --- |`, then rows. A `|` inside a cell must be written `\|`.
- A line with only `---` is a horizontal rule.

## 5. Walkthrough of this repository's use

### The README's table at the top

`README.md`

```markdown
| **Lesson** | `/prep/gcp/project-gke-identity-and-keys`, "Keyless access to an encrypted bucket from GKE" (`data-structure-explainer/src/content/tracks/gcp/16-project-gke-identity-and-keys.md` in the Plainround app) |
| **Planned hours** | 10 |
| **Level** | Intermediate |
| **Architecture** | [ARCHITECTURE.md](ARCHITECTURE.md), decisions in [docs/adr](docs/adr) |
| **Author** | Sumit Srivastava |
```

A two-column table with an empty header row (`| | |`), then the divider `| --- | --- |`, then one row per fact. Each row is a fact (lesson, planned hours, level, architecture, author) with `**bold**` labels and links.

### Headings in a fixed order

The README's second-level headings (`##`) are, in order: What is here, Prerequisites, Run it on this machine, Test, Deploy to your own project, Done when, Stretch goals, Project structure, What is simplified for teaching, Verification record, License. The order is a repository rule (`TEMPLATE.md`), so every project reads the same.

### A fenced block with a diagram of the folders

The "Project structure" section is a fence with the language `text`: a drawing made of the characters `├──`, `│` and `└──`, which only line up in a fixed-width font. That is why it is in a code block.

### A module README

`infra/modules/network/README.md`

```markdown
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
```

- `# network` is the title; the first paragraph says what the module is.
- "Used for:" ties the module to the lesson's steps.
- `## Inputs` and `## Outputs` are tables with the same columns as the Terraform variables and outputs files (see `terraform.md`): name in backticks, description, type, default.
- `## Example` points to the environment that uses the module; `## Tests` says how to run them.

### The other module pages and the environment page

They follow the same shape as the perimeter's page. Each one in full:

`infra/modules/project-services/README.md`

```markdown
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
```

`infra/modules/gke-autopilot/README.md`

```markdown
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
```

`infra/modules/kms-key/README.md`

```markdown
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

See `infra/environments/lab/main.tf`, which composes this module.

## Tests

yes (`tests/*.tftest.hcl`, mock provider). Run `make test-terraform` from the repository root.
```

`infra/modules/cmek-bucket/README.md`

```markdown
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

See `infra/environments/lab/main.tf`, which composes this module.

## Tests

yes (`tests/*.tftest.hcl`, mock provider). Run `make test-terraform` from the repository root.
```

`infra/modules/audit-logs/README.md`

```markdown
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

See `infra/environments/lab/main.tf`, which composes this module.

## Tests

yes (`tests/*.tftest.hcl`, mock provider). Run `make test-terraform` from the repository root.
```

`infra/environments/lab/README.md`

```markdown
# lab environment

The composition for a same-day lab project: APIs, network, Autopilot cluster, KMS key, encrypted bucket with the pod's role, and the Cloud Storage audit logs. Every module is in `../../modules`.

## Variables

See `variables.tf`; `lab.tfvars.example` shows every value with placeholders. `scripts/create-project.sh` writes the real `lab.tfvars` (git-ignored). `project_number` is the number, not the id. `master_authorized_cidrs` must be your own address as a /32 (never `0.0.0.0/0`; a module rule rejects it).

## Validate without credentials

```bash
cd infra/environments/lab
terraform init -backend=false
terraform validate
GOOGLE_OAUTH_ACCESS_TOKEN=offline-placeholder terraform plan -var-file=lab.tfvars.example   # 17 resources to add, no API call
terraform test                                                                             # principal, key and bucket wiring
```

The offline plan works because the Cloud Storage service agent's email is given in the example variables file (a real run leaves it empty so Terraform looks it up, which also creates the agent), and nothing else reads from Google Cloud.

## Outputs

`cluster_name`, `region`, `bucket`, `key`, `workload_pool`, `reader_writer_principal`.

## State

Local. For shared use copy `backend.tf.example` to `backend.tf`, create the bucket (versioning on) and run `terraform init -migrate-state`.
```

The pages differ only in their title, the one-line description, the step they serve, and the rows of the two tables. The environment's page lists its own inputs and outputs and how to run it.

### An architecture decision record

`docs/adr/0002-key-before-bucket-and-the-agent-not-the-pod.md`

```markdown
# 2. Authorize the Cloud Storage service agent on the key before the bucket exists

Status: accepted, 2026-10-27

## Context

A bucket with a customer-managed default key cannot be created unless Cloud Storage's own service agent may already use that key. The pod never touches the key: Cloud Storage calls Cloud KMS with its agent.

## Decision

`module.key` grants `cryptoKeyEncrypterDecrypter` on the key to the service agent (looked up with `google_storage_project_service_account`, which also creates the agent), and `module.bucket` declares `depends_on = [module.key]`. The pod's principal gets a role on the bucket only. A test fails if the dependency or the single use of the pod principal changes.

## Consequences

- The three failure layers stay separate: the pod's IAM role (authorization), the agent's role and the key's state (key).
- The first apply needs credentials (the data source), so the offline plan supplies the agent's email as a variable.
- Disabling the key version in step 5 makes reads fail without touching IAM, which is the point of the step.
```

An ADR is short and always has the same parts: a numbered title, a status and date, **Context** (the problem), **Decision** (what was chosen) and **Consequences**. The number never changes, so other documents can refer to "ADR 2".

## 6. Try it yourself

```bash
grep -n "^## " README.md
```
Expected: the eleven second-level headings of the README, with line numbers.

```bash
ls docs/adr
```
Expected: `0001-direct-workload-identity-principal-on-the-bucket.md`, `0002-key-before-bucket-and-the-agent-not-the-pod.md`, `0003-a-classifier-over-captured-error-text.md`.

```bash
grep -c '^| ' infra/modules/network/README.md
```
Expected: the number of table rows in the perimeter module's page (headers and dividers included).

```bash
grep -rn "](" README.md | grep -o "](\([^)]*\))" | head -3
```
Expected: the first three link targets, for example `(ARCHITECTURE.md)`.

## 7. Mistakes people make

- **A missing blank line** before a list or table, so the renderer shows plain text.
- **A `|` inside a table cell** without a backslash, which splits the cell.
- **Tabs and spaces mixed** in nested lists.
- **Documents that drift from the code.** Here the `tech/` notes quote the code itself, and the triage table is generated.
- **Absolute web links to files in the same repository.** Relative links keep working in a fork or a clone.
- **A fence that is never closed.** The rest of the page turns into code.

## 8. Check yourself

1. What marks a heading? *`#` characters at the start of a line.*
2. How do you write a code block? *Three backticks before and after, with the language after the first three.*
3. How do you put a `|` in a table cell? *Write `\|`.*
4. What are the four parts of an ADR? *Title with status and date, Context, Decision, Consequences.*
5. Why use relative links to files in the repository? *They keep working in a fork or a clone.*

## 9. Further reading

- GitHub Flavored Markdown specification: <https://github.github.com/gfm/>
- Basic writing and formatting syntax: <https://docs.github.com/en/get-started/writing-on-github/getting-started-with-writing-and-formatting-on-github/basic-writing-and-formatting-syntax>
- Architecture decision records: <https://adr.github.io/>
