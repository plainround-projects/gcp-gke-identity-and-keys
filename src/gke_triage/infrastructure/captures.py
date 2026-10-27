"""Adapter: capture files on disk, one `.txt` per failure."""

from __future__ import annotations

from collections.abc import Sequence
from pathlib import Path

from gke_triage.application.ports import Capture


class DirectoryCaptureSource:
    """Reads every `*.txt` file of a directory, sorted by name; the file stem is the capture's name."""

    def __init__(self, directory: Path) -> None:
        """`directory` is where the break scripts save the error text of each failure."""
        self._directory = directory

    def captures(self) -> Sequence[Capture]:
        """All captures; raises `FileNotFoundError` when the directory does not exist."""
        if not self._directory.is_dir():
            raise FileNotFoundError(f"no such directory: {self._directory}")
        return [Capture(path.stem, path.read_text(encoding="utf-8")) for path in sorted(self._directory.glob("*.txt"))]
