#!/usr/bin/env python3
"""Doctor: feste Ursachen, Fähigkeiten und keinerlei Clipboard-Operationen."""
import json
import os
from pathlib import Path
import shutil
import subprocess
import sys
import tempfile

ROOT = Path(__file__).resolve().parents[1]
with tempfile.TemporaryDirectory(prefix='md-clip-doctor-') as tmp:
    base = Path(tmp)
    runtime = base / 'bin'
    runtime.mkdir()
    shutil.copy(ROOT / 'bin/md-clip', runtime / 'md-clip')
    for file in (ROOT / 'lib').iterdir():
        if file.is_file(): shutil.copy(file, runtime / file.name)
    mock = '#!' + sys.executable + '\n' + '''import os,sys,pathlib
name=pathlib.Path(sys.argv[0]).name
args=sys.argv[1:]
if name=='uname': print(os.environ['MOCK_PLATFORM']);sys.exit()
with open(os.environ['MOCK_LOG'],'a') as f:f.write(name+' '+repr(args)+'\\n')
if name in ('clipboard-undo','clipboard-undo-linux.py'):
    if args==['status']:
        print('{"version":1,"undo_available":false,"pending_valid":false}');sys.exit(2 if os.environ.get('MOCK_STATUS_FAIL') else 0)
    if args!=['diagnose']:sys.exit(91)
    if os.environ.get('MOCK_DIAG_FAIL'):print('PRIVATE-ERROR',file=sys.stderr);sys.exit(2)
    print(os.environ.get('MOCK_DIAG','ok'));sys.exit()
if name=='pandoc':
    if '--version' in args:
        print('pandoc "quoted"\\\\version\\tcontrol');sys.exit(1 if os.environ.get('MOCK_PANDOC_FAIL') else 0)
    if '--list-input-formats' in args:print('html' if os.environ.get('MOCK_NO_RTF') else 'html\\nrtf');sys.exit()
    if os.environ.get('MOCK_NO_SANDBOX'):sys.exit(2)
    if any('lua-filter' in a for a in args) and os.environ.get('MOCK_NO_FILTER'):sys.exit(2)
    sys.stdin.buffer.read();sys.exit()
if name=='perl':print('5.34.0');sys.exit()
if name=='python3':print('Python 3.12');sys.exit()
if args in (['--version'],['-version']):print('mock 1.0');sys.exit()
print('PRIVATE-CLIPBOARD-CONTENT');sys.exit(91)
'''
    tools = ['uname', 'pandoc', 'perl', 'python3', 'pbpaste', 'pbcopy', 'xclip', 'wl-paste', 'wl-copy',
             'textutil', 'iconv', 'clipboard-html', 'clipboard-rtf', 'clipboard-undo', 'clipboard-undo-linux.py']
    for name in tools:
        path = runtime / name
        path.write_text(mock)
        path.chmod(0o755)
    # Absichtlich nur benötigte Shell-Bordwerkzeuge: fehlende Dependencies dürfen
    # nicht unbemerkt aus dem Host-PATH nachrücken.
    for name in ('bash', 'dirname', 'basename', 'readlink', 'head', 'tr', 'grep'):
        (runtime / name).symlink_to(shutil.which(name))
    env = dict(os.environ, PATH=str(runtime), MOCK_LOG=str(base / 'calls'), MOCK_PLATFORM='Linux')
    env.pop('WAYLAND_DISPLAY', None)

    def run(json_mode=True):
        (base / 'calls').write_text('')
        p = subprocess.run([str(runtime / 'md-clip'), '--doctor', *(['--json'] if json_mode else [])],
                           env=env, capture_output=True, timeout=20)
        assert p.returncode == 0 and not p.stderr, p.stderr
        assert b'PRIVATE-' not in p.stdout
        calls = (base / 'calls').read_text().splitlines()
        for call in calls:
            name = call.split()[0]
            if name in ('pbpaste', 'pbcopy', 'xclip', 'wl-paste', 'wl-copy'):
                assert '--version' in call or '-version' in call, call
            if name in ('clipboard-undo', 'clipboard-undo-linux.py'):
                assert call.endswith("['diagnose']") or call.endswith("['status']"), call
            assert name not in ('clipboard-html', 'clipboard-rtf'), call
        return json.loads(p.stdout) if json_mode else p.stdout.decode()

    platforms = [('Linux', '', 'x11'), ('Linux', 'test-wayland', 'wayland')]
    if os.uname().sysname == 'Darwin': platforms.append(('Darwin', '', 'macos'))
    for platform, wayland, backend in platforms:
        env.update(MOCK_PLATFORM=platform, WAYLAND_DISPLAY=wayland)
        doc = run()
        assert doc['native_preview'] is False
        assert doc['backend'] == backend and doc['diagnostics_version'] == 1
        assert doc['session'] == {'status': 'ready', 'code': 'ok'}
        assert doc['capabilities'] == {'plain_input': True, 'html_conversion': True, 'rtf_conversion': True,
                                       'clipboard_read': True, 'clipboard_replace': True}
        assert not doc['diagnostics']
        assert doc['dependencies']['pandoc']['version'] == 'pandoc "quoted"\\versioncontrol'
        assert 'Fähigkeiten:' in run(False)
        for code, status in [('undo-helper-missing', 'unverified'), ('python-unsupported', 'unverified'),
                             ('local-security-unsupported', 'unverified'), ('runtime-unsafe', 'unavailable'),
                             ('x11-libraries-missing', 'unverified'), ('x11-session-missing', 'unavailable'),
                             ('x11-connect-failed', 'unavailable'), ('x11-xfixes-missing', 'unsupported'),
                             ('wayland-runtime-missing', 'unavailable'), ('wayland-connect-failed', 'unavailable'),
                             ('wayland-data-control-missing', 'unsupported'), ('wayland-seat-unsupported', 'unsupported'),
                             ('macos-session-missing', 'unavailable')]:
            # Fehlender Helfer wird über das Dateisystem erkannt, nicht über dessen Ausgabe.
            env['MOCK_DIAG'] = code
            if code == 'undo-helper-missing':
                helper = runtime / ('clipboard-undo' if platform == 'Darwin' else 'clipboard-undo-linux.py')
                helper.rename(base / 'hidden-helper')
            doc = run()
            assert doc['session'] == {'status': status, 'code': code}, doc
            assert code in [issue['code'] for issue in doc['diagnostics']]
            assert all(issue['message'] and issue['next_step'] for issue in doc['diagnostics'])
            assert not doc['capabilities']['clipboard_replace']
            if code == 'undo-helper-missing': (base / 'hidden-helper').rename(helper)
            env.pop('MOCK_DIAG')
        for value in ('unknown', 'ok\nPRIVATE-CLIPBOARD-CONTENT'):
            env['MOCK_DIAG'] = value
            assert run()['session']['code'] == 'undo-helper-failed'
        env.pop('MOCK_DIAG')
        env['MOCK_DIAG_FAIL'] = '1'
        assert run()['session']['code'] == 'undo-helper-failed'
        env.pop('MOCK_DIAG_FAIL')
        print('OK:', backend, 'Ursachen/JSON/Text ohne Clipboard-Zugriff')

    if os.uname().sysname == 'Darwin':
        env.update(MOCK_PLATFORM='Darwin', WAYLAND_DISPLAY='')
        preview = base / 'helpers' / 'md-clip-preview'
        preview.parent.mkdir()
        preview.write_text('#!/bin/sh\nexit 91\n')
        preview.chmod(0o755)
        assert run()['native_preview'] is True
        assert 'Fenstervorschau: verfügbar;' in run(False)
        env['MOCK_STATUS_FAIL'] = '1'
        doc = run()
        assert doc['native_preview'] is False
        assert 'Fenstervorschau: nicht verfügbar;' in run(False)
        assert 'preview-status-unavailable' in [item['code'] for item in doc['diagnostics']]
        env.pop('MOCK_STATUS_FAIL')
        preview.unlink()
        for tool, issue in [('textutil', 'textutil-missing'), ('clipboard-html', 'html-helper-missing'),
                            ('clipboard-rtf', 'rtf-helper-missing')]:
            (runtime / tool).rename(base / 'hidden-tool')
            doc = run()
            assert issue in [item['code'] for item in doc['diagnostics']], doc
            if tool == 'textutil': assert not doc['capabilities']['rtf_conversion']
            (base / 'hidden-tool').rename(runtime / tool)

    env.update(MOCK_PLATFORM='Linux', WAYLAND_DISPLAY='')
    for flag, issue in [('MOCK_PANDOC_FAIL', 'pandoc-unusable'), ('MOCK_NO_SANDBOX', 'pandoc-no-sandbox'),
                        ('MOCK_NO_FILTER', 'table-filter-unavailable'), ('MOCK_NO_RTF', 'pandoc-no-rtf')]:
        env[flag] = '1'
        doc = run()
        assert issue in [item['code'] for item in doc['diagnostics']], doc
        env.pop(flag)
    for tool, issue in [('pandoc', 'pandoc-missing'), ('perl', 'perl-missing'), ('python3', 'python-missing'),
                        ('xclip', 'clipboard-read-tool-missing')]:
        (runtime / tool).rename(base / 'hidden-tool')
        doc = run()
        assert issue in [item['code'] for item in doc['diagnostics']], doc
        assert doc['capabilities']['plain_input']
        (base / 'hidden-tool').rename(runtime / tool)
    env['WAYLAND_DISPLAY'] = 'test-wayland'
    (runtime / 'wl-copy').rename(base / 'hidden-tool')
    doc = run()
    assert not doc['capabilities']['clipboard_replace'] and doc['capabilities']['clipboard_read']
    assert 'clipboard-write-tool-missing' in [item['code'] for item in doc['diagnostics']]
print('OK: Fehlende Werkzeuge und defekte Konverter/Helfer werden getrennt gemeldet')
