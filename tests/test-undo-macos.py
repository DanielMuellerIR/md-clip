#!/usr/bin/env python3
"""Native Undo-Tests mit ausschließlich privater macOS-Zwischenablage."""
import os
import json
from pathlib import Path
import platform
import subprocess
import tempfile

if platform.system() != "Darwin":
    print("SKIP: native Undo-Tests benötigen macOS")
    raise SystemExit(0)
root = Path(__file__).resolve().parents[1]
with tempfile.TemporaryDirectory(prefix="md-clip-undo-tests-", dir="/private/tmp") as work:
    work = Path(work)
    helper = work / "clipboard-undo"
    driver = work / "undo-tests"
    cache = work / "module-cache"
    for source, binary, flags in [
        (root / "helpers/clipboard-undo.swift", helper, ["-D", "TEST"]),
        (root / "tests/test-undo-macos.swift", driver, []),
    ]:
        subprocess.run(["swiftc", "-O" if binary == helper else "-Onone", "-module-cache-path", str(cache), *flags,
                        str(source), "-o", str(binary)], check=True)
    diagnosis_directory = work / "diagnosis-only"
    diagnosis = subprocess.run([str(helper), "diagnose"], capture_output=True, timeout=10,
                               env=dict(os.environ, MD_CLIP_TEST_DIRECTORY=str(diagnosis_directory),
                                        MD_CLIP_TEST_PASTEBOARD="md-clip-doctor-private-test"))
    assert diagnosis.returncode == 0 and diagnosis.stdout.strip() in (b"ok", b"macos-session-missing"), diagnosis.stderr
    assert not diagnosis_directory.exists(), "Diagnose erzeugt keinen Dienstordner"
    print("OK: native macOS-Diagnose ohne Dienststart")
    status = subprocess.run([str(helper), "status", "unused"], capture_output=True, timeout=10,
                            env=dict(os.environ, MD_CLIP_TEST_DIRECTORY=str(diagnosis_directory)))
    assert status.returncode == 0 and json.loads(status.stdout) == {"version": 1, "undo_available": False, "pending_valid": False}, status.stderr
    assert not diagnosis_directory.exists()
    print("OK: frischer macOS-Status ohne Dienstordner")
    try:
        subprocess.run([str(driver), str(helper), str(work)], check=True, timeout=180)
    finally:
        # Ein fehlgeschlagener Test darf keinen Dienst mit Nutzdaten zurücklassen.
        for service in [work / "service"]:
            environment = dict(os.environ, MD_CLIP_TEST_DIRECTORY=str(service))
            subprocess.run([str(helper), "stop"], env=environment,
                           stdout=subprocess.DEVNULL, stderr=subprocess.DEVNULL, timeout=30)
