# IAM, roles and principals

## 1. What it is

**IAM** (Identity and Access Management) answers "who may do what to which thing" in Google Cloud. An **identity** is a user, a group, a service account, or here a Kubernetes workload. A **permission** is one allowed action (`storage.objects.get`). A **role** is a named bundle of permissions. A **binding** says "this member has this role on this resource". A **principal** is the full name of an identity in a binding; this repository's pod is a `principal://...` string (see `workload-identity-federation.md`).

## 2. Why this repository uses it

The lesson separates *authentication* ("who are you?") from *authorization* ("what may you do?"). The pod authenticates fine; the three breaks differ in what IAM, or the key behind IAM, says.

## 3. Where it appears

| Path | What it does with IAM |
| --- | --- |
| `infra/modules/cmek-bucket/main.tf` | `roles/storage.objectUser` for the pod's principal, on the bucket only. |
| `infra/modules/kms-key/main.tf` | `roles/cloudkms.cryptoKeyEncrypterDecrypter` for the Cloud Storage service agent, on the key only. |
| `infra/modules/audit-logs/main.tf` | Audit configuration (not a role). |
| `tests/unit/test_infrastructure_policy.py` | Fails if a project-level role, a key resource, a public member or a broad role appears. |
| `scripts/break-missing-role.sh`, `restore-role.sh` | Remove and add the bucket binding with `gcloud storage buckets ...-iam-policy-binding`. |
| `scripts/prove.sh` | Reads the bucket's policy and checks for the principal. |
| `src/gke_triage/domain/triage.py` | Tells "default service account" from "missing role". |

## 4. How it works underneath

- Where a role is granted matters: on the **project** it reaches everything inside; on a **bucket** or **key** it reaches only that one. This repository grants only on resources.
- A role is effective for the principal named in the binding. If the pod runs as another Kubernetes service account (`default`), that is a **different principal** with no role.
- **Service agents** are Google-run identities that act for a service. The Cloud Storage agent uses your key; it needs its own grant.
- IAM changes take a short time to spread; a check right after a change can still see the old answer.
- The denial message is the evidence: it names the principal, the permission and the resource.

## 5. Walkthrough of this repository's use

`tests/unit/test_infrastructure_policy.py`

```python
def test_no_service_account_key_is_ever_created():
    assert _hits(r'resource\s+"google_service_account_key"') == []


PROJECT_IAM = ["google_project_iam_member", "google_project_iam_binding", "google_project_iam_policy"]


@pytest.mark.parametrize("kind", PROJECT_IAM)
def test_no_project_level_role_is_granted(kind):
    assert _hits(rf'resource\s+"{kind}"') == []


@pytest.mark.parametrize("role", ["roles/owner", "roles/editor", "roles/storage.admin", "roles/cloudkms.admin"])
def test_no_broad_role_appears(role):
    assert _hits(re.escape(role)) == []


def test_nothing_is_public():
    assert _hits("allUsers|allAuthenticatedUsers") == []
```

These tests read the Terraform source as text. They fail if a `google_service_account_key` resource, a project-level IAM resource (`google_project_iam_member`, `..._binding`, `..._policy`), or a broad role (`roles/owner`, `roles/editor`, `roles/storage.admin`, `roles/cloudkms.admin`) appears, or if `allUsers`/`allAuthenticatedUsers` is used. `rf'resource\s+"{kind}"'` is a regular expression with the resource kind inserted.

The pod's role and the "no role on the key" rule:

`tests/unit/test_infrastructure_policy.py`

```python
def test_the_pod_principal_gets_a_role_on_the_bucket_and_none_on_the_key():
    main = (INFRA / "environments/lab/main.tf").read_text()
    assert main.count("local.pod_principal") == 1
    assert "object_users = { reader_writer = local.pod_principal }" in main
    assert "encrypter_decrypter_members = { storage_agent = local.storage_service_agent }" in main
```

The break and the fix:

`scripts/break-missing-role.sh`

```bash
gcloud storage buckets remove-iam-policy-binding "gs://$BUCKET" --member="$PRINCIPAL" --role=roles/storage.objectUser
echo "waiting 60 seconds for the removal to propagate"
sleep 60
```

`scripts/restore-role.sh`

```bash
gcloud storage buckets add-iam-policy-binding "gs://$BUCKET" --member="$PRINCIPAL" --role=roles/storage.objectUser
echo "waiting 60 seconds for the grant to propagate"
sleep 60
pod_test files
kubectl -n demo get pods -l app=files   # RESTARTS is still 0: no restart was needed
```

`remove-iam-policy-binding` takes `--member` and `--role`: the exact binding to take away. After the fix, `kubectl ... get pods` shows `RESTARTS` still `0`: the pod was not restarted, because IAM is checked on each request.

## 6. Try it yourself

```bash
.venv/bin/python -m pytest tests/unit/test_infrastructure_policy.py -q -p no:cacheprovider
```
Expected: `15 passed` (some tests run once per role or resource kind).

```bash
grep -rhn "role  *= \"roles/" infra --include=main.tf | sed 's/.*"roles/roles/; s/"$//'
```
Expected: `roles/cloudkms.cryptoKeyEncrypterDecrypter` and `roles/storage.objectUser`.

```bash
.venv/bin/gke-triage classify tests/fixtures/wrong-service-account.txt | sed -n 1,2p
```
Expected: `layer:       authorization` and `cause:       default service account`: authenticated, then no role.

## 7. Mistakes people make

- **Reading 403 as "not logged in".** The caller authenticated; IAM found no role.
- **Granting a broad role on the project to make something work.**
- **Using the project id in the principal.** The binding matches nothing.
- **Granting the pod a role on the key.** The Cloud Storage agent needs it, not the pod.
- **Restarting the pod after a role change.** Not needed.

## 8. Check yourself

1. What is a binding? *A member, a role and a resource tied together.*
2. Why does the `default` service account get a denial? *It is a different principal with no role on the bucket.*
3. Which identity uses the key? *The Cloud Storage service agent.*
4. What does the denial message name? *The principal, the permission and the resource.*
5. Why is a bucket-level grant safer than a project-level one? *It reaches only that bucket.*

## 9. Further reading

- IAM overview: <https://cloud.google.com/iam/docs/overview>
- Principal identifiers: <https://cloud.google.com/iam/docs/principal-identifiers>
- Cloud Storage roles: <https://cloud.google.com/storage/docs/access-control/iam-roles>
- Troubleshooting permission denied: <https://cloud.google.com/iam/docs/troubleshooting-access>
