import json
from pathlib import Path

import pytest

from gke_triage.domain.errors import UnreadableAuditLog
from gke_triage.infrastructure.audit_log import JsonAuditLogSource
from gke_triage.infrastructure.captures import DirectoryCaptureSource

FIXTURES = Path(__file__).resolve().parents[2] / "fixtures"


def test_the_audit_export_yields_only_the_denied_calls():
    denials = JsonAuditLogSource((FIXTURES / "audit-log.json").read_text()).denials()
    assert [(d.permission, d.principal.rsplit("/", 1)[-1]) for d in denials] == [
        ("storage.objects.create", "default"),
        ("storage.objects.create", "default"),
        ("", "operator@example.org"),
    ]
    assert denials[0].resource.endswith("/objects/a.txt")
    assert denials[0].timestamp == "2026-10-26T10:00:01Z"


@pytest.mark.parametrize("text", ["not json", "{}", '"x"'])
def test_anything_but_a_json_array_is_unreadable(text):
    with pytest.raises(UnreadableAuditLog):
        JsonAuditLogSource(text).denials()


def test_entries_without_a_payload_are_skipped():
    assert JsonAuditLogSource(json.dumps([{"a": 1}, 5, {"protoPayload": 3}])).denials() == []


def test_captures_are_read_sorted_by_name():
    names = [c.name for c in DirectoryCaptureSource(FIXTURES).captures()]
    assert names == sorted(names)
    assert "wrong-service-account" in names


def test_a_missing_directory_is_an_error(tmp_path):
    with pytest.raises(FileNotFoundError):
        DirectoryCaptureSource(tmp_path / "nope").captures()
