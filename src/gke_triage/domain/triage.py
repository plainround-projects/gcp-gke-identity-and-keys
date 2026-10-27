"""Classify a failed Cloud Storage call from its error text: which layer failed, and what to check first."""

from __future__ import annotations

import re
from dataclasses import dataclass
from enum import Enum


class Layer(Enum):
    """The three places access can fail, plus the case the rules do not recognize."""

    IDENTITY = "identity"
    AUTHORIZATION = "authorization"
    KEY = "key"
    UNKNOWN = "unknown"


class Cause(Enum):
    """The specific reason inside a layer."""

    NO_CREDENTIALS = "no credentials"
    DEFAULT_SERVICE_ACCOUNT = "default service account"
    MISSING_ROLE = "missing role"
    KEY_DISABLED = "key disabled"
    KEY_ACCESS_DENIED = "key access denied"
    UNRECOGNIZED = "unrecognized"


@dataclass(frozen=True, slots=True)
class Finding:
    """The result of classifying one error text."""

    layer: Layer
    cause: Cause
    symptom: str
    first_check: str
    fix: str
    principal: str | None = None
    permission: str | None = None
    evidence: str = ""


_AUTHORIZATION = re.compile(
    r"(?P<principal>\S+) does not have (?P<permission>[A-Za-z0-9_.]+) access to (?P<what>[^.]+)"
)
_KEY_DISABLED = re.compile(
    r"cloud kms key.{0,300}?(is disabled|disabled|destroyed|scheduled for destruction)", re.I | re.S
)
_KEY_PERMISSION = re.compile(r"Permission '(?P<permission>cloudkms\.[A-Za-z0-9_.]+)' denied", re.I)
_NO_CREDENTIALS = re.compile(
    r"could not (automatically )?determine credentials|default credentials were not found|"
    r"unable to (reach|connect to) the metadata server|HTTPError 401|invalid credentials|"
    r"reauthentication is needed",
    re.I,
)
_DEFAULT_ACCOUNT = re.compile(r"/sa/default$")


def classify(text: str) -> Finding:
    """Classify `text`, the output of a failed `gcloud storage` command or a Cloud Storage client error."""
    evidence = _evidence(text)
    if _KEY_DISABLED.search(text):
        return Finding(
            Layer.KEY,
            Cause.KEY_DISABLED,
            "reads fail although IAM is fine",
            "gcloud kms keys versions list --key=KEY --keyring=RING --location=LOCATION",
            "gcloud kms keys versions enable VERSION ... (a destroyed version cannot be recovered)",
            evidence=evidence,
        )
    key_permission = _KEY_PERMISSION.search(text)
    if key_permission:
        return Finding(
            Layer.KEY,
            Cause.KEY_ACCESS_DENIED,
            "the bucket cannot use its key",
            "gcloud kms keys get-iam-policy KEY ...: does the Cloud Storage service agent hold encrypterDecrypter?",
            "gcloud storage service-agent --project=PROJECT --authorize-cmek=KEY",
            permission=key_permission["permission"],
            evidence=evidence,
        )
    authorization = _AUTHORIZATION.search(text)
    if authorization:
        principal = authorization["principal"].rstrip(",:")
        permission = authorization["permission"]
        if _DEFAULT_ACCOUNT.search(principal):
            return Finding(
                Layer.AUTHORIZATION,
                Cause.DEFAULT_SERVICE_ACCOUNT,
                "authenticated but denied (sa/default)",
                "print the principal in the error: is it the account you meant?",
                "set serviceAccountName on the pod to the account that holds the bucket role",
                principal=principal,
                permission=permission,
                evidence=evidence,
            )
        return Finding(
            Layer.AUTHORIZATION,
            Cause.MISSING_ROLE,
            "denied after a role was removed, or never granted",
            "read the bucket policy: gcloud storage buckets get-iam-policy gs://BUCKET",
            f"grant a role that includes {permission} to the principal, on the bucket",
            principal=principal,
            permission=permission,
            evidence=evidence,
        )
    if _NO_CREDENTIALS.search(text):
        return Finding(
            Layer.IDENTITY,
            Cause.NO_CREDENTIALS,
            "the call has no usable credentials",
            "kubectl exec ... -- gcloud auth list; is Workload Identity Federation enabled on the cluster?",
            "enable the workload pool on the cluster (Autopilot has it); run the pod with a Kubernetes service account",
            evidence=evidence,
        )
    return Finding(
        Layer.UNKNOWN,
        Cause.UNRECOGNIZED,
        "not one of the three known failures",
        "read the full error and the audit log entry for the call",
        "extend gke_triage.domain.triage with a rule once you know the cause",
        evidence=evidence,
    )


def _evidence(text: str) -> str:
    """The first non-empty line, the part a person would paste into a table."""
    for line in text.splitlines():
        if line.strip():
            return line.strip()
    return ""
