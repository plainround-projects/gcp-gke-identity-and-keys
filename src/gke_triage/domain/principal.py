"""The identity of a pod under Workload Identity Federation for GKE, as an IAM principal."""

from __future__ import annotations

import re
from dataclasses import dataclass
from enum import Enum

from gke_triage.domain.errors import InvalidPrincipal

_PROJECT_ID = re.compile(r"[a-z][a-z0-9-]{4,28}[a-z0-9]")
_PROJECT_NUMBER = re.compile(r"[0-9]{1,19}")
_DNS_LABEL = re.compile(r"[a-z0-9]([-a-z0-9]{0,61}[a-z0-9])?")
_URI = re.compile(
    r"principal://iam\.googleapis\.com/projects/(?P<number>[^/]+)/locations/global/workloadIdentityPools/"
    r"(?P<pool>[^/]+)/subject/ns/(?P<namespace>[^/]+)/sa/(?P<ksa>[^/]+)"
)


@dataclass(frozen=True, slots=True)
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
        )


class BindingProblem(Enum):
    """What is wrong with a principal string, if anything."""

    NOT_A_WORKLOAD_PRINCIPAL = "not a principal:// string for a workload identity pool"
    PROJECT_ID_WHERE_NUMBER_BELONGS = "the project id is used where the project number is needed"
    POOL_OF_ANOTHER_PROJECT = "the pool belongs to a different project than the number says"


def check_binding_member(member: str, project_id: str, project_number: str) -> BindingProblem | None:
    """Return the first problem with `member` as a binding for this project, or None when it looks right."""
    match = _URI.fullmatch(member)
    if match is None:
        return BindingProblem.NOT_A_WORKLOAD_PRINCIPAL
    if match["number"] == project_id:
        return BindingProblem.PROJECT_ID_WHERE_NUMBER_BELONGS
    if match["number"] != project_number or match["pool"] != f"{project_id}.svc.id.goog":
        return BindingProblem.POOL_OF_ANOTHER_PROJECT
    return None
