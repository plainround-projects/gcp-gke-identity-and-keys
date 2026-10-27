"""The Kubernetes manifests, checked as data: schema-valid, keyless, hardened, and wrong in exactly the lesson's way."""

from pathlib import Path
from typing import Any

import kubernetes_validate
import pytest
import yaml

ROOT = Path(__file__).resolve().parents[2] / "manifests"
K8S_VERSION = "1.33"


def load(path: str) -> list[dict[str, Any]]:
    return [doc for doc in yaml.safe_load_all((ROOT / path).read_text()) if doc]


def all_manifests() -> list[Path]:
    return sorted(p for p in ROOT.rglob("*.yaml") if p.name != "kustomization.yaml")


def deployment(path: str) -> dict[str, Any]:
    return next(doc for doc in load(path) if doc["kind"] == "Deployment")


@pytest.mark.parametrize("path", all_manifests(), ids=lambda p: str(p.relative_to(ROOT)))
def test_every_manifest_is_valid_against_the_kubernetes_schema(path):
    for doc in yaml.safe_load_all(path.read_text()):
        kubernetes_validate.validate(doc, K8S_VERSION, strict=True)


def test_the_service_deployment_runs_as_the_reader_writer_account_in_the_demo_namespace():
    spec = deployment("base/deployment.yaml")
    assert spec["metadata"]["namespace"] == "demo"
    assert spec["spec"]["template"]["spec"]["serviceAccountName"] == "reader-writer"


def test_the_wrong_identity_copy_has_no_service_account_name_so_it_runs_as_default():
    pod = deployment("overlays/wrong-identity/files-default.yaml")["spec"]["template"]["spec"]
    assert "serviceAccountName" not in pod


def test_the_two_deployments_differ_only_in_the_identity_and_the_name():
    good = deployment("base/deployment.yaml")["spec"]["template"]["spec"]
    bad = deployment("overlays/wrong-identity/files-default.yaml")["spec"]["template"]["spec"]
    good = {k: v for k, v in good.items() if k != "serviceAccountName"}
    assert good == bad


@pytest.mark.parametrize("path", ["base/deployment.yaml", "overlays/wrong-identity/files-default.yaml"])
def test_no_credential_reaches_the_pod(path):
    pod = deployment(path)["spec"]["template"]["spec"]
    assert pod["automountServiceAccountToken"] is False
    assert all("secret" not in volume for volume in pod.get("volumes", []))
    container = pod["containers"][0]
    assert "envFrom" not in container
    assert not any(e["name"].startswith("GOOGLE_APPLICATION_CREDENTIALS") for e in container.get("env", []))
    assert all("hostPath" not in volume for volume in pod.get("volumes", []))


@pytest.mark.parametrize("path", ["base/deployment.yaml", "overlays/wrong-identity/files-default.yaml"])
def test_the_pod_meets_the_restricted_pod_security_standard(path):
    pod = deployment(path)["spec"]["template"]["spec"]
    container = pod["containers"][0]
    assert pod["securityContext"]["runAsNonRoot"] is True
    assert pod["securityContext"]["seccompProfile"]["type"] == "RuntimeDefault"
    assert container["securityContext"]["allowPrivilegeEscalation"] is False
    assert container["securityContext"]["capabilities"]["drop"] == ["ALL"]
    assert container["securityContext"]["readOnlyRootFilesystem"] is True
    assert container["resources"]["requests"]
    assert container["resources"]["limits"]


@pytest.mark.parametrize("path", ["base/deployment.yaml", "overlays/wrong-identity/files-default.yaml"])
def test_the_image_is_pinned_to_a_version(path):
    image = deployment(path)["spec"]["template"]["spec"]["containers"][0]["image"]
    tag = image.rsplit(":", 1)[-1]
    assert tag not in {"latest", "slim", "stable"}
    assert image.startswith("gcr.io/google.com/cloudsdktool/google-cloud-cli:")
    assert "@sha256:" in image


def test_the_service_account_carries_no_annotation_and_no_key_reference():
    account = next(doc for doc in load("base/serviceaccount.yaml") if doc["kind"] == "ServiceAccount")
    assert "annotations" not in account["metadata"]
    assert "secrets" not in account


def test_nothing_may_connect_to_the_pod():
    policy = next(doc for doc in load("base/networkpolicy.yaml") if doc["kind"] == "NetworkPolicy")
    assert policy["spec"]["podSelector"] == {}
    assert policy["spec"]["policyTypes"] == ["Ingress"]
    assert "ingress" not in policy["spec"]
