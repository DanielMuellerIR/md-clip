#!/usr/bin/env python3
"""Native Vorschau: standardmäßig ohne Fenster; --ui nur als Hintergrundtest."""
import argparse
import json
import os
from pathlib import Path
import platform
import plistlib
import shutil
import signal
import subprocess
import sys
import tempfile
import time

parser = argparse.ArgumentParser()
parser.add_argument('--ui', action='store_true', help='Selbstbeendende Ansichten ohne Fokusübernahme prüfen')
args = parser.parse_args()
if platform.system() != 'Darwin':
    print('SKIP: native Vorschau benötigt macOS')
    raise SystemExit(0)
ROOT = Path(__file__).resolve().parents[1]
with tempfile.TemporaryDirectory(prefix='md-clip-preview-tests-', dir='/private/tmp') as tmp:
    work = Path(tmp)
    binary = work / 'preview-tests'
    subprocess.run(['swiftc', '-D', 'TEST', '-target', platform.machine() + '-apple-macos14.0',
                    str(ROOT / 'helpers/md-clip-preview.swift'), '-o', str(binary)], check=True)
    invalid = subprocess.run([str(binary)],capture_output=True,timeout=5)
    assert invalid.returncode == 64 and b'UTF-8' in invalid.stderr
    helper = work / 'helper with space'
    data = work / 'status.json'
    calls = work / 'calls'
    cancelled = work / 'cancelled'
    helper.write_text('#!' + os.path.realpath(sys.executable) + '\n' + '''import json,os,pathlib,sys,time,signal
root=pathlib.Path(os.environ['PREVIEW_TEST_ROOT'])
with (root/'calls').open('a') as f:f.write(json.dumps(sys.argv[1:])+'\\n')
if sys.argv[1:]==['cancel','fixed']:(root/'cancelled').write_text('yes');sys.exit()
assert sys.argv[1:]==['status','fixed']
if (root/'delay').exists():
    (root/'status.pid').write_text(str(os.getpid()))
    if (root/'ignore-term').exists():signal.signal(signal.SIGTERM,signal.SIG_IGN)
    time.sleep(30)
sys.stdout.buffer.write((root/'status.json').read_bytes())
sys.exit(2 if (root/'fail').exists() else 0)
''')
    helper.chmod(0o755)
    env = dict(os.environ, PREVIEW_TEST_ROOT=str(work))
    for key in ('MD_CLIP_TEST_PREVIEW_BACKGROUND','MD_CLIP_TEST_PREVIEW_EVIDENCE','MD_CLIP_TEST_PREVIEW_ACTION'):env.pop(key,None)
    for payload, expected in (({'version':1,'undo_available':True,'pending_valid':True},0),
                              ({'version':99,'undo_available':True,'pending_valid':True},2), ({},2)):
        data.write_text(json.dumps(payload))
        result = subprocess.run([str(binary),'--test-status',str(helper),'fixed'],env=env,capture_output=True,timeout=5)
        assert result.returncode == expected, result.stderr
        if expected == 0: assert json.loads(result.stdout) == payload
    data.write_bytes(b'not JSON')
    assert subprocess.run([str(binary),'--test-status',str(helper),'fixed'],env=env,capture_output=True,timeout=5).returncode == 2
    data.write_text(json.dumps({'version':1,'undo_available':True,'pending_valid':True}))
    (work/'delay').touch()
    started = time.monotonic()
    assert subprocess.run([str(binary),'--test-status',str(helper),'fixed'],env=env,capture_output=True,timeout=5).returncode == 2
    assert time.monotonic()-started < 4
    (work/'ignore-term').touch()
    started = time.monotonic()
    result = subprocess.run([str(binary),'--test-cancel-status',str(helper),'fixed'],env=env,capture_output=True,timeout=5)
    assert result.returncode == 0 and time.monotonic()-started < 2, result.stderr
    status_pid = int((work/'status.pid').read_text())
    try:os.kill(status_pid,0)
    except ProcessLookupError:pass
    else:raise AssertionError('Abbruch ließ einen Statusprozess zurück')
    (work/'ignore-term').unlink()
    (work/'delay').unlink()
    body = work / 'body.txt';notes = work / 'notes.txt';notes.write_text('Quelle: Klartext')
    body.write_bytes(b'\xff')
    for arguments in ([str(body),str(notes),str(helper),'fixed'],):
        result = subprocess.run([str(binary),*arguments],env=env,capture_output=True,timeout=5)
        assert result.returncode == 64 and b'UTF-8' in result.stderr
    with body.open('wb') as out:out.truncate(64*1024*1024+1)
    assert subprocess.run([str(binary),str(body),str(notes),str(helper),'fixed'],env=env,capture_output=True,timeout=5).returncode == 64
    print('OK: native Status-IPC, Schema, Fehler, Zeitlimit, UTF-8 und Größenprüfung ohne GUI')
    native_undo = work / 'native-undo'
    integration = work / 'preview-integration'
    for source, target, flags in ((ROOT/'helpers/clipboard-undo.swift',native_undo,['-O','-D','TEST']),
                                  (ROOT/'tests/test-preview-integration.swift',integration,[])):
        subprocess.run(['swiftc','-target',platform.machine()+'-apple-macos14.0',*flags,str(source),'-o',str(target)],check=True)
    runtime = work / 'runtime'
    (runtime/'bin').mkdir(parents=True);(runtime/'helpers').mkdir()
    shutil.copy2(ROOT/'bin/md-clip',runtime/'bin/md-clip')
    cat = runtime/'bin/cat'
    cat.write_text('#!/bin/sh\nif [ -n "${MD_CLIP_TEST_IO_PID:-}" ]; then printf \'%s\\n\' "$$" > "$MD_CLIP_TEST_IO_PID"; fi\nexec /bin/cat "$@"\n')
    cat.chmod(0o755)
    shutil.copytree(ROOT/'lib',runtime/'lib')
    (runtime/'helpers/clipboard-undo').symlink_to(native_undo)
    (runtime/'helpers/md-clip-preview').symlink_to(binary)
    integration_root = work / 'integration'
    def run_integration(ui=False):
        try:
            subprocess.run([str(integration),str(native_undo),str(runtime/'bin/md-clip'),str(integration_root),*(['--ui'] if ui else [])],
                           env=env,check=True,timeout=150)
        finally:
            subprocess.run([str(native_undo),'stop'],env=dict(env,MD_CLIP_TEST_DIRECTORY=str(integration_root/'service')),
                           stdout=subprocess.DEVNULL,stderr=subprocess.DEVNULL,timeout=30)
    if not args.ui:
        run_integration()
        print('INFO: Ansichten separat mit --ui auf einem entsperrten Test-Mac prüfen')
        raise SystemExit(0)

    if os.stat('/dev/console').st_uid != os.getuid():
        print('BLOCKIERT: Test benötigt die eigene grafische Konsolensitzung')
        raise SystemExit(2)
    ioreg = subprocess.check_output(['/usr/sbin/ioreg','-a','-n','Root','-d','1','-l'])
    def locked_values(value):
        if isinstance(value,dict):
            return [value['IOConsoleLocked']] if 'IOConsoleLocked' in value else sum((locked_values(v) for v in value.values()),[])
        if isinstance(value,list):return sum((locked_values(v) for v in value),[])
        return []
    locked = locked_values(plistlib.loads(ioreg))
    if not locked or any(locked):
        print('BLOCKIERT: Test-Mac ist gesperrt oder Sperrzustand nicht prüfbar')
        raise SystemExit(2)
    run_integration(ui=True)
    artifacts = work / 'artifacts'
    subprocess.run([str(binary),'--self-test',str(artifacts)],env=env,check=True,timeout=55)
    evidence = json.loads((artifacts/'result.json').read_text())
    assert evidence['scrolled'] and evidence['end_marker_visible'] and evidence['focus_preserved']
    assert evidence['keyboard_actions'] == ['command-return','command-q','command-z']
    assert len(list(artifacts.glob('*.png'))) == 5
    if os.environ.get('MD_CLIP_PREVIEW_ARTIFACTS'):
        shutil.copytree(artifacts,os.environ['MD_CLIP_PREVIEW_ARTIFACTS'],dirs_exist_ok=True)
    body.write_text('# Eigene Vorschau\n\nKeine Host-Zwischenablage.\n')
    notes.write_text('Quelle: Test\nZielformat: gfm')
    observed = work / 'observed.json'
    env.update(MD_CLIP_TEST_PREVIEW_BACKGROUND='1',MD_CLIP_TEST_PREVIEW_EVIDENCE=str(observed))
    command = [str(binary),str(body),str(notes),str(helper),'fixed']
    def status(pending=True,undo=True):
        data.write_text(json.dumps({'version':1,'undo_available':undo,'pending_valid':pending}))
    def wait_observation(predicate):
        deadline = time.monotonic()+10
        while time.monotonic()<deadline:
            if observed.exists():
                value = json.loads(observed.read_text())
                assert value['focus_preserved'] and value['visible']
                if predicate(value):return value
            time.sleep(.05)
        raise AssertionError('Native Ansicht erreicht den erwarteten Zustand nicht')
    status()
    process = subprocess.Popen(command,env=env,stdout=subprocess.PIPE,stderr=subprocess.PIPE)
    try:
        wait_observation(lambda value:value['accept'] and value['undo'])
        status(False,False)
        wait_observation(lambda value:not value['accept'] and not value['undo'])
        data.write_text('{}')
        wait_observation(lambda value:'fehlgeschlagen' in value['status'])
        process.terminate()
        out,error = process.communicate(timeout=5)
        assert process.returncode == 4 and cancelled.exists(), (process.returncode,error)
    finally:
        if process.poll() is None:process.kill();process.communicate()
    print('OK: echte native Statusaktualisierung, deaktivierte Controls und Signal-Stornierung ohne Fokus')

    observed.unlink();cancelled.unlink();status()
    spawner = work / 'spawner.py'
    pid_file = work / 'child.pid'
    spawner.write_text('import subprocess,os,pathlib,time\n' +
                       'p=subprocess.Popen('+repr(command)+',env=os.environ,stdout=subprocess.DEVNULL,stderr=subprocess.DEVNULL)\n'+
                       'pathlib.Path('+repr(str(pid_file))+').write_text(str(p.pid))\ntime.sleep(60)\n')
    parent = subprocess.Popen([sys.executable,str(spawner)],env=env)
    child = None
    try:
        wait_observation(lambda value:value['accept'])
        child = int(pid_file.read_text())
        parent.kill();parent.wait()
        deadline=time.monotonic()+5
        while not cancelled.exists() and time.monotonic()<deadline:time.sleep(.05)
        assert cancelled.exists(), 'Elternende storniert die eigene Vorbereitung nicht'
        while time.monotonic()<deadline:
            try:os.kill(child,0)
            except ProcessLookupError:break
            time.sleep(.05)
        else:raise AssertionError('Native Vorschau blieb nach Elternende aktiv')
    finally:
        if parent.poll() is None:parent.kill();parent.wait()
        if child:
            try:os.kill(child,signal.SIGKILL)
            except ProcessLookupError:pass
    print('OK: unerwartetes Elternende beendet Vorschau und storniert Token ohne Fokus')
