"""The `gke-triage` command: classify an error, summarize audit denials, build the table, print or check a principal."""

from __future__ import annotations

import argparse
import sys
from collections.abc import Sequence
from pathlib import Path

from gke_triage.application.diagnose import BuildTriageTable, SummarizeDenials, diagnose
from gke_triage.domain.errors import DomainError
from gke_triage.domain.principal import WorkloadPrincipal, check_binding_member
from gke_triage.infrastructure.audit_log import JsonAuditLogSource
from gke_triage.infrastructure.captures import DirectoryCaptureSource


def main(argv: Sequence[str] | None = None) -> int:
    """Run the command; returns the process exit status (0 ok, 1 a problem was found, 2 bad input)."""
    parser = _parser()
    args = parser.parse_args(argv)
    try:
        return int(args.handler(args))
    except (DomainError, OSError) as error:
        print(f"error: {error}", file=sys.stderr)
        return 2


def _parser() -> argparse.ArgumentParser:
    parser = argparse.ArgumentParser(prog="gke-triage", description=__doc__)
    commands = parser.add_subparsers(dest="command", required=True)

    classify = commands.add_parser(
        "classify", help="classify the error text in FILE (or stdin) as identity, authorization or key"
    )
    classify.add_argument("file", nargs="?", default="-")
    classify.set_defaults(handler=_classify)

    audit = commands.add_parser("audit", help="summarize denials in the JSON from `gcloud logging read --format=json`")
    audit.add_argument("file", nargs="?", default="-")
    audit.set_defaults(handler=_audit)

    table = commands.add_parser("table", help="render the triage table from the *.txt files in DIRECTORY")
    table.add_argument("directory", nargs="?", default="captures")
    table.set_defaults(handler=_table)

    principal = commands.add_parser("principal", help="print the IAM principal of a Kubernetes service account")
    principal.add_argument("--project-id", required=True)
    principal.add_argument("--project-number", required=True)
    principal.add_argument("--namespace", default="demo")
    principal.add_argument("--service-account", default="reader-writer")
    principal.set_defaults(handler=_principal)

    check = commands.add_parser(
        "check-binding", help="check that a binding's member uses the project number, not the id"
    )
    check.add_argument("member")
    check.add_argument("--project-id", required=True)
    check.add_argument("--project-number", required=True)
    check.set_defaults(handler=_check_binding)
    return parser


def _read(file: str) -> str:
    return sys.stdin.read() if file == "-" else Path(file).read_text(encoding="utf-8")


def _classify(args: argparse.Namespace) -> int:
    finding = diagnose(_read(args.file))
    print(f"layer:       {finding.layer.value}")
    print(f"cause:       {finding.cause.value}")
    if finding.principal:
        print(f"principal:   {finding.principal}")
    if finding.permission:
        print(f"permission:  {finding.permission}")
    print(f"first check: {finding.first_check}")
    print(f"fix:         {finding.fix}")
    return 0


def _audit(args: argparse.Namespace) -> int:
    summaries = SummarizeDenials(JsonAuditLogSource(_read(args.file))).execute()
    if not summaries:
        print("no denials found")
        return 0
    for summary in summaries:
        denial = summary.denial
        print(f"{summary.count}x  {denial.principal}  {denial.permission}  {denial.resource}")
    return 1


def _table(args: argparse.Namespace) -> int:
    print(BuildTriageTable(DirectoryCaptureSource(Path(args.directory))).execute(), end="")
    return 0


def _principal(args: argparse.Namespace) -> int:
    print(WorkloadPrincipal(args.project_id, args.project_number, args.namespace, args.service_account).uri)
    return 0


def _check_binding(args: argparse.Namespace) -> int:
    problem = check_binding_member(args.member, args.project_id, args.project_number)
    if problem is None:
        print("ok: the member names this project's pool by number")
        return 0
    print(f"problem: {problem.value}")
    return 1


if __name__ == "__main__":
    raise SystemExit(main())
