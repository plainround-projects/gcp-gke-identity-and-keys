"""Guardrails over the Terraform source, checked without Terraform or Google Cloud.

They encode the lesson's rules as tests: no keys anywhere, no project-level role for the pod, the project number in the
principal, no public data, and an API endpoint that is never open to the world.
"""

import re
from pathlib import Path

import pytest

INFRA = Path(__file__).resolve().parents[2] / "infra"
SOURCES = {path: path.read_text() for path in INFRA.rglob("*.tf") if ".terraform" not in path.parts}
CODE = {path: re.sub(r"(?m)^\s*#.*$", "", text) for path, text in SOURCES.items()}


def _hits(pattern: str) -> list[str]:
    return [str(path.relative_to(INFRA)) for path, text in CODE.items() if re.search(pattern, text)]


def test_the_sources_were_found():
    assert len(SOURCES) >= 20


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


def test_the_pod_principal_is_built_from_the_project_number_not_the_project_id():
    main = (INFRA / "environments/lab/main.tf").read_text()
    number_part = (
        "principal://iam.googleapis.com/projects/${var.project_number}/locations/global/workloadIdentityPools/"
    )
    subject_part = "${var.project_id}.svc.id.goog/subject/ns/${var.namespace}/sa/${var.kubernetes_service_account}"
    assert number_part + subject_part in main


def test_the_pod_principal_gets_a_role_on_the_bucket_and_none_on_the_key():
    main = (INFRA / "environments/lab/main.tf").read_text()
    assert main.count("local.pod_principal") == 1
    assert "object_users = { reader_writer = local.pod_principal }" in main
    assert "encrypter_decrypter_members = { storage_agent = local.storage_service_agent }" in main


def test_the_bucket_is_created_only_after_the_key_is_authorized():
    main = (INFRA / "environments/lab/main.tf").read_text()
    bucket = main[main.index('module "bucket"') : main.index('module "audit"')]
    assert "depends_on = [module.key]" in bucket


def test_the_api_endpoint_is_never_open_to_the_world():
    # Only the rule that rejects it and the deny-all firewall mention it.
    assert sorted(_hits("0\\.0\\.0\\.0/0")) == ["modules/gke-autopilot/variables.tf", "modules/network/main.tf"]
    assert '!= "0.0.0.0/0"' in (INFRA / "modules/gke-autopilot/variables.tf").read_text()


def test_the_provider_is_pinned_in_every_root_and_module():
    for path in INFRA.rglob("versions.tf"):
        if ".terraform" in path.parts:
            continue
        assert re.search(r'version\s*=\s*"(~>|>=)\s*8', path.read_text()), path
