# Changelog

All notable changes to this project are recorded here. The format follows [Keep a Changelog](https://keepachangelog.com/en/1.1.0/) and the project uses [Semantic Versioning](https://semver.org/).

## [Unreleased]

### Added

- Drawn architecture and flow figures in `docs/diagrams/`, light and dark, shown in the README.

### Fixed

- ARCHITECTURE.md and README now match the code where they disagreed (see the drawn figures).


## [0.1.0] - 2026-10-27

### Added

- Terraform: six modules and a `lab` environment (APIs, VPC, GKE Autopilot, KMS key, encrypted bucket with the pod's role, Cloud Storage data-access audit logs), native tests with a mock provider, tflint and checkov.
- Kustomize manifests for the keyless pod, a network policy and the wrong-identity overlay for break one.
- `gke-triage`: classify an error text as identity, authorization or key, summarize audit denials, render the triage table, build and check the workload identity principal. Layered, typed, tested on the lesson's error texts.
- The lesson's runbook as scripts, and a CI workflow.
- `tech/`: 38 technology notes and an index, one file per language, tool, service and file format, for a reader new to all of them.
