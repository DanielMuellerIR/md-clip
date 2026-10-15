#!/usr/bin/env python3
"""HTML-Varianten müssen nach dem Markdown-Roundtrip denselben Inhalt behalten."""
import json
from pathlib import Path
import subprocess

ROOT = Path(__file__).resolve().parents[1]


def run(args, data):
    result = subprocess.run(args, input=data, capture_output=True, timeout=20)
    assert result.returncode == 0, result.stderr.decode(errors="replace")
    return result.stdout


def signature(document):
    found = {name: [] for name in ("Link", "Image", "Code", "CodeBlock", "OrderedList", "BulletList", "Strong", "Emph", "Header", "Table")}

    def visit(value):
        if isinstance(value, list):
            for child in value:
                visit(child)
        elif isinstance(value, dict):
            kind, content = value.get("t"), value.get("c")
            if kind in ("Link", "Image"):
                found[kind].append(content[2])
            elif kind in ("Code", "CodeBlock"):
                found[kind].append(content[-1])
            elif kind == "OrderedList":
                found[kind].append([content[0][0], len(content[1])])
            elif kind == "BulletList":
                found[kind].append(len(content))
            elif kind in ("Strong", "Emph"):
                found[kind].append(1)
            elif kind == "Header":
                found[kind].append(content[0])
            elif kind == "Table":
                rows = list(content[3][1])
                for body in content[4]:
                    rows.extend(body[2] + body[3])
                rows.extend(content[5][1])
                found[kind].append([len(row[1]) for row in rows])
            for child in value.values():
                visit(child)

    visit(document["blocks"])
    plain = run(["pandoc", "-f", "json", "-t", "plain", "--wrap=none"], json.dumps(document).encode())
    return plain, found


cases = []
for attrs in ('title="a > b"', "title='a > b'", 'title="a &gt; b"',
              'class="x" title="a > b" data-note="kept"',
              'title="data-line=\'7\' > style=\'x\'"',
              'title="a >\nb"', 'TITLE="a > b"'):
    cases.append(("span-" + attrs, '<p><span ' + attrs + '>Hallo</span></p>', '<p>Hallo</p>'))
cases.extend([
    ("nested-spans", '<p><span title="a > b">A <span><strong>B</strong></span> C</span></p>', '<p>A <strong>B</strong> C</p>'),
    ("significant-space", '<p><strong>A</strong><span title="a > b"> </span><em>B</em></p>', '<p><strong>A</strong> <em>B</em></p>'),
    ("comment", '<!-- <span title="a > b">hidden</span> --><p>visible</p>', '<p>visible</p>'),
    ("literal-code", '<pre><code>&lt;span title="a &gt; b" style="x"&gt;\n\\# keep\\\n</code></pre>', '<pre><code>&lt;span title="a &gt; b" style="x"&gt;\n\\# keep\\\n</code></pre>'),
    ("attribute-lookalike", '<div title=" data-line=\'1\' style=\'x\' >">A</div><p>B</p>', '<p>A</p><p>B</p>'),
    ("table-spans", '<table><tr><th>A</th><th>B</th></tr><tr><td><span title="a > b">eins</span></td><td><strong>zwei</strong></td></tr></table>', '<table><tr><th>A</th><th>B</th></tr><tr><td>eins</td><td><strong>zwei</strong></td></tr></table>'),
    ("heading", '<h2><span title="a > b">Titel</span></h2>', '<h2>Titel</h2>'),
])
for attrs in ('title="a > b" href="https://example.test/a_(b)?x=1&amp;y=2"',
              "href='https://example.test/a_(b)?x=1&amp;y=2' title='a > b'",
              'TITLE="a > b" HREF="https://example.test/a_(b)?x=1&amp;y=2"'):
    cases.append(("empty-link-" + attrs, '<p><a ' + attrs + '><i></i></a></p>',
                  '<p><a href="https://example.test/a_(b)?x=1&amp;y=2" title="a > b">https://example.test/a_(b)?x=1&amp;y=2</a></p>'))
for attrs in ('data-line="1" title="a > b"', "title='a > b' data-line='1'", 'DATA-LINE="1"'):
    cases.append(("claude-" + attrs,
                  '<pre><code><div ' + attrs + '>one</div><div data-line="2">two</div></code></pre>',
                  '<pre><code>one\ntwo\n</code></pre>'))
for attrs in ('class="mvRF3b" title="a > b"', "title='a > b' class='other mvRF3b more'", 'CLASS="mvRF3b"'):
    cases.append(("classroom-" + attrs,
                  '<a title="a > b" href="https://example.test/doc?authuser=0&amp;x=1#part"><img src="https://classroom.google.com/webthumbnail/x"><div ' + attrs + '>Title</div></a>',
                  '<ul><li><a href="https://example.test/doc?x=1#part">Title</a></li></ul>'))

failed = []
for name, source, expected in cases:
    expected_doc = json.loads(run(["pandoc", "--sandbox", "-f", "html", "-t", "json"], expected.encode()))
    wanted = signature(expected_doc)
    for target in ("gfm", "markdown", "commonmark"):
        try:
            output = run(["bash", "-c", 'set -o pipefail; source "$1"; convert_html "$2"',
                          "html-test", str(ROOT / "lib/pipeline.sh"), target], source.encode())
        except AssertionError as error:
            failed.append((name, target, str(error)))
            continue
        # Der GFM-Reader verlinkt URLs sogar innerhalb vorhandener Links erneut.
        # Hier werden explizite HTML-Links geprüft, keine bloßen Text-URLs.
        reader = {"gfm": "gfm-autolink_bare_uris", "commonmark": "commonmark+pipe_tables"}.get(target, target)
        actual = signature(json.loads(run(["pandoc", "-f", reader, "-t", "json"], output)))
        if actual != wanted:
            failed.append((name, target, output.decode(), repr(actual), repr(wanted)))
for failure in failed:
    print("FAIL:", *failure, sep="\n")
assert not failed, f"{len(failed)} HTML-Roundtrips fehlgeschlagen"
for raw in ('<!-- <div data-line="1" style="x">hidden</div><div></div> -->',
            '<script>const sample = \'<div data-line="1" style="x">literal</div>\';</script>'):
    for mode in ("claude_desktop", "google_classroom"):
        assert run(["bash", "-c", 'source "$1"; "preprocess_$2"',
                    "html-test", str(ROOT / "lib/pipeline.sh"), mode], raw.encode()) == raw.encode()
print(f"OK: {len(cases) * 3} HTML-Roundtrips und vier Rohtextprüfungen; Text, Code, Links, Auszeichnung, Listen und Tabellen erhalten")
