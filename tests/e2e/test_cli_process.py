"""The installed `gke-triage` program as a user runs it: a subprocess, standard input, exit statuses."""

import subprocess
import sys
from pathlib import Path

import pytest

pytestmark = pytest.mark.e2e

FIXTURES = Path(__file__).resolve().parents[1] / "fixtures"
PROGRAM = [sys.executable, "-m", "gke_triage.interfaces.cli"]


def run(*args, stdin=None):
    return subprocess.run([*PROGRAM, *args], input=stdin, capture_output=True, text=True, timeout=60, check=False)


def test_the_lessons_triage_table_comes_out_of_the_captured_error_texts():
    result = run("table", str(FIXTURES))
    assert result.returncode == 0
    rows = [line for line in result.stdout.splitlines() if line.startswith("| ")][2:]
    layers = {row.split(" | ")[2] for row in rows}
    assert {"authorization", "key", "identity", "unknown"} <= layers
    assert any("sa/default" in row for row in rows)


def test_an_error_piped_in_is_classified_as_the_layer_that_failed():
    result = run("classify", "-", stdin=(FIXTURES / "key-disabled.txt").read_text())
    assert result.returncode == 0
    assert "layer:       key" in result.stdout


def test_the_audit_export_exits_1_because_it_holds_denials():
    result = run("audit", str(FIXTURES / "audit-log.json"))
    assert result.returncode == 1
    assert "sa/default" in result.stdout


def test_the_project_id_where_the_number_belongs_is_caught_with_exit_2():
    result = run("principal", "--project-id", "example-sandbox-0000", "--project-number", "example-sandbox-0000")
    assert result.returncode == 2
    assert "projectNumber" in result.stderr
