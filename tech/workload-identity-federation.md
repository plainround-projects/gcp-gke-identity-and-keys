# Workload Identity Federation for GKE

## 1. What it is

Workload Identity Federation for GKE lets a pod call Google Cloud APIs **as itself**, without any key file. Inside the cluster a pod already has an identity: its Kubernetes service account in a namespace. Google Cloud recognizes that identity as an **IAM principal** with a long name, and you grant roles to that principal like to any other identity. The pod gets **short-lived tokens** automatically.

## 2. Why this repository uses it

This is the lesson. The pod must read and write a bucket with no service account key anywhere, and the learner must understand the difference between *authenticating* (the pod proves who it is) and *being authorized* (IAM has a role for that identity).

## 3. Where it appears

| Path | What it does |
| --- | --- |
| `infra/environments/lab/main.tf` | Builds the pod's principal string (`local.pod_principal`) and grants it a role on the bucket. |
| `infra/modules/cmek-bucket/main.tf` | `google_storage_bucket_iam_member` with `roles/storage.objectUser` for that principal. |
| `manifests/base/serviceaccount.yaml`, `deployment.yaml` | The Kubernetes service account `reader-writer` and the pod that uses it. |
| `src/gke_triage/domain/principal.py` | `WorkloadPrincipal` builds and checks the same string. |
| `scripts/lib.sh` | `PRINCIPAL=...` for the break scripts. |
| `tests/unit/domain/test_principal.py`, `infra/environments/lab/tests/principal.tftest.hcl` | Both assert the same literal. |

## 4. How it works underneath

1. The cluster has a **workload pool** named `PROJECT_ID.svc.id.goog`; every pod's identity lives in it. (Autopilot turns this on.)
2. A pod asks for credentials the usual way: the Google tools ask the **metadata server** (a special address that only the local machine answers). On GKE, a component called the **GKE metadata server** answers for pods.
3. That component takes the pod's Kubernetes identity, exchanges it with Google's security token service, and returns a **short-lived federated token**. Nothing is stored in the pod.
4. The pod calls the API with that token. Google identifies the caller as:

```text
principal://iam.googleapis.com/projects/PROJECT_NUMBER/locations/global/workloadIdentityPools/PROJECT_ID.svc.id.goog/subject/ns/NAMESPACE/sa/KUBERNETES_SERVICE_ACCOUNT
```

5. **IAM** now decides: does this principal hold a role with the needed permission on the resource? A different pod (another namespace or service account) is a different principal.

Note the two project identifiers: **PROJECT_NUMBER** (digits, in the first position) and **PROJECT_ID** (the name, in the pool). Using the id in the first position creates a binding that matches nothing, and the failure looks like a propagation delay.

## 5. Walkthrough of this repository's use

`infra/environments/lab/main.tf`

```hcl
  # The pod's identity under Workload Identity Federation for GKE: the project NUMBER, the pool of the project ID,
  # the namespace and the Kubernetes service account. The Python tool builds the same string (gke-triage principal).
  pod_principal = "principal://iam.googleapis.com/projects/${var.project_number}/locations/global/workloadIdentityPools/${var.project_id}.svc.id.goog/subject/ns/${var.namespace}/sa/${var.kubernetes_service_account}"

  # Cloud Storage reads and writes the key with its own service agent, not with the pod's identity.
  storage_service_agent_email = var.storage_service_agent_email != "" ? var.storage_service_agent_email : one(data.google_storage_project_service_account.gcs[*].email_address)
  storage_service_agent       = "serviceAccount:${local.storage_service_agent_email}"
```

`${var.project_number}` and `${var.project_id}` are placed exactly where the format needs them. The Terraform variable `project_number` has a check that it is digits only.

The grant, on the bucket only:

`infra/environments/lab/main.tf`

```hcl
module "bucket" {
  source = "../../modules/cmek-bucket"

  project_id    = var.project_id
  name          = "${var.project_id}-files"
  location      = var.region
  kms_key_id    = module.key.id
  labels        = var.labels
  force_destroy = true

  # Step 2: the pod's principal reads and writes this bucket and nothing else. It holds no role on the key.
  object_users = { reader_writer = local.pod_principal }

  # Creating the bucket fails unless the service agent may already use the key.
  depends_on = [module.key]
```

`object_users = { reader_writer = local.pod_principal }` becomes `roles/storage.objectUser` on that one bucket (see `cloud-storage.md`). The pod needs **no role on the key**: Cloud Storage uses its own service agent for the key (see `cloud-kms.md`).

The same string in Python, with the check that catches the usual mistake:

`src/gke_triage/domain/principal.py`

```python
class WorkloadPrincipal:
    """One Kubernetes service account in one namespace of a project's workload identity pool."""

    project_id: str
    project_number: str
    namespace: str
    service_account: str

    def __post_init__(self) -> None:
        """Reject a project id where the number belongs, and names that Kubernetes would not accept."""
        if _PROJECT_NUMBER.fullmatch(self.project_number) is None:
            raise InvalidPrincipal(
                f"project number must be digits only, got {self.project_number!r}: "
                "use `gcloud projects describe PROJECT_ID --format='value(projectNumber)'`, not the project id"
            )
        if _PROJECT_ID.fullmatch(self.project_id) is None:
            raise InvalidPrincipal(f"not a project id: {self.project_id!r}")
        for label, value in (("namespace", self.namespace), ("service account", self.service_account)):
            if _DNS_LABEL.fullmatch(value) is None:
                raise InvalidPrincipal(f"{label} must be a lowercase DNS label, got {value!r}")

    @property
    def uri(self) -> str:
        """The `principal://` string used as the member of an IAM binding."""
        return (
            f"principal://iam.googleapis.com/projects/{self.project_number}/locations/global/"
            f"workloadIdentityPools/{self.project_id}.svc.id.goog/subject/ns/{self.namespace}/sa/{self.service_account}"
```

The same string in Bash for the break scripts:

`scripts/lib.sh`

```bash
# Use the project NUMBER here, never the project id: with the id the binding matches nothing.
PRINCIPAL="principal://iam.googleapis.com/projects/$PROJECT_NUMBER/locations/global/workloadIdentityPools/$PROJECT_ID.svc.id.goog/subject/ns/demo/sa/reader-writer"
```

And the test that keeps Terraform and Python in agreement:

`infra/environments/lab/tests/principal.tftest.hcl`

```hcl
# The same literal is asserted in tests/unit/domain/test_principal.py: Terraform and the Python tool must agree.
run "the_pod_principal_uses_the_project_number_and_the_pool_of_the_project_id" {
  command = plan

  assert {
    condition     = output.reader_writer_principal == "principal://iam.googleapis.com/projects/123456789012/locations/global/workloadIdentityPools/example-sandbox-0000.svc.id.goog/subject/ns/demo/sa/reader-writer"
    error_message = "The principal must be built from the number, the pool and the subject."
  }
```

## 6. Try it yourself

```bash
.venv/bin/gke-triage principal --project-id example-sandbox-0000 --project-number 123456789012
```
Expected: the full principal string above with those values.

```bash
.venv/bin/gke-triage principal --project-id example-sandbox-0000 --project-number example-sandbox-0000; echo "exit=$?"
```
Expected: ``error: project number must be digits only, got 'example-sandbox-0000': use `gcloud projects describe PROJECT_ID --format='value(projectNumber)'`, not the project id`` and `exit=2`.

```bash
.venv/bin/gke-triage check-binding "principal://iam.googleapis.com/projects/example-sandbox-0000/locations/global/workloadIdentityPools/example-sandbox-0000.svc.id.goog/subject/ns/demo/sa/reader-writer" --project-id example-sandbox-0000 --project-number 123456789012; echo "exit=$?"
```
Expected: `problem: the project id is used where the project number is needed` and `exit=1`.

```bash
cd infra/environments/lab && terraform init -backend=false -input=false >/dev/null && terraform test
```
Expected: `Success! 4 passed, 0 failed.`

With a cluster (not run here): `kubectl -n demo exec deploy/files -- gcloud auth list` shows the pod's federated identity, and `kubectl -n demo get secrets` shows none.

## 7. Mistakes people make

- **The project id in place of the project number.** The binding matches nothing.
- **Reading "permission denied" as "not logged in".** The pod authenticated; IAM found no role. The principal in the message tells you which identity was used.
- **Running the pod as `default`.** That is a different principal with no role (the lesson's break one).
- **Granting the pod a role on the key.** Not needed; Cloud Storage uses its own agent.
- **Restarting the pod after a role change.** Not needed; the next request already sees the change after a short delay.
- **Downloading a key "just for the test".** It defeats the point.

## 8. Check yourself

1. What identifies a pod to IAM? *Its namespace and Kubernetes service account, inside the project's workload pool.*
2. Where does the project number appear in the principal? *In the first position, after `projects/`.*
3. Where does the project id appear? *In the pool name `PROJECT_ID.svc.id.goog`.*
4. Does the pod store a key? *No; it gets short-lived tokens from the metadata server.*
5. Authentication or authorization fails when a role is missing? *Authorization; the caller was recognized.*

## 9. Further reading

- Workload Identity Federation for GKE: <https://cloud.google.com/kubernetes-engine/docs/concepts/workload-identity>
- Authenticate to Google Cloud APIs from GKE workloads: <https://cloud.google.com/kubernetes-engine/docs/how-to/workload-identity>
- Principal identifiers: <https://cloud.google.com/iam/docs/principal-identifiers>
