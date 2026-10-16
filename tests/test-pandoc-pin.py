#!/usr/bin/env python3
"""Gemeinsamer Bundle-Pin, Archivprüfung und atomare Testbereitstellung."""
import hashlib
import os
from pathlib import Path
import re
import shutil
import subprocess
import sys
import tempfile
import zipfile

ROOT = Path(__file__).resolve().parents[1]
pin = (ROOT / 'wrappers/pandoc-pin.sh').read_text()
version = re.findall(r'^PANDOC_VERSION="([0-9.]+)"$', pin, re.M)
assert len(version) == 1
version = version[0]
assert 'source "$SCRIPT_DIR/pandoc-pin.sh"' in (ROOT / 'wrappers/build-app-bundled.sh').read_text()
with tempfile.TemporaryDirectory(prefix='md-clip-pin-') as tmp:
    root = Path(tmp)
    for name in ('tests', 'wrappers', 'tools'): (root / name).mkdir()
    shutil.copy(ROOT / 'tests/prepare-bundled-pandoc.sh', root / 'tests/')
    shutil.copy(ROOT / 'wrappers/verified-cache.sh', root / 'wrappers/')
    binary = ('#!/bin/sh\nprintf "pandoc ' + version + '\\n"\n').encode()
    archive = root / 'fixture.zip'
    with zipfile.ZipFile(archive, 'w') as z:
        z.writestr('pandoc-' + version + '-arm64/bin/pandoc', binary)
    digest = hashlib.sha256(archive.read_bytes()).hexdigest()
    (root / 'wrappers/pandoc-pin.sh').write_text(re.sub(r'^PANDOC_ZIP_SHA256="[a-f0-9]+"$',
                                                       'PANDOC_ZIP_SHA256="' + digest + '"', pin, flags=re.M))
    uname = root / 'tools/uname'
    uname.write_text('#!/bin/sh\n[ "$1" = -s ] && { echo "$MOCK_SYSTEM"; exit; }\necho "$MOCK_ARCH"\n')
    uname.chmod(0o755)
    curl = root / 'tools/curl'
    curl.write_text('#!' + sys.executable + '\n' + """import os,sys,pathlib
args=sys.argv[1:]
output=pathlib.Path(args[args.index('--output')+1])
output.write_bytes(b'corrupt' if os.environ.get('MOCK_BAD_ARCHIVE') else pathlib.Path(os.environ['MOCK_ARCHIVE']).read_bytes())
""")
    curl.chmod(0o755)
    env = dict(os.environ, PATH=str(root / 'tools') + ':' + os.environ['PATH'],
               MOCK_SYSTEM='Darwin', MOCK_ARCH='arm64', MOCK_ARCHIVE=str(archive))
    destination = root / 'result with space'
    command = ['bash', str(root / 'tests/prepare-bundled-pandoc.sh'), str(destination)]
    for system, arch in (('Linux', 'x86_64'), ('Darwin', 'x86_64')):
        env.update(MOCK_SYSTEM=system, MOCK_ARCH=arch)
        assert subprocess.run(command, env=env, capture_output=True).returncode == 2
        assert not destination.exists()
    env.update(MOCK_SYSTEM='Darwin', MOCK_ARCH='arm64')
    prepared = subprocess.run(command, env=env, capture_output=True)
    assert prepared.returncode == 0, prepared.stderr
    assert (destination / 'pandoc').read_bytes() == binary
    cached = destination / ('pandoc-' + version + '-arm64-macOS.zip')
    cached.write_bytes(b'corrupt cache')
    env['MOCK_BAD_ARCHIVE'] = '1'
    rejected = subprocess.run(command, env=env, capture_output=True)
    assert rejected.returncode != 0 and b'SHA-256' in rejected.stderr
    assert (destination / 'pandoc').read_bytes() == binary
    env.pop('MOCK_BAD_ARCHIVE')
    with zipfile.ZipFile(archive, 'w') as z:
        z.writestr('pandoc-' + version + '-arm64/bin/pandoc', b'#!/bin/sh\nprintf "pandoc 0.0\\n"\n')
    bad_digest = hashlib.sha256(archive.read_bytes()).hexdigest()
    (root / 'wrappers/pandoc-pin.sh').write_text(re.sub(r'^PANDOC_ZIP_SHA256="[a-f0-9]+"$',
                                                       'PANDOC_ZIP_SHA256="' + bad_digest + '"', pin, flags=re.M))
    rejected = subprocess.run(command, env=env, capture_output=True)
    assert rejected.returncode != 0 and b'Falsche pandoc-Version' in rejected.stderr
    assert (destination / 'pandoc').read_bytes() == binary
    assert not list(destination.glob('.extract.*')) and not list(destination.glob('*.download.*'))
    outside = root / 'outside'
    outside.write_bytes(b'protected')
    (destination / 'pandoc').unlink()
    (destination / 'pandoc').symlink_to(outside)
    rejected = subprocess.run(command, env=env, capture_output=True)
    assert rejected.returncode == 2 and outside.read_bytes() == b'protected'
    assert (destination / 'pandoc').is_symlink()
print('OK: gemeinsamer Bundle-Pin, Plattform, SHA-256 und vorheriger Konverter geschützt')
