"""Adapter: the JSON that `gcloud logging read --format=json` prints for Cloud Storage data-access audit entries."""

from __future__ import annotations

import json
from collections.abc import Sequence
from typing import Any

from gke_triage.domain.audit import AuditDenial, is_denial
from gke_triage.domain.errors import UnreadableAuditLog


class JsonAuditLogSource:
    """Parses an export (a JSON array of log entries) into the denials it contains."""

    def __init__(self, text: str) -> None:
        """`text` is the whole export."""
        self._text = text

    def denials(self) -> Sequence[AuditDenial]:
        """The denied calls; entries that are not audit entries or were allowed are skipped."""
        try:
            entries = json.loads(self._text)
        except ValueError as error:
            raise UnreadableAuditLog("input is not JSON") from error
        if not isinstance(entries, list):
            raise UnreadableAuditLog("expected a JSON array, as `--format=json` prints")
        found: list[AuditDenial] = []
        for entry in entries:
            found.extend(_denials_in(entry))
        return found


def _denials_in(entry: Any) -> list[AuditDenial]:
    payload = entry.get("protoPayload") if isinstance(entry, dict) else None
    if not isinstance(payload, dict):
        return []
    authentication = payload.get("authenticationInfo") or {}
    principal = authentication.get("principalSubject") or authentication.get("principalEmail") or "unknown"
    status = payload.get("status") or {}
    status_code = status.get("code")
    results = []
    for authorization in payload.get("authorizationInfo") or []:
        if is_denial(status_code, authorization.get("granted")):
            results.append(
                AuditDenial(
                    principal=str(principal),
                    permission=str(authorization.get("permission", "")),
                    resource=str(authorization.get("resource") or payload.get("resourceName", "")),
                    method=str(payload.get("methodName", "")),
                    timestamp=str(entry.get("timestamp", "")),
                )
            )
    if not results and is_denial(status_code, None):
        results.append(
            AuditDenial(
                str(principal),
                "",
                str(payload.get("resourceName", "")),
                str(payload.get("methodName", "")),
                str(entry.get("timestamp", "")),
            )
        )
    return results
