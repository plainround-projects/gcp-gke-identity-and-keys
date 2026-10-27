"""Ports: where captured error texts and audit log entries come from."""

from __future__ import annotations

from collections.abc import Sequence
from dataclasses import dataclass
from typing import Protocol

from gke_triage.domain.audit import AuditDenial


@dataclass(frozen=True, slots=True)
class Capture:
    """The text of one failure as you captured it, under a name such as `wrong-service-account`."""

    name: str
    text: str


class CaptureSource(Protocol):
    """Yields the captured failures to put in the triage table."""

    def captures(self) -> Sequence[Capture]:
        """All captures, in a stable order."""
        ...


class AuditLogSource(Protocol):
    """Yields the denied calls found in an audit log export."""

    def denials(self) -> Sequence[AuditDenial]:
        """Every denial in the export, in log order."""
        ...
