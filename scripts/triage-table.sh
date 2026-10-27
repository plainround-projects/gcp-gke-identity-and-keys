#!/usr/bin/env bash
# Step 6: the triage table from the error texts the break scripts captured. Copy the output into your README.
set -euo pipefail
ROOT="$(cd "$(dirname "$0")/.." && pwd)"
"$ROOT/.venv/bin/gke-triage" table "$ROOT/captures"
