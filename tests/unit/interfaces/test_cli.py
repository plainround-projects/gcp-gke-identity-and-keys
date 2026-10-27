import io
from pathlib import Path

import pytest

from gke_triage.interfaces.cli import main

FIXTURES = Path(__file__).resolve().parents[2] / "fixtures"
NUMBER = "123456789012"
PROJECT = "example-sandbox-0000"


def run(capsys, *argv):
    status = main(list(argv))
    captured = capsys.readouterr()
    return status, captured.out, captured.err


def test_classify_prints_layer_cause_principal_permission_and_checks(capsys):
    status, out, _ = run(capsys, "classify", str(FIXTURES / "wrong-service-account.txt"))
    assert status == 0
    assert "layer:       authorization" in out
    assert "cause:       default service account" in out
    assert "permission:  storage.objects.create" in out
    assert "/sa/default" in out


def test_classify_reads_standard_input_with_a_dash(capsys, monkeypatch):
    monkeypatch.setattr("sys.stdin", io.StringIO("Cloud KMS key k is disabled"))
    status, out, _ = run(capsys, "classify", "-")
    assert status == 0
    assert "layer:       key" in out


def test_audit_lists_distinct_denials_and_exits_1_when_there_are_some(capsys):
    status, out, _ = run(capsys, "audit", str(FIXTURES / "audit-log.json"))
    assert status == 1
    assert out.splitlines()[0].startswith("2x  principal://")
    assert "sa/default" in out


def test_audit_with_no_denials_exits_0(capsys, tmp_path):
    empty = tmp_path / "log.json"
    empty.write_text("[]")
    assert run(capsys, "audit", str(empty))[:2] == (0, "no denials found\n")


def test_table_renders_every_capture_in_the_directory(capsys):
    status, out, _ = run(capsys, "table", str(FIXTURES))
    assert status == 0
    assert out.count("\n") == 2 + len(list(FIXTURES.glob("*.txt")))


def test_principal_prints_the_member_for_a_binding(capsys):
    status, out, _ = run(capsys, "principal", "--project-id", PROJECT, "--project-number", NUMBER)
    assert status == 0
    assert out.strip().endswith("/subject/ns/demo/sa/reader-writer")


def test_principal_rejects_the_project_id_in_place_of_the_number(capsys):
    status, _, err = run(capsys, "principal", "--project-id", PROJECT, "--project-number", PROJECT)
    assert status == 2
    assert "digits only" in err


def test_check_binding_flags_the_project_id_and_accepts_the_number(capsys):
    good = f"principal://iam.googleapis.com/projects/{NUMBER}/locations/global/workloadIdentityPools/{PROJECT}.svc.id.goog/subject/ns/demo/sa/reader-writer"
    bad = good.replace(NUMBER, PROJECT)
    assert run(capsys, "check-binding", good, "--project-id", PROJECT, "--project-number", NUMBER)[0] == 0
    status, out, _ = run(capsys, "check-binding", bad, "--project-id", PROJECT, "--project-number", NUMBER)
    assert status == 1
    assert "project id is used where the project number is needed" in out


def test_a_missing_file_is_a_clean_error_not_a_traceback(capsys):
    status, _, err = run(capsys, "classify", "does-not-exist.txt")
    assert status == 2
    assert err.startswith("error:")


def test_an_unreadable_audit_export_is_a_clean_error(capsys, tmp_path):
    bad = tmp_path / "bad.json"
    bad.write_text("nope")
    status, _, err = run(capsys, "audit", str(bad))
    assert status == 2
    assert "not JSON" in err


def test_a_subcommand_is_required():
    with pytest.raises(SystemExit):
        main([])
