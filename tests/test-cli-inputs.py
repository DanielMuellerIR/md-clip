#!/usr/bin/env python3
"""CLI-Verhalten mit echten Konvertern und drei vollständig isolierten Backends."""
import json
import sys
import fcntl
import pty
import select
import signal
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
    mock = '#!' + os.path.realpath(sys.executable) + '\n' + '''import os,sys,pathlib
name=pathlib.Path(sys.argv[0]).name
args=sys.argv[1:]
b=pathlib.Path(os.environ['MOCK_ROOT'])
with (b/'interpreters').open('a') as f:f.write(os.path.realpath(sys.executable)+'\\n')
if name=='uname': print(os.environ['MOCK_PLATFORM']);sys.exit()
undo=name in ('clipboard-undo','clipboard-undo-linux.py')
if undo and args==['available']:sys.exit()
if undo and args==['diagnose']:print('ok');sys.exit()
if undo and args==['status']:sys.exit(1 if os.environ.get('UNDO_FAIL_STATUS') else 0)
if '--version' in args or '-version' in args:print('mock 1.0');sys.exit()
with (b/'calls').open('a') as f:f.write(name+'\\n')
if os.environ.get('NO_CLIP')=='1':sys.exit(90)
if undo:
    with (b/'undo-calls').open('a') as f:f.write(args[0]+'\\n')
    if args[0]=='prepare':
        if os.environ.get('UNDO_FAIL_PREPARE'):sys.exit(1)
        print('mock-token');sys.exit()
    if args[0]=='cancel':
        if os.environ.get('UNDO_PAUSE_CANCEL'):
            (b/'cancel-start').write_text(str(os.getpid()))
            import time
            time.sleep(1)
        sys.exit()
    if args[0]=='replace':
        if os.environ.get('UNDO_FAIL_REPLACE'):sys.exit(1)
        (b/'written').write_bytes(sys.stdin.buffer.read());sys.exit()
    if args[0]=='undo':sys.exit(0 if os.environ.get('UNDO_SUCCESS') else 1)
write=name in ('pbcopy','wl-copy') or '-in' in args
if write:(b/'written').write_bytes(sys.stdin.buffer.read());sys.exit()
kind='plain'
if name=='clipboard-html' or 'text/html' in args:kind='html'
if name=='clipboard-rtf' or 'text/rtf' in args or 'application/rtf' in args:kind='rtf'
f=b/kind
if not f.exists():sys.exit(1)
sys.stdout.buffer.write(f.read_bytes())
'''
    for name in ('uname','pbpaste','pbcopy','wl-paste','wl-copy','xclip','clipboard-html','clipboard-rtf','clipboard-undo','clipboard-undo-linux.py'):
        f=runtime/name;f.write_text(mock);f.chmod(0o755)
    # Ein zufälliges python3 im Produkt-PATH darf die Testattrappen nicht übernehmen.
    decoy=runtime/'python3'
    decoy.write_text('#!/bin/sh\n[ "$1" = --version ] && { echo "Python 3.test"; exit 0; }\necho unwanted > "$MOCK_ROOT/unwanted-interpreter"\nexit 92\n')
    decoy.chmod(0o755)
    cat_mock=runtime/'cat'
    cat_mock.write_text('#!/bin/sh\nif [ "${MOCK_TRACK_CAT:-}" = 1 ]; then printf \'%s\\n\' "$$" > "$MOCK_ROOT/io-cat-pid"; fi\nexec /bin/cat "$@"\n')
    cat_mock.chmod(0o755)
    env=dict(os.environ, PATH=str(runtime)+':'+os.environ['PATH'], MOCK_ROOT=str(base), MOCK_PLATFORM='Linux')
    def run(args=(), data=None, rc=0):
        p=subprocess.run([str(runtime/'md-clip'),*args],input=data,stdout=subprocess.PIPE,stderr=subprocess.PIPE,env=env,timeout=20)
        assert p.returncode==rc,(args,p.returncode,p.stderr)
        return p
    def undo_calls():
        path=base/'undo-calls'
        calls=path.read_text().splitlines() if path.exists() else []
        path.unlink(missing_ok=True)
        return calls
    env['NO_CLIP']='1'
    for raw in (b'abc',b'abc\n\n',b'\x00\xff\r\n',b'\n\n',br'{\rtf1 literal}'+b'\x00\xff\n'):
        assert run(['--stdin','--plain'],raw).stdout==raw
        assert run(['--stdin','--plain','--strict'],raw).stdout==raw
    for args in (['--stdin'],['--stdin','--input','x'],['--json'],['--preview'],['--plain','--from','html'],['--input','missing.html']):
        run(args,b'x',2)
    run(['--doctor','--strict'],rc=2)
    for raw in (b'plain tagged as RTF', b'<p>HTML tagged as RTF</p>',
                br'{\rtf10\ansi wrong version}', br'{\rtf1broken}'):
        for target in ('gfm','markdown','commonmark'):
            invalid=run(['--stdin','--from','rtf','--to',target],raw,3)
            assert not invalid.stdout and b'RTF-Kopf' in invalid.stderr
    wrong_rtf = base/'RTF source with space.rtf'
    wrong_rtf.write_bytes(b'plain tagged as RTF\n\n')
    assert b'RTF-Kopf' in run(['--input',str(wrong_rtf)],rc=3).stderr
    assert run(['--input',str(wrong_rtf),'--plain']).stdout == wrong_rtf.read_bytes()
    for args in (['--preview-window'], ['--undo','--preview-window'],
                 ['--doctor','--preview-window'], ['--replace','--preview-window','--preview']):
        run(args,rc=2)
    for args in (['--images'], ['--images','invalid'], ['--doctor','--images','alt'],
                 ['--tables'], ['--tables','invalid'], ['--doctor','--tables','text']):
        run(args,rc=2)
    f=base/'file with space.txt';f.write_bytes(b'file\n\n')
    assert run(['--input',str(f)]).stdout==f.read_bytes()
    run(['--stdin','--plain'],b'',1)
    # Ein nur lesbarer stdout muss als Ausgabefehler (3) gemeldet werden.
    with (base/'file with space.txt').open('rb') as readonly:
        failed=subprocess.run([str(runtime/'md-clip'),'--stdin','--plain'],
                              input=b'x',stdout=readonly,stderr=subprocess.PIPE,env=env,timeout=20)
    assert failed.returncode==3,(failed.returncode,failed.stderr)
    assert b'stdout' in failed.stderr
    invisible_html=[b'<p><strong>&lrm;</strong></p>',
                    b'<p><em>&#x200B;</em></p>',b'<p><strong>&nbsp;</strong></p>',
                    b'<blockquote><p><em>&rlm;</em></p></blockquote>',
                    b'<pre><code>&#x2061;</code></pre>',
                    b'<html><head><title>Title</title></head><body><b>&lrm;</b></body></html>']
    for target in ('gfm','markdown','commonmark'):
        for html in invisible_html:
            run(['--stdin','--from','html','--to',target],html,3)
        for html in (b'<p><strong>visible</strong></p>',b'<p><code>**</code></p>',
                     b'<img src="image.png">',b'<hr>'):
            assert run(['--stdin','--from','html','--to',target],html).stdout.strip()
        run(['--stdin','--from','html','--to',target],NESTED,3)
        run(['--stdin','--from','html','--to',target],NESTED.replace(b'<table>',b'<TaBlE\n>'),3)
        p=run(['--stdin','--from','html','--to',target],b'<p>[TABLE]</p>')
        assert b'TABLE' in p.stdout
        p=run(['--stdin','--from','html','--to',target],b'<p title="<table>">literal</p><!-- <table><table> -->')
        assert b'literal' in p.stdout
        run(['--stdin','--from','html','--to',target],b'<table><tr><th>A</th><th>B</th></tr><tr><td colspan="2">VALUE</td></tr></table>',3)
    complex_cells=b'<table><tr><th>A</th><th>B</th></tr><tr><td>one<br>two</td><td><p>three</p><p>four</p></td></tr></table>'
    simple_table=b'<table><tr><th>A</th></tr><tr><td>value</td></tr></table>'
    for target in ('gfm','markdown','commonmark'):
        args=['--stdin','--from','html','--to',target]
        assert run(args+['--strict'],simple_table).stdout
        p=run(args,complex_cells)
        if target=='markdown':
            assert b'Vereinfachung' not in p.stderr
            assert run(args+['--strict'],complex_cells).stdout==p.stdout
        else:
            assert b'2 Tabellenzellen' in p.stderr
            assert not run(args+['--strict'],complex_cells,3).stdout
    rtf_table=br'{\rtf1\ansi\trowd\cellx1000\cellx2000\intbl RTFLEFT\cell RTFRIGHT\cell\row}'
    for target in ('gfm','markdown','commonmark'):
        p=run(['--stdin','--from','rtf','--tables','text','--to',target],rtf_table)
        parsed=json.loads(subprocess.check_output([real_pandoc,'-f',target+('+pipe_tables' if target=='commonmark' else ''),'-t','json'],input=p.stdout))
        assert parsed['blocks'][0]['t']=='Table',p.stdout
        assert b'RTFLEFT' in p.stdout and b'RTFRIGHT' in p.stdout
    filter_file=runtime/'tables.lua'
    saved_filter=filter_file.read_bytes()
    for record in ('table-cells-flattened\tbogus\n', 'table-cells-flattened\t0\n',
                   'table-cells-flattened\t\t1\n', 'table-cells-flattened\t1\t\n',
                   'table-cells-flattened\t1', 'unknown\t1\n'):
        filter_file.write_bytes(('function Pandoc(doc)\n'
            'local f=assert(io.open(os.getenv("MD_CLIP_RESULT_FILE"),"a"))\n'
            'f:write('+json.dumps(record)+'); f:close(); return doc\nend\n').encode())
        invalid=run(['--stdin','--from','html'],b'<p>valid</p>',3)
        assert not invalid.stdout and b'Konvertierungsbericht' in invalid.stderr
    filter_file.write_bytes(saved_filter)
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
    env['MD_CLIP_STRICT']='1'
    env['MD_CLIP_TABLES']='text'
    env['MD_CLIP_IMAGES']='omit'
    assert b'![' in run(['--stdin','--from','html'],b'<img src="x" alt="Y">').stdout
    run(['--stdin','--from','html'],NESTED,3)
    doctor=json.loads(run(['--doctor','--json']).stdout)
    assert doctor['table_modes']==['reject','text']
    assert doctor['stdin'] and doctor['sandbox'] and doctor['undo'] and doctor['strict']
    assert doctor['image_modes']==['keep','alt','omit']
    assert doctor['table_filter'], 'Interne Umgebungswerte dürfen Doctor nicht verändern'
    env.pop('MD_CLIP_STRICT')
    env.pop('MD_CLIP_IMAGES')
    env.pop('MD_CLIP_TABLES')
    for target in ('gfm','markdown','commonmark'):
        for tag in ('textarea','title'):
            source=('<p>BEFORE</p><'+tag+'><td rowspan="0">literal</'+tag+'><p>AFTER</p>').encode()
            result=run(['--stdin','--from','html','--to',target,'--tables','text','--strict','--quiet'],source)
            assert b'BEFORE' in result.stdout and b'AFTER' in result.stdout and not result.stderr
        for value in ('&#50','&#x32'):
            source=('<table><tr><td colspan="'+value+'">CELL</td></tr></table>').encode()
            result=run(['--stdin','--from','html','--to',target,'--tables','text'],source)
            assert b'CELL' in result.stdout and b'2 Spalten' in result.stdout and b'beschrifteten Text' in result.stderr
            result=run(['--stdin','--from','html','--to',target,'--tables','text','--strict'],source,3)
            assert not result.stdout and b'Strukturvereinfachung' in result.stderr
    assert not (base/'calls').exists(), 'Datei/stdin/Doctor berührten Clipboard'
    # Kein pandoc-Aufruf im Plain-Weg, auch bei vorhandenem defektem Binary.
    (runtime/'pandoc').unlink()
    (runtime/'pandoc').write_text('#!/bin/sh\necho touched > "$MOCK_ROOT/pandoc-called"\nexit 88\n')
    (runtime/'pandoc').chmod(0o755)
    assert run(['--stdin','--plain'],b'bytes\n').stdout==b'bytes\n'
    assert run(['--stdin','--plain','--strict'],b'bytes\n').stdout==b'bytes\n'
    for mode in ('keep','alt','omit'):
        assert run(['--stdin','--plain','--images',mode],b'![image](x)\x00\n').stdout==b'![image](x)\x00\n'
    assert run(['--stdin','--plain','--tables','text'],b'|x|\x00\n').stdout==b'|x|\x00\n'
    assert not (base/'pandoc-called').exists()
    broken=json.loads(run(['--doctor','--json']).stdout)
    assert not broken['sandbox'] and not broken['table_filter']
    (runtime/'pandoc').unlink();(runtime/'pandoc').symlink_to(real_pandoc)
    env.pop('NO_CLIP')
    gui_dir=base/'helpers';gui_dir.mkdir()
    gui=gui_dir/'md-clip-preview'
    gui.write_text('#!' + os.path.realpath(sys.executable) + '\n' + '''import os,sys,pathlib,json,time
b=pathlib.Path(os.environ['MOCK_ROOT'])
(b/'preview-data').write_bytes(pathlib.Path(sys.argv[1]).read_bytes())
(b/'preview-notes').write_bytes(pathlib.Path(sys.argv[2]).read_bytes())
(b/'preview-process').write_text(str(os.getpid()))
assert pathlib.Path(sys.argv[3]).name=='clipboard-undo' and sys.argv[4]=='mock-token'
if os.environ.get('MOCK_PREVIEW_PAUSE'):time.sleep(30)
sys.exit(int(os.environ.get('MOCK_PREVIEW_STATUS','0')))
''')
    gui.chmod(0o755)
    platforms=[('Linux',''),('Linux','mock-wayland')]
    if os.uname().sysname=='Darwin': platforms.append(('Darwin',''))
    for platform,wayland in platforms:
        env.update(MOCK_PLATFORM=platform, WAYLAND_DISPLAY=wayland)
        (base/'rtf').write_bytes(b'{\\rtf1\\ansi RTF selected}')
        for rich, expected in ((b'<p>HTML safe</p>\x00', b'HTML safe\n'),
                               (b'<p>HTML safe</p>\x00\x00', b'HTML safe\n'),
                               (b'<html xmlns:o="urn:schemas-microsoft-com:office:office">\x00<p>HTML</p></html>', b'RTF selected\n'),
                               (b'<p>HTML</p>\x00<!-- '+b'mso-x '*10+b'-->', b'RTF selected\n')):
            (base/'html').write_bytes(rich)
            result=run(['--quiet'])
            assert result.stdout==expected and not result.stderr, (platform,wayland,result.stdout,result.stderr)
            assert (base/'html').read_bytes()==rich
        (base/'html').unlink()
        (base/'rtf').unlink()
        for args in (['--undo','--replace'], ['--undo','--plain'],
                     ['--undo','--stdin'], ['--undo','--from','auto'],
                     ['--undo','--doctor'], ['--undo','--preview'], ['--undo','--strict'], ['--undo','--images','keep'], ['--undo','--tables','reject']):
            run(args,rc=2)
        undo_calls()
        run(['--undo'],rc=1)
        assert undo_calls()==['undo']
        (base/'calls').unlink(missing_ok=True)
        env['UNDO_SUCCESS']='1'
        assert not run(['--undo']).stdout
        assert undo_calls()==['undo']
        assert (base/'calls').read_text().splitlines()==['clipboard-undo' if platform=='Darwin' else 'clipboard-undo-linux.py']
        env.pop('UNDO_SUCCESS')
        for flag in ('UNDO_FAIL_PREPARE','UNDO_FAIL_REPLACE'):
            (base/'written').write_bytes(b'protected')
            env[flag]='1'
            run(['--stdin','--plain','--replace'],b'new',1)
            assert (base/'written').read_bytes()==b'protected'
            assert undo_calls()==(['prepare'] if flag=='UNDO_FAIL_PREPARE' else ['prepare','replace','cancel'])
            env.pop(flag)
        (base/'html').write_bytes(b'<html xmlns:o="urn:schemas-microsoft-com:office:office"><p>HTML rescue</p></html>')
        (base/'rtf').write_bytes(b'plain tagged as RTF')
        (base/'plain').write_bytes(b'plain fallback\n\n')
        for strict in (False, True):
            undo_calls()
            p=run(['--replace',*(['--strict'] if strict else [])])
            assert (base/'written').read_bytes()==b'HTML rescue' and b'RTF-Kopf' in p.stderr
            assert undo_calls()==['prepare','replace']
        (base/'html').unlink()
        undo_calls()
        p=run(['--replace'])
        assert (base/'written').read_bytes()==b'plain fallback\n\n' and b'RTF-Kopf' in p.stderr
        assert undo_calls()==['prepare','replace']
        (base/'written').write_bytes(b'protected');undo_calls()
        run(['--replace','--strict'],rc=3)
        assert (base/'written').read_bytes()==b'protected' and undo_calls()==['prepare','cancel']
        run(['--replace','--from','rtf'],rc=3)
        assert (base/'written').read_bytes()==b'protected' and undo_calls()==['prepare','cancel']
        (base/'plain').write_bytes(b'plain\n\n')
        for target in ('gfm','markdown','commonmark'):
            (base/'html').write_bytes(NESTED)
            (base/'rtf').write_bytes(b'{\\rtf1\\ansi RTF rescue}')
            p=run(['--replace','--to',target]);assert (base/'written').read_bytes()==b'RTF rescue'
            assert undo_calls()==['prepare','replace']
            assert b'verschachtelte Tabelle' in p.stderr and b'RTF verwendet' in p.stderr
            p=run(['--replace','--strict','--to',target])
            assert (base/'written').read_bytes()==b'RTF rescue'
            assert undo_calls()==['prepare','replace']
            (base/'rtf').unlink()
            p=run(['--replace','--to',target]);assert (base/'written').read_bytes()==b'plain\n\n'
            assert undo_calls()==['prepare','replace']
            assert b'Klartext' in p.stderr and not p.stdout
            (base/'written').write_bytes(b'protected')
            p=run(['--replace','--strict','--to',target],rc=3)
            assert b'Strenger Modus' in p.stderr and not p.stdout
            assert (base/'written').read_bytes()==b'protected'
            assert undo_calls()==['prepare','cancel']
            run(['--replace','--from','html','--to',target],rc=3)
            assert (base/'written').read_bytes()==b'protected'
            assert undo_calls()==['prepare','cancel']
        for html in invisible_html:
            (base/'html').write_bytes(html)
            assert run().stdout==b'plain\n\n'
            run(['--replace'])
            assert (base/'written').read_bytes()==b'plain\n\n'
            (base/'written').write_bytes(b'protected')
            run(['--replace','--from','html'],rc=3)
            assert (base/'written').read_bytes()==b'protected'
        (base/'html').write_bytes(b'<html xmlns:o="urn:schemas-microsoft-com:office:office"><p>HTML rescue</p></html>')
        (base/'rtf').write_bytes(b'{\\rtf1\\ansi }')
        assert b'HTML rescue' in run().stdout
        (base/'html').write_bytes(b'<table><tr><th>A</th></tr><tr><td>one<br>two</td></tr></table>')
        assert b'Struktur vereinfacht' in run().stderr
        assert b'1 Tabellenzelle' in run().stderr
        assert not run(['--quiet','--verbose']).stderr
        for flags in (['--strict'], ['--strict','--quiet'], ['--strict','--preview']):
            (base/'written').write_bytes(b'protected')
            undo_calls()
            p=run(['--replace',*flags],rc=3)
            assert b'Strenger Modus' in p.stderr and not p.stdout
            assert (base/'written').read_bytes()==b'protected'
            assert undo_calls()==['prepare','cancel']
        (base/'html').unlink()
        (base/'rtf').unlink(missing_ok=True)
        undo_calls()
        p=run(['--strict','--replace'])
        assert (base/'written').read_bytes()==b'plain\n\n'
        assert b'R\xc3\xbcckfall' not in p.stderr and b'Vereinfachung' not in p.stderr
        assert undo_calls()==['prepare','replace']
        (base/'html').write_bytes(NESTED)
        undo_calls()
        run(['--strict','--plain','--replace'])
        assert (base/'written').read_bytes()==b'plain\n\n'
        assert undo_calls()==['prepare','replace']
        image_html=b'<p>Text <img src="https://example.invalid/a.png" alt="Diagramm"></p>'
        (base/'html').write_bytes(image_html)
        for target in ('gfm','markdown','commonmark'):
            for mode in ('alt','omit'):
                undo_calls()
                p=run(['--replace','--images',mode,'--to',target])
                written=(base/'written').read_bytes()
                assert b'Text' in written and b'![' not in written
                assert (b'Diagramm' in written)==(mode=='alt')
                assert b'1 Bild' in p.stderr
                assert undo_calls()==['prepare','replace']
                (base/'written').write_bytes(b'protected')
                p=run(['--replace','--images',mode,'--strict','--to',target],rc=3)
                assert b'Bildvereinfachung' in p.stderr and not p.stdout
                assert (base/'written').read_bytes()==b'protected'
                assert undo_calls()==['prepare','cancel']
        (base/'html').write_bytes(NESTED)
        for target in ('gfm','markdown','commonmark'):
            undo_calls()
            (base/'written').unlink(missing_ok=True)
            p=run(['--from','html','--replace','--tables','text','--to',target])
            assert b'2 Tabellen' in p.stderr
            assert b'VALUE' in (base/'written').read_bytes()
            assert undo_calls()==['prepare','replace']
            (base/'written').unlink()
            p=run(['--from','html','--replace','--tables','text','--strict','--to',target],rc=3)
            assert not p.stdout and not (base/'written').exists()
            assert undo_calls()==['prepare','cancel']
            assert b'Strenger Modus' in p.stderr
        for mode in ('alt','omit'):
            (base/'html').write_bytes(b'<img src="x">')
            (base/'written').write_bytes(b'protected')
            p=run(['--from','html','--replace','--images',mode],rc=3)
            assert not p.stdout and (base/'written').read_bytes()==b'protected'
            assert undo_calls()==['prepare','cancel']
        (base/'html').write_bytes(NESTED)
        (base/'written').write_bytes(b'protected')
        run(['--preview','--replace'],rc=2)
        assert (base/'written').read_bytes()==b'protected'
        undo_calls()
        if platform=='Darwin':
            env['UNDO_FAIL_STATUS']='1'
            (base/'preview-data').unlink(missing_ok=True)
            p=run(['--replace','--preview-window'],rc=2)
            assert b'Undo-Status' in p.stderr and not undo_calls() and not (base/'preview-data').exists()
            env.pop('UNDO_FAIL_STATUS')
            (base/'html').write_bytes(b'<p>Text <img src="x" alt="BILD"></p>')
            (runtime/'pandoc').unlink()
            (runtime/'pandoc').write_text('#!' + os.path.realpath(sys.executable) + '\n' +
                'import sys,os,pathlib\n' +
                "if '--wrap=none' in sys.argv:\n with (pathlib.Path(os.environ['MOCK_ROOT'])/'conversions').open('a') as f:f.write('1\\n')\n" +
                'os.execv(' + repr(real_pandoc) + ', [' + repr(real_pandoc) + ',*sys.argv[1:]])\n')
            (runtime/'pandoc').chmod(0o755)
            for decision, code in ((0,0),(4,4),(64,3)):
                undo_calls()
                (base/'conversions').unlink(missing_ok=True)
                (base/'written').write_bytes(b'protected')
                env['MOCK_PREVIEW_STATUS']=str(decision)
                p=run(['--from','html','--replace','--preview-window','--images','alt','--quiet'],rc=code)
                assert (base/'conversions').read_text().splitlines()==['1']
                assert b'1 Bild' in (base/'preview-notes').read_bytes() and b'Quelle: HTML' in (base/'preview-notes').read_bytes()
                assert undo_calls()==(['prepare','replace'] if decision==0 else ['prepare','cancel'])
                assert (base/'written').read_bytes()==((base/'preview-data').read_bytes() if decision==0 else b'protected')
                assert not p.stdout
            env['MOCK_PREVIEW_STATUS']='5';env['UNDO_SUCCESS']='1'
            undo_calls()
            run(['--from','html','--replace','--preview-window'])
            assert undo_calls()==['prepare','cancel','undo']
            env.pop('UNDO_SUCCESS');env.pop('MOCK_PREVIEW_STATUS')
            (base/'html').write_bytes(NESTED)
            (base/'rtf').write_bytes(b'{\\rtf1\\ansi RTF rescue}')
            undo_calls()
            run(['--replace','--preview-window'])
            assert b'RTF rescue' in (base/'preview-data').read_bytes()
            notes=(base/'preview-notes').read_bytes()
            assert b'HTML' in notes and b'RTF verwendet' in notes
            undo_calls()
            (base/'preview-data').unlink()
            run(['--from','html','--replace','--preview-window','--strict'],rc=3)
            assert not (base/'preview-data').exists() and undo_calls()==['prepare','cancel']
            (base/'rtf').unlink()
            (base/'html').write_bytes(b'<p>valid</p>')
            for interruption, code in ((signal.SIGINT,130),(signal.SIGTERM,143)):
                env['MOCK_PREVIEW_PAUSE']='1'
                (base/'preview-process').unlink(missing_ok=True)
                undo_calls()
                proc=subprocess.Popen([str(runtime/'md-clip'),'--from','html','--replace','--preview-window'],
                                      stdout=subprocess.PIPE,stderr=subprocess.PIPE,env=env,start_new_session=True)
                try:
                    deadline=time.monotonic()+10
                    while not (base/'preview-process').exists() and time.monotonic()<deadline:time.sleep(.01)
                    assert (base/'preview-process').exists()
                    child=int((base/'preview-process').read_text())
                    proc.send_signal(interruption)
                    out,error=proc.communicate(timeout=5)
                    assert proc.returncode==code,(code,proc.returncode,error)
                    assert not out and undo_calls()==['prepare','cancel']
                    try:os.kill(child,0)
                    except ProcessLookupError:pass
                    else:raise AssertionError('Vorschau-Kindprozess blieb aktiv')
                finally:
                    if proc.poll() is None:os.killpg(proc.pid,signal.SIGKILL)
                    proc.wait()
                env.pop('MOCK_PREVIEW_PAUSE')
            (runtime/'pandoc').unlink();(runtime/'pandoc').symlink_to(real_pandoc)
            print('OK: native Vorschau übernimmt einmaliges Ergebnis, Hinweise/Quiet, Cancel, Undo und Signale')
        else:
            (base/'preview-data').unlink(missing_ok=True)
            run(['--replace','--preview-window'],rc=2)
            assert not (base/'preview-data').exists() and not undo_calls()
        env['MOCK_TRACK_CAT']='1'
        for io_mode in ('stdin','stdout'):
            for interruption, expected_code in ((signal.SIGINT,130),(signal.SIGTERM,143)):
                undo_calls();(base/'io-cat-pid').unlink(missing_ok=True)
                if io_mode=='stdin':
                    command=[str(runtime/'md-clip'),'--stdin','--plain','--replace']
                else:
                    source=base/'large-plain.txt';source.write_bytes(b'X'*(4*1024*1024))
                    command=[str(runtime/'md-clip'),'--input',str(source),'--plain']
                proc=subprocess.Popen(command,stdin=subprocess.PIPE,stdout=subprocess.PIPE,stderr=subprocess.PIPE,env=env,start_new_session=True)
                group=proc.pid
                try:
                    deadline=time.monotonic()+8
                    if io_mode=='stdout':
                        assert select.select([proc.stdout],[],[],8)[0], 'stdout-Kopie begann nicht'
                        assert proc.stdout.read(1)==b'X'
                    else:
                        while not (base/'io-cat-pid').exists() and time.monotonic()<deadline:time.sleep(.01)
                    assert (base/'io-cat-pid').exists(), 'I/O-Kindprozess begann nicht'
                    child=int((base/'io-cat-pid').read_text())
                    proc.send_signal(interruption)
                    deadline=time.monotonic()+5
                    while proc.poll() is None and time.monotonic()<deadline:time.sleep(.01)
                    assert proc.returncode==expected_code, 'Elternsignal benötigte EOF/freien stdout: '+io_mode
                    # Erst nach der Exit-Prüfung stdin schließen/stdout leeren.
                    out,error=proc.communicate(timeout=2)
                    if io_mode=='stdin':assert not out and undo_calls()==['prepare','cancel']
                    else:assert len(out)<4*1024*1024 and not undo_calls()
                    try:os.kill(child,0)
                    except ProcessLookupError:pass
                    else:raise AssertionError('I/O-Kindprozess blieb aktiv')
                finally:
                    try:os.killpg(group,signal.SIGKILL)
                    except ProcessLookupError:pass
                    proc.communicate(timeout=3)
        master,slave=pty.openpty()
        attributes=termios.tcgetattr(slave)
        attributes[3] &= ~(termios.ECHO | termios.ECHONL)
        termios.tcsetattr(slave,termios.TCSANOW,attributes)
        proc=subprocess.Popen([str(runtime/'md-clip'),'--stdin','--plain'],stdin=slave,
                              stdout=subprocess.PIPE,stderr=subprocess.PIPE,env=env,start_new_session=True)
        os.close(slave)
        try:
            terminal_bytes='Terminal ä😀\n'.encode()
            os.write(master,terminal_bytes+b'\x04')
            out,error=proc.communicate(timeout=10)
            assert proc.returncode==0 and out==terminal_bytes,(proc.returncode,out,error)
        finally:
            os.close(master)
            if proc.poll() is None:proc.kill()
            proc.wait(timeout=3)
        env.pop('MOCK_TRACK_CAT')
        signal_work=base/'signal-work';signal_work.mkdir(exist_ok=True)
        previous_tmp=env.get('TMPDIR')
        env.update(TMPDIR=str(signal_work),UNDO_PAUSE_CANCEL='1',MOCK_TRACK_CAT='1')
        for first,second,expected in ((signal.SIGINT,signal.SIGTERM,130),(signal.SIGTERM,signal.SIGINT,143)):
            undo_calls();(base/'cancel-start').unlink(missing_ok=True);(base/'io-cat-pid').unlink(missing_ok=True)
            (base/'written').write_bytes(b'protected')
            proc=subprocess.Popen([str(runtime/'md-clip'),'--stdin','--plain','--replace','--quiet'],
                                  stdin=subprocess.PIPE,stdout=subprocess.PIPE,stderr=subprocess.PIPE,env=env,start_new_session=True)
            try:
                proc.stdin.write(b'synthetic incomplete input');proc.stdin.flush()
                end=time.monotonic()+8
                while time.monotonic()<end:
                    sources=list(signal_work.glob('md-clip.*/plain'))
                    if sources and sources[0].read_bytes()==b'synthetic incomplete input':break
                    time.sleep(.01)
                else:raise AssertionError('Private Teilquelle nicht erreicht')
                proc.send_signal(first)
                end=time.monotonic()+5
                while not (base/'cancel-start').exists() and time.monotonic()<end:time.sleep(.01)
                assert (base/'cancel-start').exists(), 'Stornierung begann nicht'
                proc.send_signal(second)
                assert proc.wait(timeout=5)==expected, 'Weiteres Signal änderte ersten Exit'
                out,error=proc.communicate(timeout=2)
                assert not out and not list(signal_work.iterdir()), (out,error,list(signal_work.iterdir()))
                assert (base/'written').read_bytes()==b'protected' and undo_calls()==['prepare','cancel']
                for marker in ('io-cat-pid','cancel-start'):
                    child=int((base/marker).read_text())
                    try:os.kill(child,0)
                    except ProcessLookupError:pass
                    else:raise AssertionError('Cleanup-Kindprozess blieb aktiv')
            finally:
                if proc.poll() is None:os.killpg(proc.pid,signal.SIGKILL)
                proc.communicate(timeout=3)
        for name in ('UNDO_PAUSE_CANCEL','MOCK_TRACK_CAT'):env.pop(name)
        if previous_tmp is None:env.pop('TMPDIR')
        else:env['TMPDIR']=previous_tmp
        print('OK:',platform,wayland or 'default','Tabellen/Fallback/Strict/Schreibschutz')
    # Echte Terminalabfrage, aber ausschließlich auf den Clipboard-Attrappen.
    for answer, expected_rc in ((b'nein\n',4),(b'ja\n',0),(b'\x04',4)):
        undo_calls()
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
        assert undo_calls()==['prepare','replace' if expected_rc==0 else 'cancel']
    print('OK: Vorschau bestaetigen/ablehnen/EOF im isolierten Terminal')
    for interruption, expected_rc in ((signal.SIGINT,130),(signal.SIGTERM,143)):
        undo_calls()
        proc=subprocess.Popen([str(runtime/'md-clip'),'--stdin','--plain','--replace'],
                              stdin=subprocess.PIPE,stdout=subprocess.PIPE,stderr=subprocess.PIPE,
                              env=env,start_new_session=True)
        try:
            deadline=time.monotonic()+5
            while time.monotonic()<deadline:
                calls=base/'undo-calls'
                if calls.exists() and calls.read_text().splitlines()==['prepare']:break
                time.sleep(.01)
            else:raise AssertionError('prepare wurde nicht erreicht')
            time.sleep(.1)
            os.killpg(proc.pid,interruption)
            stdout,stderr=proc.communicate(timeout=5)
            assert proc.returncode==expected_rc,(proc.returncode,stderr)
            assert not stdout
            assert undo_calls()==['prepare','cancel']
        finally:
            if proc.poll() is None:os.killpg(proc.pid,signal.SIGKILL)
            proc.wait()
    print('OK: INT/TERM storniert vorbereitete Sicherung einmalig')
    interpreters=set((base/'interpreters').read_text().splitlines())
    assert interpreters=={os.path.realpath(sys.executable)}, interpreters
    assert not (base/'unwanted-interpreter').exists()
    print('OK: alle Python-Attrappen verwenden',os.path.realpath(sys.executable))
print('OK: stdin/Datei/Doctor/Klartext-Abhängigkeiten')
