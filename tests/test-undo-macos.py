#!/usr/bin/env python3
"""Native Undo-Tests mit ausschließlich privater macOS-Zwischenablage."""
import os
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
    try:
        subprocess.run([str(driver), str(helper), str(work)], check=True, timeout=180)
    finally:
        # Ein fehlgeschlagener Test darf keinen Dienst mit Nutzdaten zurücklassen.
        for service in [work / "service"]:
            environment = dict(os.environ, MD_CLIP_TEST_DIRECTORY=str(service))
            subprocess.run([str(helper), "stop"], env=environment,
                           stdout=subprocess.DEVNULL, stderr=subprocess.DEVNULL, timeout=30)
