#!/usr/bin/env python3
"""CLI-Verhalten mit echten Konvertern und drei vollständig isolierten Backends."""
import json
import fcntl
import pty
import select
import termios
import time
import os
from pathlib import Path
import shutil
import subprocess
import tempfile

ROOT = Path(__file__).resolve().parents[1]
NESTED = b'<table><tr><th>Outer</th></tr><tr><td>before<table><tr><th>Inner</th></tr><tr><td>VALUE</td></tr></table>after</td></tr></table>'
with tempfile.TemporaryDirectory(prefix='md-clip-contract-') as tmp:
    base = Path(tmp)
    runtime = base / 'bin'
    runtime.mkdir()
    shutil.copy(ROOT / 'bin/md-clip', runtime / 'md-clip')
    for file in (ROOT / 'lib').iterdir():
        if file.is_file(): shutil.copy(file, runtime / file.name)
    real_pandoc = shutil.which('pandoc')
    assert real_pandoc
    # Produkt priorisiert Bundle-pandoc; dort liegt auch der gesamte Fake-PATH.
    (runtime / 'pandoc').symlink_to(real_pandoc)
    mock = '''#!/usr/bin/env python3
import os,sys,pathlib
name=pathlib.Path(sys.argv[0]).name
args=sys.argv[1:]
b=pathlib.Path(os.environ['MOCK_ROOT'])
if name=='uname': print(os.environ['MOCK_PLATFORM']);sys.exit()
if '--version' in args or '-version' in args:print('mock 1.0');sys.exit()
with (b/'calls').open('a') as f:f.write(name+'\\n')
if os.environ.get('NO_CLIP')=='1':sys.exit(90)
write=name in ('pbcopy','wl-copy') or '-in' in args
if write:(b/'written').write_bytes(sys.stdin.buffer.read());sys.exit()
kind='plain'
if name=='clipboard-html' or 'text/html' in args:kind='html'
if name=='clipboard-rtf' or 'text/rtf' in args or 'application/rtf' in args:kind='rtf'
f=b/kind
if not f.exists():sys.exit(1)
sys.stdout.buffer.write(f.read_bytes())
'''
    for name in ('uname','pbpaste','pbcopy','wl-paste','wl-copy','xclip','clipboard-html','clipboard-rtf'):
        f=runtime/name;f.write_text(mock);f.chmod(0o755)
    env=dict(os.environ, PATH=str(runtime)+':'+os.environ['PATH'], MOCK_ROOT=str(base), MOCK_PLATFORM='Linux')
    def run(args=(), data=None, rc=0):
        p=subprocess.run([str(runtime/'md-clip'),*args],input=data,stdout=subprocess.PIPE,stderr=subprocess.PIPE,env=env,timeout=20)
        assert p.returncode==rc,(args,p.returncode,p.stderr)
        return p
    env['NO_CLIP']='1'
    for raw in (b'abc',b'abc\n\n',b'\x00\xff\r\n',b'\n\n'):
        assert run(['--stdin','--plain'],raw).stdout==raw
    for args in (['--stdin'],['--stdin','--input','x'],['--json'],['--preview'],['--plain','--from','html'],['--input','missing.html']):
        run(args,b'x',2)
    f=base/'file with space.txt';f.write_bytes(b'file\n\n')
    assert run(['--input',str(f)]).stdout==f.read_bytes()
    run(['--stdin','--plain'],b'',1)
    for target in ('gfm','markdown','commonmark'):
        run(['--stdin','--from','html','--to',target],NESTED,3)
        run(['--stdin','--from','html','--to',target],NESTED.replace(b'<table>',b'<TaBlE\n>'),3)
        p=run(['--stdin','--from','html','--to',target],b'<p>[TABLE]</p>')
        assert b'TABLE' in p.stdout
        p=run(['--stdin','--from','html','--to',target],b'<p title="<table>">literal</p><!-- <table><table> -->')
        assert b'literal' in p.stdout
        run(['--stdin','--from','html','--to',target],b'<table><tr><th>A</th><th>B</th></tr><tr><td colspan="2">VALUE</td></tr></table>',3)
    for inner, expected in ((b'<blockquote><p>ONE</p><p>TWO</p></blockquote>', 'ONE TWO'),
                            (b'<ul><li>ONE</li><li>TWO</li></ul>', 'ONE TWO'),
                            (b'<dl><dt>TERM</dt><dd>DEF</dd></dl>', 'TERM DEF'),
                            (b'<pre><code>ONE\nTWO</code></pre>', 'ONE TWO')):
        for target in ('gfm','commonmark'):
            html=b'<table><tr><th>HEAD</th></tr><tr><td>'+inner+b'</td></tr></table>'
            output=run(['--stdin','--from','html','--to',target],html).stdout
            reader=target+('+pipe_tables' if target=='commonmark' else '')
            parsed=json.loads(subprocess.check_output([real_pandoc,'-f',reader,'-t','json'],input=output))
            table=parsed['blocks'][0]
            assert table['t']=='Table',output
            rows=table['c'][4][0][3]
            assert len(rows)==1 and len(rows[0][1])==1,output
            cell=rows[0][1][0][4]
            # Wieder als Plain schreiben: Code und Fließtext haben dieselben Worte.
            doc=dict(parsed,blocks=cell)
            text=subprocess.check_output([real_pandoc,'-f','json','-t','plain'],input=json.dumps(doc).encode()).decode().strip()
            assert text==expected,(output,text)
    doctor=json.loads(run(['--doctor','--json']).stdout)
    assert doctor['stdin'] and doctor['sandbox'] and not doctor['undo']
    assert not (base/'calls').exists(), 'Datei/stdin/Doctor berührten Clipboard'
    # Kein pandoc-Aufruf im Plain-Weg, auch bei vorhandenem defektem Binary.
    (runtime/'pandoc').unlink()
    (runtime/'pandoc').write_text('#!/bin/sh\necho touched > "$MOCK_ROOT/pandoc-called"\nexit 88\n')
    (runtime/'pandoc').chmod(0o755)
    assert run(['--stdin','--plain'],b'bytes\n').stdout==b'bytes\n'
    assert not (base/'pandoc-called').exists()
    broken=json.loads(run(['--doctor','--json']).stdout)
    assert not broken['sandbox'] and not broken['table_filter']
    (runtime/'pandoc').unlink();(runtime/'pandoc').symlink_to(real_pandoc)
    env.pop('NO_CLIP')
    platforms=[('Linux',''),('Linux','mock-wayland')]
    if os.uname().sysname=='Darwin': platforms.append(('Darwin',''))
    for platform,wayland in platforms:
        env.update(MOCK_PLATFORM=platform, WAYLAND_DISPLAY=wayland)
        (base/'plain').write_bytes(b'plain\n\n')
        for target in ('gfm','markdown','commonmark'):
            (base/'html').write_bytes(NESTED)
            (base/'rtf').write_bytes(b'{\\rtf1\\ansi RTF rescue}')
            p=run(['--replace','--to',target]);assert (base/'written').read_bytes()==b'RTF rescue'
            (base/'rtf').unlink()
            p=run(['--replace','--to',target]);assert (base/'written').read_bytes()==b'plain\n\n'
            assert b'Klartext' in p.stderr and not p.stdout
            (base/'written').write_bytes(b'protected')
            run(['--replace','--from','html','--to',target],rc=3)
            assert (base/'written').read_bytes()==b'protected'
        (base/'html').write_bytes(b'<html xmlns:o="urn:schemas-microsoft-com:office:office"><p>HTML rescue</p></html>')
        (base/'rtf').write_bytes(b'{\\rtf1\\ansi }')
        assert b'HTML rescue' in run().stdout
        (base/'html').write_bytes(b'<table><tr><th>A</th></tr><tr><td>one<br>two</td></tr></table>')
        assert b'Struktur vereinfacht' in run().stderr
        assert not run(['--quiet','--verbose']).stderr
        (base/'written').write_bytes(b'protected')
        run(['--preview','--replace'],rc=2)
        assert (base/'written').read_bytes()==b'protected'
        print('OK:',platform,wayland or 'default','Tabellen/Fallback/Schreibschutz')
    # Echte Terminalabfrage, aber ausschließlich auf den Clipboard-Attrappen.
    for answer, expected_rc in ((b'nein\n',4),(b'ja\n',0),(b'\x04',4)):
        (base/'written').write_bytes(b'protected')
        master,slave=pty.openpty()
        def terminal():
            os.setsid()
            fcntl.ioctl(2,termios.TIOCSCTTY,0)
        proc=subprocess.Popen([str(runtime/'md-clip'),'--plain','--replace','--preview'],
                              stdin=subprocess.DEVNULL,stdout=subprocess.PIPE,stderr=slave,
                              env=env,preexec_fn=terminal)
        os.close(slave)
        captured=b'';sent=False;deadline=time.monotonic()+20
        try:
            while time.monotonic()<deadline:
                if select.select([master],[],[],0.1)[0]:
                    try:chunk=os.read(master,65536)
                    except OSError:break
                    if not chunk:break
                    captured+=chunk
                    if not sent and b'[ja/Nein]' in captured:
                        os.write(master,answer);sent=True
                if proc.poll() is not None:break
            assert sent,captured
            assert proc.wait(timeout=2)==expected_rc,captured
            assert proc.stdout.read()==b''
        finally:
            if proc.poll() is None:proc.kill()
            proc.wait();os.close(master)
        expected=(base/'plain').read_bytes() if expected_rc==0 else b'protected'
        assert (base/'written').read_bytes()==expected
    print('OK: Vorschau bestaetigen/ablehnen/EOF im isolierten Terminal')
print('OK: stdin/Datei/Doctor/Klartext-Abhängigkeiten')
