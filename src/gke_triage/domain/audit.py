"""A denied call as Cloud Audit Logs record it."""

from __future__ import annotations

from dataclasses import dataclass

_PERMISSION_DENIED = 7  # google.rpc.Code.PERMISSION_DENIED


@dataclass(frozen=True, slots=True)
class AuditDenial:
    """One denied Cloud Storage call: who, what permission, on which resource, when."""

    principal: str
    permission: str
    resource: str
    method: str
    timestamp: str


def is_denial(status_code: int | None, granted: bool | None) -> bool:
    """A call was denied when the authorization check says not granted or the status is PERMISSION_DENIED."""
    return granted is False or status_code == _PERMISSION_DENIED
