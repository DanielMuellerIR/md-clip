"""Bereitet eine isolierte Kopie der CLI und ihrer Laufzeitressourcen vor."""

from __future__ import annotations

from pathlib import Path
import subprocess

PROJECT_ROOT = Path(__file__).resolve().parents[2]


def stage_runtime(bin_dir: Path, lib_dir: Path | None = None) -> None:
    subprocess.run(
        ["bash", str(PROJECT_ROOT / "wrappers/stage-runtime.sh"), str(PROJECT_ROOT),
         str(bin_dir), str(lib_dir or bin_dir)],
        check=True,
    )
