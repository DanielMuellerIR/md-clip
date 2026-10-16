#!/usr/bin/env python3
"""Konvertierung aus dem eigenen unsignierten Build, ohne GUI oder Clipboard."""
import argparse
import hashlib
import html
import json
import os
from pathlib import Path
import platform
import re
import shutil
import subprocess
import tempfile
import zipfile

ROOT = Path(__file__).resolve().parents[1]
parser = argparse.ArgumentParser()
parser.add_argument('bundle', nargs='?', type=Path, default=ROOT/'build/md-clip.app')
args = parser.parse_args()
if platform.system() != 'Darwin':
    print('SKIP: App-Bundle benötigt macOS')
    raise SystemExit(0)


def digest(stream):
    result = hashlib.sha256()
    for chunk in iter(lambda: stream.read(1024*1024), b''):
        result.update(chunk)
    return result.hexdigest()


def file_digest(path):
    with path.open('rb') as stream:
        return digest(stream)


def pin(name):
    values = re.findall(r'^'+name+r'="([0-9a-f.]+)"$', (ROOT/'wrappers/pandoc-pin.sh').read_text(), re.M)
    assert len(values) == 1, 'Uneindeutiger Bundle-Pin: '+name
    return values[0]


def nodes(value, kind):
    if isinstance(value, dict):
        return ([value] if value.get('t') == kind else []) + sum((nodes(v,kind) for v in value.values()), [])
    if isinstance(value, list):
        return sum((nodes(v,kind) for v in value), [])
    return []


resources = args.bundle.resolve()/'Contents/Resources/bin'
cli, pandoc = resources/'md-clip', resources/'pandoc'
assert cli.read_bytes() == (ROOT/'bin/md-clip').read_bytes(), 'Bundle-CLI weicht von der Build-Quelle ab'
for source in (ROOT/'lib').iterdir():
    if source.is_file():
        assert (resources/source.name).read_bytes() == source.read_bytes(), 'Bundle-Ressource weicht ab: '+source.name
version = pin('PANDOC_VERSION')
archive = ROOT/'build/cache'/('pandoc-'+version+'-arm64.zip')
assert file_digest(archive) == pin('PANDOC_ZIP_SHA256'), 'Build-Archiv stimmt nicht mit dem Pin überein'
# Vor Ausführung das tatsächliche Binary an das geprüfte Archiv binden.
with zipfile.ZipFile(archive) as package:
    with package.open('pandoc-'+version+'-arm64/bin/pandoc') as stream:
        assert digest(stream) == file_digest(pandoc), 'Bundle-pandoc weicht vom geprüften Archiv ab'

with tempfile.TemporaryDirectory(prefix='md-clip-bundle-') as temporary:
    work = Path(temporary)/'cwd with spaces';work.mkdir()
    tools = work/'caller tools';tools.mkdir()
    marker = work/'unexpected-tool'
    for name in ('pandoc','pbcopy','pbpaste','osascript','xclip','wl-copy','wl-paste'):
        tool = tools/name
        tool.write_text('#!/bin/sh\nprintf \'%s\\n\' "$0" >> "$BUNDLE_TEST_MARKER"\nexit 86\n')
        tool.chmod(0o755)
    env = dict(os.environ, PATH=str(tools)+':/usr/bin:/bin:/usr/sbin:/sbin', BUNDLE_TEST_MARKER=str(marker))
    alias = work/'md clip alias';alias.symlink_to(cli)

    def run(options, data=None, expected=0, executable=alias):
        result = subprocess.run([str(executable),*options,'--quiet'],input=data,env=env,cwd=work,
                                capture_output=True,timeout=20)
        assert result.returncode == expected, (options,result.returncode,result.stderr)
        if expected:
            assert not result.stdout and result.stderr, (options,result.stdout,result.stderr)
        return result.stdout

    def parse(data, target):
        reader = {'gfm':'gfm-autolink_bare_uris','commonmark':'commonmark+pipe_tables'}.get(target,target)
        result = subprocess.run([str(pandoc),'-f',reader,'-t','json'],input=data,capture_output=True,timeout=20)
        assert result.returncode == 0, result.stderr
        return json.loads(result.stdout)

    source_version = subprocess.check_output(['bash','-c','source "$1"; md_clip_version "$2"',
                                             'bundle-version',str(ROOT/'wrappers/version.sh'),str(ROOT/'bin/md-clip')],text=True).strip()
    assert run(['--version']).splitlines()[0] == ('md-clip '+source_version).encode()
    for raw in (b'plain',b'plain\n\n',b'\x00\xff\r\n',b'\n\n'):
        assert run(['--stdin','--plain'],raw) == raw
        path = work/'raw input.txt';path.write_bytes(raw)
        assert run(['--input',str(path),'--plain','--strict']) == raw

    code = '  printf "%s" \\\n    "\\# literal"\n  next\\\n'
    rich = ('<h2><span title="a > b">HEADING</span></h2><p><strong>BOLD</strong> '
            '<em>ITALIC</em> <a href="https://example.invalid/a?x=1&amp;y=2" title="TITLE">LINK</a> '
            '<code>\\# a|b</code></p><pre><span>'+html.escape(code)+'</span></pre>'
            '<table><tr><th>HEAD A</th><th>HEAD B</th></tr><tr><td>x|y</td><td># raw</td></tr></table>'
            '<p><img src="data:image/png;base64,YQ==" alt="ICON"></p>').encode()
    path = work/'rich input.html';path.write_bytes(rich)
    for target in ('gfm','markdown','commonmark'):
        options = ['--stdin','--from','html','--to',target]
        result = run(options+['--strict'],rich)
        assert run(['--input',str(path),'--to',target,'--strict']) == result
        doc = parse(result,target)
        assert [n['c'][0] for n in nodes(doc,'Header')] == [2]
        assert [n['c'][-1] for n in nodes(doc,'CodeBlock')] == [code.rstrip('\n')]
        assert [n['c'][-1] for n in nodes(doc,'Code')] == ['\\# a|b']
        assert [n['c'][2] for n in nodes(doc,'Link')] == [['https://example.invalid/a?x=1&y=2','TITLE']]
        assert len(nodes(doc,'Strong')) == len(nodes(doc,'Emph')) == len(nodes(doc,'Image')) == 1
        table, = nodes(doc,'Table')
        rows = table['c'][3][1] + sum((body[2]+body[3] for body in table['c'][4]),[]) + table['c'][5][1]
        assert [len(row[1]) for row in rows] == [2,2]
        assert [[' '.join(n['c'] for n in nodes(cell[4],'Str')) for cell in row[1]] for row in rows] == [['HEAD A','HEAD B'],['x|y','# raw']]
        for mode in ('alt','omit'):
            changed = parse(run(options+['--images',mode],rich),target)
            assert not nodes(changed,'Image')
            assert ('ICON' in [n['c'] for n in nodes(changed,'Str')]) == (mode=='alt')
            run(options+['--images',mode,'--strict'],rich,3)
        spanned = b'<table><tr><td colspan="&#50">CELL</td></tr></table>'
        run(options,spanned,3)
        text = parse(run(options+['--tables','text'],spanned),target)
        assert not nodes(text,'Table') and 'CELL' in [n['c'] for n in nodes(text,'Str')]
        run(options+['--tables','text','--strict'],spanned,3)
        protected = b'<p>BEFORE</p><textarea><td rowspan="0">literal</textarea><p>AFTER</p>'
        doc = parse(run(options+['--tables','text','--strict'],protected),target)
        assert [n['c'] for n in nodes(doc,'Str')] == ['BEFORE','AFTER']
    rtf = work/'rich input.rtf';rtf.write_bytes(br'{\rtf1\ansi\b RTFTEXT}')
    assert b'RTFTEXT' in run(['--input',str(rtf)])
    run(['--stdin','--from','rtf'],b'plain tagged as RTF',3)
    run(['--stdin','--plain'],b'',1)
    run(['--input',str(work/'missing.html')],expected=2)
    run(['--stdin','--from','html','--to','unknown'],b'<p>x</p>',2)

    broken = work/'isolated runtime';broken.mkdir()
    for source in [cli,*[resources/f.name for f in (ROOT/'lib').iterdir() if f.is_file()]]:
        shutil.copy2(source,broken/source.name)
    (broken/'pandoc').symlink_to(pandoc)
    (broken/'tables.lua').unlink()
    failure = subprocess.run([str(broken/'md-clip'),'--stdin','--from','html','--quiet'],input=b'<p>VISIBLE</p>',
                             cwd=work,env=env,capture_output=True,timeout=20)
    assert failure.returncode != 0 and not failure.stdout and failure.stderr
    (broken/'pandoc').unlink()
    for name in ('pandoc','perl'):
        shutil.copy2(tools/'pandoc',broken/name)
    assert run(['--stdin','--plain'],b'bytes\x00\xff\n',executable=broken/'md-clip') == b'bytes\x00\xff\n'
    assert not marker.exists(), 'Bundle rief ein Clipboard-/GUI-Werkzeug oder Caller-pandoc auf'
print('OK: echtes Bundle, Ressourcen/Pin, fremdes cwd, Leerzeichen, Rohbytes, RTF/HTML, drei Dialekte, Bilder/Tabellen/Strict und fehlende Ressource')
