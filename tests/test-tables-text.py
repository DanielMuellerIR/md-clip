#!/usr/bin/env python3
"""Komplexe Tabellen: Koordinaten und Zellinhalt nach Markdown-Roundtrip."""
import collections
import copy
import json
import os
from pathlib import Path
import subprocess
import tempfile

ROOT = Path(__file__).resolve().parents[1]


def nodes(value, kind):
    if isinstance(value, dict):
        return ([value] if value.get('t') == kind else []) + sum(
            (nodes(child, kind) for child in value.values()), [])
    if isinstance(value, list):
        return sum((nodes(child, kind) for child in value), [])
    return []


def text(value):
    return ' '.join(node['c'] for node in nodes(value, 'Str'))


code = 'printf "%s" \\\n  "\\# literal"\nnext\\\n'
html = '''<table><caption>CAPTION <em>CAPEM</em></caption>
<thead><tr><th colspan="3">HEAD</th></tr></thead>
<tbody><tr><td colspan="2" rowspan="2"><p><strong>BOLD</strong> <a href="https://example.invalid/t?a=1&amp;b=2" title="LINKTITLE">LINKTEXT</a></p>
<ul><li>LISTONE</li><li>LISTTWO</li></ul><pre><code>''' + code + '''</code></pre></td>
<td>BEFORE<table><tr><td>INNER<table><tr><td>DEEPEST</td></tr></table></td></tr></table>AFTER</td></tr>
<tr><td></td></tr></tbody><tfoot><tr><td colspan="3">FOOT</td></tr></tfoot></table>'''
markers = ['CAPTION', 'CAPEM', 'HEAD', 'BOLD', 'LINKTEXT', 'LISTONE', 'LISTTWO',
           'BEFORE', 'INNER', 'DEEPEST', 'AFTER', 'FOOT']
with tempfile.TemporaryDirectory(prefix='md-clip-tables-') as tmp:
    report = Path(tmp) / 'report'

    def convert(data, target, mode='text', strict=False, success=True, function='convert_html', images='keep'):
        report.write_bytes(b'')
        env = dict(os.environ, MD_CLIP_RESULT_FILE=str(report), MD_CLIP_TABLES=mode,
                   MD_CLIP_STRICT='1' if strict else '0', MD_CLIP_IMAGES=images)
        p = subprocess.run(['bash', '-c', 'set -o pipefail; source "$1"; rtf_to_html() { cat; }; "$2" "$3"',
                            'table-test', str(ROOT / 'lib/pipeline.sh'), function, target],
                           input=data.encode(), capture_output=True, env=env, timeout=20)
        assert (p.returncode == 0) == success, (target, p.stderr, p.stdout)
        records = collections.Counter()
        for line in report.read_text().splitlines():
            key, count = line.split('\t')
            records[key] += int(count)
        if not success:
            assert not p.stdout, p.stdout
            return None, records, p.stdout
        reader = {'gfm': 'gfm-autolink_bare_uris', 'commonmark': 'commonmark+pipe_tables'}.get(target, target)
        parsed = subprocess.check_output(['pandoc', '-f', reader, '-t', 'json'], input=p.stdout, timeout=20)
        return json.loads(parsed), records, p.stdout

    for target in ('gfm', 'markdown', 'commonmark'):
        doc, records, output = convert(html, target)
        assert records == {'tables-text': 3}, records
        assert not nodes(doc, 'Table')
        assert len(nodes(doc, 'BlockQuote')) == 3
        words = [n['c'] for n in nodes(doc, 'Str')]
        for marker in markers:
            assert words.count(marker) == 1, (target, marker, words)
        assert [n['c'][1] for n in nodes(doc, 'CodeBlock')] == [code.rstrip('\n')], (target, output)
        links = nodes(doc, 'Link')
        assert len(links) == 1 and links[0]['c'][2] == ['https://example.invalid/t?a=1&b=2', 'LINKTITLE']
        assert len(nodes(doc, 'BulletList')) == 1 and len(nodes(doc, 'BulletList')[0]['c']) == 2
        assert any(text(n) == 'BOLD' for n in nodes(doc, 'Strong'))
        assert any(text(n) == 'CAPEM' for n in nodes(doc, 'Emph'))
        labels = [text(n) for n in nodes(doc, 'Strong')]
        for expected in ('Tabelle 1 — Textdarstellung (3 Spalten)', 'Tabelle 2 — Textdarstellung (1 Spalte)',
                         'Tabelle 3 — Textdarstellung (1 Spalte)', 'Zeile 1 (Tabellenkopf)',
                         'Zeile 2 (Tabellenkörper 1)', 'Spalten 1–2; Zeilen 2–3',
                         'Spalten 1–2: Fortsetzung aus Zeile 2, Spalte 1', 'Zeile 4 (Tabellenfuß)'):
            assert expected in labels, (expected, labels)
        assert text(doc).count('(leere Zelle)') == 1
        for function in ('convert_html', 'convert_rtf'):
            _, reasons, _ = convert(html, target, strict=True, success=False, function=function)
            assert reasons == {'tables-text': 1}, reasons
        _, reasons, _ = convert(html, target, mode='reject', success=False)
        assert reasons['table-spanned'] or reasons['table-nested']
        # RTF-Adapter behält im Textmodus die Matrix; der echte Reader wird im CLI-Test geprüft.
        rtfdoc, reasons, _ = convert(html, target, function='convert_rtf')
        assert reasons == {'tables-text': 3} and text(rtfdoc) == text(doc)
        simple = '<table><tr><th>A</th><th>B</th></tr><tr><td>x</td><td>y</td></tr></table>'
        unchanged, reasons, original = convert(simple, target, mode='reject', strict=True)
        same, reasons2, alternative = convert(simple, target, strict=True)
        assert original == alternative and not reasons and not reasons2 and nodes(same, 'Table')
        multi = '<table><tbody><tr><td colspan="2">GROUPONE</td></tr></tbody><tbody><tr><td>GROUPTWO</td><td>OTHER</td></tr></tbody></table>'
        grouped, reasons, _ = convert(multi, target)
        assert 'Zeile 2 (Tabellenkörper 2)' in [text(n) for n in nodes(grouped, 'Strong')]
        assert reasons == {'tables-text': 1}
        for image_mode in ('keep', 'alt', 'omit'):
            picture = '<table><tr><td colspan="2"><img src="data:image/png;base64,YQ==" alt="DIAGRAM"></td></tr></table>'
            pictured, reasons, _ = convert(picture, target, images=image_mode)
            assert len(nodes(pictured, 'Image')) == (image_mode == 'keep')
            assert reasons['tables-text'] == 1
            assert ('DIAGRAM' in text(pictured)) == (image_mode != 'omit')
        for value in ('0', '-1', 'nope', ''):
            bad = '<table><tr><td rowspan="' + value + '">X</td></tr></table>'
            _, reasons, _ = convert(bad, target, success=False)
            assert reasons['table-ambiguous'] == 1, reasons
        duplicate = '<table><tr><td colspan="2" COLSPAN="3">X</td></tr></table>'
        _, reasons, _ = convert(duplicate, target, success=False)
        assert reasons['table-ambiguous'] == 1
        encoded = '<table><tr><td title="a > b" COLSPAN = "&#50;">ENTITY</td></tr></table>'
        entity, reasons, _ = convert(encoded, target)
        assert reasons == {'tables-text': 1} and 'ENTITY' in text(entity)
        protected = '<p title="<td rowspan=0>">TEXT</p><!-- <td rowspan="0"> --><script>"<td rowspan=0>"</script><pre><code>&lt;td rowspan="0"&gt;</code></pre>'
        _, reasons, _ = convert(protected, target)
        assert not reasons

    # Der HTML-Reader repariert manche defekten Matrizen bereits. Die Grenze des
    # Renderers deshalb zusätzlich an einer gezielt ungültigen geparsten Matrix prüfen.
    parsed = json.loads(subprocess.check_output(['pandoc', '-f', 'html', '-t', 'json'], input=b'<table><thead><tr><th colspan="2">H</th></tr></thead><tbody><tr><td>X</td><td>Y</td></tr></tbody></table>'))
    for mutate in ('past-group', 'past-column', 'missing-cell'):
        broken = copy.deepcopy(parsed)
        cell = broken['blocks'][0]['c'][4][0][3][0][1][0]
        if mutate == 'past-group': cell[2] = 2
        elif mutate == 'past-column': cell[3] = 3
        else: broken['blocks'][0]['c'][4][0][3][0][1].pop()
        report.write_bytes(b'')
        env = dict(os.environ, MD_CLIP_RESULT_FILE=str(report), MD_CLIP_TABLES='text', MD_CLIP_STRICT='0')
        p = subprocess.run(['pandoc', '-f', 'json', '-t', 'gfm', '--lua-filter', str(ROOT / 'lib/tables.lua')],
                           input=json.dumps(broken).encode(), env=env, capture_output=True, timeout=20)
        assert p.returncode != 0 and not p.stdout and report.read_text() == 'table-ambiguous\t1\n'
print('OK: Tabellen-Textmodus, Spannweiten, Verschachtelung, Inhalte, RTF-Adapter und Abbrüche')
