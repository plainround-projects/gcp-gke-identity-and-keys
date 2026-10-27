from collections.abc import Sequence

from gke_triage.application.diagnose import BuildTriageTable, SummarizeDenials, diagnose
from gke_triage.application.ports import Capture
from gke_triage.domain.audit import AuditDenial
from gke_triage.domain.triage import Layer


class FakeLog:
    def __init__(self, denials: Sequence[AuditDenial]) -> None:
        self._denials = denials

    def denials(self):
        return self._denials


class FakeCaptures:
    def __init__(self, captures):
        self._captures = captures

    def captures(self):
        return self._captures


def denial(principal="p/default", permission="storage.objects.create", resource="r"):
    return AuditDenial(principal, permission, resource, "storage.objects.create", "t")


def test_diagnose_returns_the_domain_finding():
    assert diagnose("Cloud KMS key x is disabled").layer is Layer.KEY


def test_repeated_denials_are_grouped_and_ordered_by_count():
    log = FakeLog([denial("a"), denial("b"), denial("b"), denial("b"), denial("a")])
    summary = SummarizeDenials(log).execute()
    assert [(s.denial.principal, s.count) for s in summary] == [("b", 3), ("a", 2)]


def test_ties_keep_the_order_they_were_first_seen():
    summary = SummarizeDenials(FakeLog([denial("x"), denial("y")])).execute()
    assert [s.denial.principal for s in summary] == ["x", "y"]


def test_no_denials_is_an_empty_summary():
    assert SummarizeDenials(FakeLog([])).execute() == []


def test_the_table_has_a_row_per_capture_with_the_layer_and_escaped_pipes():
    captures = FakeCaptures(
        [
            Capture("key", "ERROR: Cloud KMS key a|b is disabled"),
            Capture(
                "missing-role", "ERROR: p/sa/reader-writer does not have storage.objects.get access to the object."
            ),
        ]
    )
    lines = BuildTriageTable(captures).execute().splitlines()
    assert lines[0].startswith("| Symptom | Exact error text | Layer | First check | Fix |")
    assert len(lines) == 4
    assert "a\\|b" in lines[2]
    assert "| key |" in lines[2]
    assert "| authorization |" in lines[3]
