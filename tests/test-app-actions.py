#!/usr/bin/env python3
"""App-Aktionen über den echten Launcher, ohne GUI oder Host-Clipboard."""
import json
import os
from pathlib import Path
import shutil
import subprocess
import sys
import tempfile
import time

ROOT = Path(__file__).resolve().parents[1]
with tempfile.TemporaryDirectory(prefix='md-clip-actions-') as tmp:
    base = Path(tmp).resolve()
    app = base / 'Applications' / "md Clip O'Neil $(touch NIE).app"
    macos = app / 'Contents/MacOS'
    runtime = app / 'Contents/Resources/bin'
    tools = base / 'tools'
    for path in (macos, runtime, tools): path.mkdir(parents=True)
    launcher = macos / 'md-clip'
    source = (ROOT / 'wrappers/launcher.sh').read_text()
    # Nur der feste Installationspfad wird isoliert, die Launcher-Logik bleibt echt.
    source = source.replace('SYSTEM_CLI="/usr/local/bin/md-clip"', 'SYSTEM_CLI="$MOCK_SYSTEM_CLI"')
    launcher.write_text(source)
    launcher.chmod(0o755)
    mock = '#!' + os.path.realpath(sys.executable) + '\n' + '''import os,sys,pathlib,json
name=pathlib.Path(sys.argv[0]).name
base=pathlib.Path(os.environ['MOCK_ROOT'])
if name=='md-clip':
    (base/'cli').write_text(json.dumps(sys.argv[1:]))
    print('native failure detail',file=sys.stderr) if os.environ.get('MOCK_STATUS') else None
    sys.exit(int(os.environ.get('MOCK_STATUS') or '0'))
if name=='md-clip-updater':
    (base/'updater').write_text(json.dumps(sys.argv[1:]));sys.exit()
if name=='osascript':
    source=sys.stdin.read()
    (base/'dialog-source').write_text(source)
    text=os.environ.get('MD_CLIP_DIALOG_TEXT','')
    kind=os.environ.get('MD_CLIP_DIALOG_KIND','setup')
    (base/'dialog').write_text(json.dumps([kind,text]))
    print('Später');sys.exit()
if name=='defaults':
    (base/'defaults').write_text(json.dumps(sys.argv[1:]));print('0');sys.exit()
sys.exit(91)
'''
    for path in (runtime / 'md-clip', macos / 'md-clip-updater', tools / 'osascript', tools / 'defaults'):
        path.write_text(mock);path.chmod(0o755)
    env = dict(os.environ, HOME=str(base), MOCK_ROOT=str(base), MOCK_SYSTEM_CLI=str(base / 'system/md-clip'),
               PATH=str(tools) + ':' + os.environ['PATH'])
    env.pop('MD_CLIP_LAUNCHER_SOURCE_ONLY', None)

    def run(args, status=0, cli_status=0):
        for name in ('cli','updater','dialog','defaults','dialog-source'):
            (base / name).unlink(missing_ok=True)
        env['MOCK_STATUS'] = str(cli_status) if cli_status else ''
        p = subprocess.run([str(launcher), *args], env=env, capture_output=True, timeout=20)
        assert p.returncode == status, (args,p.returncode,p.stderr)
        return p

    for args in ([], ['--convert'], ['-psn_0_12345']):
        run(args,status=7,cli_status=7)
        assert json.loads((base/'cli').read_text()) == ['--replace','--notify']
        assert json.loads((base/'dialog').read_text())[0] == 'setup'
        deadline = time.monotonic()+2
        while not (base/'updater').exists() and time.monotonic()<deadline: time.sleep(.01)
        assert json.loads((base/'updater').read_text()) == ['--background']
    for status in (0,1,2,3):
        run(['--undo'],status=status,cli_status=status)
        assert json.loads((base/'cli').read_text()) == ['--undo','--notify']
        assert not (base/'defaults').exists() and not (base/'updater').exists()
        if status:
            kind, message = json.loads((base/'dialog').read_text())
            assert kind == 'error' and 'native failure detail' in message
            assert ('zehn Minuten' in message) == (status == 1)
        else: assert not (base/'dialog').exists()
    for status in (0,4,3):
        run(['--preview'],status=status,cli_status=status)
        assert json.loads((base/'cli').read_text()) == ['--replace','--preview-window','--notify']
        assert not (base/'defaults').exists() and not (base/'updater').exists()
        assert (base/'dialog').exists() == (status == 3)
    for args in (['--help'], ['-h']):
        run(args)
        kind, message = json.loads((base/'dialog').read_text())
        assert kind == 'info' and '--undo' in message and 'open -n' in message
        assert not any((base/name).exists() for name in ('cli','defaults','updater'))
    for args in (['--unknown'], ['--undo','--convert'], ['--help','extra'], ['-psn_1_bad'], ['$(touch NIE)']):
        run(args,status=2)
        assert not any((base/name).exists() for name in ('cli','defaults','updater'))
        assert json.loads((base/'dialog').read_text())[0] == 'error'
    (runtime/'md-clip').unlink()
    run(['--help'])
    assert json.loads((base/'dialog').read_text())[0] == 'info'
    for args in ([],['--undo']):
        run(args,status=2)
        assert 'unvollständig' in json.loads((base/'dialog').read_text())[1]
        assert not (base/'updater').exists()
    assert not (base/'NIE').exists() and not (ROOT/'NIE').exists()
print('OK: App-Konvertieren/Undo/Hilfe, Erststart, Fehler, Argumente und problematische Pfade')
