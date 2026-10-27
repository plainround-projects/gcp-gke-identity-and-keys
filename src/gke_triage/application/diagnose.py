"""Use cases: classify one error, summarize audit denials, build the triage table."""

from __future__ import annotations

from collections import Counter
from dataclasses import dataclass

from gke_triage.application.ports import AuditLogSource, CaptureSource
from gke_triage.domain.audit import AuditDenial
from gke_triage.domain.triage import Finding, classify


def diagnose(text: str) -> Finding:
    """Classify one failed call from its error text."""
    return classify(text)


@dataclass(frozen=True, slots=True)
class DenialSummary:
    """One distinct denial and how many times it appears."""

    denial: AuditDenial
    count: int


class SummarizeDenials:
    """Group an audit log export by principal, permission and resource."""

    def __init__(self, source: AuditLogSource) -> None:
        """Create the use case around an audit log source."""
        self._source = source

    def execute(self) -> list[DenialSummary]:
        """Distinct denials, most frequent first, ties in first-seen order."""
        denials = self._source.denials()
        keys = [(d.principal, d.permission, d.resource) for d in denials]
        counts = Counter(keys)
        first_seen: dict[tuple[str, str, str], AuditDenial] = {}
        for denial, key in zip(denials, keys, strict=True):
            first_seen.setdefault(key, denial)
        ordered = sorted(first_seen, key=lambda key: -counts[key])
        return [DenialSummary(first_seen[key], counts[key]) for key in ordered]


class BuildTriageTable:
    """Render the lesson's triage table, one row per captured failure."""

    def __init__(self, source: CaptureSource) -> None:
        """Create the use case around a capture source."""
        self._source = source

    def execute(self) -> str:
        """A Markdown table: symptom, exact error text, layer, first check, fix."""
        rows = ["| Symptom | Exact error text | Layer | First check | Fix |", "| --- | --- | --- | --- | --- |"]
        for capture in self._source.captures():
            finding = classify(capture.text)
            rows.append(
                "| "
                + " | ".join(
                    _cell(value)
                    for value in (
                        f"{finding.symptom} ({capture.name})",
                        finding.evidence,
                        finding.layer.value,
                        finding.first_check,
                        finding.fix,
                    )
                )
                + " |"
            )
        return "\n".join(rows) + "\n"


def _cell(value: str) -> str:
    return value.replace("|", "\\|").replace("\n", " ")
