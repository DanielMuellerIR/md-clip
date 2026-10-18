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
            elif kind == "Code":
                found[kind].append(content[-1])
            elif kind == "CodeBlock":
                found[kind].append([content[0][1], content[-1]])
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
for suffix in ('\x00', '\x00\x00'):
    for source in ('<p>Hallo ä😀</p>', '<pre><code>  command\\\n</code></pre>'):
        cases.append(('terminal-nul-' + repr(suffix) + source, source + suffix, source))
for attrs in ('title="a > b"', "title='a > b'", 'title="a &gt; b"',
              'class="x" title="a > b" data-note="kept"',
              'title="data-line=\'7\' > style=\'x\'"',
              'title="a >\nb"', 'TITLE="a > b"'):
    cases.append(("span-" + attrs, '<p><span ' + attrs + '>Hallo</span></p>', '<p>Hallo</p>'))
cases.extend([
    ("preformatted-text", '<pre>  printf "%s" \\\n    "\\# literal"\n\n  next\\\n</pre>',
     '<pre><code>  printf "%s" \\\n    "\\# literal"\n\n  next\\\n</code></pre>'),
    ("preformatted-spans", '<pre><span title="a > b"># literal ☀</span>\n<span><span>  | x | y | \\#</span></span></pre>',
     '<pre><code># literal ☀\n  | x | y | \\#</code></pre>'),
    ("preformatted-br", '<pre><span>one</span><br style="color:red" class="x"><span>  two</span></pre>',
     '<pre><code>one\n  two</code></pre>'),
    ("preformatted-list", '<ul><li>before<pre><span>  one\n    two</span></pre>after</li></ul>',
     '<ul><li>before<pre><code>  one\n    two</code></pre>after</li></ul>'),
    ("existing-code-language", '<pre><code class="language-python">  print("☀")\n</code></pre>',
     '<pre><code class="language-python">  print("☀")\n</code></pre>'),
    ("preformatted-link", '<pre><a href="https://example.test/pre" title="TARGET">one\ntwo</a></pre>',
     '<pre><a href="https://example.test/pre" title="TARGET">one\ntwo</a></pre>'),
    ("preformatted-image", '<pre>before <img src="x.png" alt="ICON"> after</pre>',
     '<pre>before <img src="x.png" alt="ICON"> after</pre>'),
    ("nested-pre-unchanged", '<pre>one<pre>two</pre>three</pre>',
     '<pre>one<pre>two</pre>three</pre>'),
    ("nested-spans", '<p><span title="a > b">A <span><strong>B</strong></span> C</span></p>', '<p>A <strong>B</strong> C</p>'),
    ("significant-space", '<p><strong>A</strong><span title="a > b"> </span><em>B</em></p>', '<p><strong>A</strong> <em>B</em></p>'),
    ("comment", '<!-- <span title="a > b">hidden</span> --><p>visible</p>', '<p>visible</p>'),
    ("literal-code", '<pre><code>&lt;span title="a &gt; b" style="x"&gt;\n\\# keep\\\n</code></pre>', '<pre><code>&lt;span title="a &gt; b" style="x"&gt;\n\\# keep\\\n</code></pre>'),
    ("attribute-lookalike", '<div title=" data-line=\'1\' style=\'x\' >">A</div><p>B</p>', '<p>A</p><p>B</p>'),
    ("table-spans", '<table><tr><th>A</th><th>B</th></tr><tr><td><span title="a > b">eins</span></td><td><strong>zwei</strong></td></tr></table>', '<table><tr><th>A</th><th>B</th></tr><tr><td>eins</td><td><strong>zwei</strong></td></tr></table>'),
    ("heading", '<h2><span title="a > b">Titel</span></h2>', '<h2>Titel</h2>'),
])
for literal in ('{#literal}', '{.literal}', '{key="value"}',
                '{#literal .class key="value"}', '{#literal} tail', '{braces}', '{', '\\{#literal}'):
    source = '<h2>Heading ' + literal + '</h2>'
    cases.append(('literal-heading-' + literal, source, source))
cases.extend([
    ('formatted-heading-attribute', '<h2>Heading <em>{#literal}</em></h2>',
     '<h2>Heading <em>{#literal}</em></h2>'),
    ('heading-code-attribute', '<h2>Heading <code>{#literal}</code></h2>',
     '<h2>Heading <code>{#literal}</code></h2>'),
    ('heading-real-and-literal-attribute', '<h2 id="real">Heading {#literal}</h2>',
     '<h2 id="real">Heading {#literal}</h2>'),
])
for tag in ('ol', 'ul'):
    for code in ('command', '  command'):
        source = '<' + tag + '><li>before</li><li><pre><code>' + code + '</code></pre></li></' + tag + '>'
        cases.append(('list-unlabelled-code-' + tag + code, source, source))
    for wrapper in ('{}', '<blockquote>{}</blockquote>', '<ul><li>{}</li></ul>'):
        code = "  printf '%s' \\\n    '\\# keep'\n\n  \\- keep"
        source = wrapper.format('<' + tag + '><li>before</li><li><pre><code>' + code + '</code></pre></li><li>after</li></' + tag + '>')
        cases.append(('list-multiline-code-' + tag + wrapper, source, source))
for name, source in (
    ('literal-backslash-hash', '<p>Text \\# behalten</p>'),
    ('leading-backslash-hash', '<p>\\# behalten</p>'),
    ('nbsp-backslash-hash', '<p>&nbsp; \\# behalten</p>'),
    ('double-backslash-hash', '<p>Text \\\\# behalten</p>'),
    ('adjacent-backslash-hashes', '<p>Text \\## behalten</p>'),
    ('heading-backslash-hash', '<h2>Text \\# behalten</h2>'),
    ('list-backslash-hash', '<ul><li>\\# behalten</li></ul>'),
    ('quote-backslash-hash', '<blockquote><p>\\# behalten</p></blockquote>'),
    ('table-backslash-hash', '<table><tr><th>A</th><th>B</th></tr><tr><td>\\# behalten</td><td>Nachbar</td></tr></table>'),
    ('link-backslash-hash', '<p><a href="https://example.test/\\#ziel" title="\\# Titel">\\# behalten</a></p>'),
    ('image-backslash-hash', '<p><img src="image.png" alt="\\# behalten" title="\\# Titel"></p>'),
    ('code-backslash-hash', '<p><code>\\# behalten</code></p><pre><code>  \\# behalten\n</code></pre>'),
):
    cases.append((name, source, source))
for count in (2, 3):
    literal = '\\' * count + '#'
    source = ('<p><a href="https://example.test/' + literal + 'ziel" title="' + literal
              + ' Titel">Link</a><img src="image.png" alt="Bild" title="' + literal + ' Titel"></p>')
    cases.append(('target-backslash-run-' + str(count), source, source))
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
for src in ('HTTPS://CLASSROOM.GOOGLE.COM/webthumbnail/x', '//classroom.google.com/webthumbnail?x=1'):
    cases.append(("classroom-url-" + src,
                  '<a href="https://example.test/doc"><img src="' + src + '"><div class="mvRF3b">Title</div></a>',
                  '<ul><li><a href="https://example.test/doc">Title</a></li></ul>'))
for href, cleaned in (
    ('', ''), ('?authuser=0&amp;authuser=1', ''),
    ('https://example.test/doc?x=1&amp;authuser=0&amp;y=2', 'https://example.test/doc?x=1&amp;y=2'),
    ('https://example.test/doc?authuser=0&amp;authuser=1&amp;x=2', 'https://example.test/doc?x=2'),
    ('https://example.test/doc#section?authuser=0', 'https://example.test/doc#section?authuser=0'),
    ('https://example.test/doc?x=1#section&amp;authuser=0', 'https://example.test/doc?x=1#section&amp;authuser=0'),
    ('https://example.test/doc?x=1&amp;authuser=0#part?authuser=inside', 'https://example.test/doc?x=1#part?authuser=inside')):
    cases.append(("classroom-query-" + href,
                  '<a href="' + href + '"><img src="https://classroom.google.com/webthumbnail/x"><div class="mvRF3b">Title</div></a>',
                  '<ul><li><a href="' + cleaned + '">Title</a></li></ul>'))

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
        if name == 'heading-real-and-literal-attribute' and target == 'markdown':
            parsed = json.loads(run(["pandoc", "-f", reader, "-t", "json"], output))
            assert parsed['blocks'][0]['c'][1][0] == 'real', 'Echte Überschrifts-ID verändert'
        if actual != wanted:
            failed.append((name, target, output.decode(), repr(actual), repr(wanted)))
for failure in failed:
    print("FAIL:", *failure, sep="\n")
assert not failed, f"{len(failed)} HTML-Roundtrips fehlgeschlagen"
raw_cases = ['<!-- <div data-line="1" style="x">hidden</div><div></div> -->',
             '<script>const sample = \'<div data-line="1" style="x">literal</div>\';</script>',
             '<pre><code>before\x00after</code></pre>',
             '<svg><text>before\x00after</text></svg>']
for tag in ('textarea','title','script','style'):
    content = '<td rowspan="0"><div data-line="1" style="x">☀</div><div></div><li data-md-clip-classroom="1">literal</li>'
    raw_cases.extend(['<'+tag+'>'+content+'</'+tag+'>', '<'+tag.upper()+'>'+content+'</'+tag.upper()+' >', '<'+tag+'>'+content])
for raw in raw_cases:
    for mode in ("claude_desktop", "google_classroom"):
        assert run(["bash", "-c", 'source "$1"; "preprocess_$2"',
                    "html-test", str(ROOT / "lib/pipeline.sh"), mode], raw.encode()) == raw.encode()
unfinished = ('<svg>' * 30000 + 'end').encode()
for mode in ('claude_desktop','google_classroom'):
    assert run(['bash','-c','source "$1"; "preprocess_$2"',
                'html-test',str(ROOT/'lib/pipeline.sh'),mode],unfinished) == unfinished
tidy_cases = []
for depth in (1, 2, 3):
    prefix = '> ' * depth
    for decoration in ('', '****'):
        source = prefix + decoration + '\\\n' + prefix + r'Text \# bleiben' + '\n'
        expected = prefix.rstrip() + '\n' + prefix + 'Text # bleiben\n'
        tidy_cases.append((source, expected))
    source = prefix + '```\n' + prefix + '\\\n' + prefix + '```\n'
    tidy_cases.append((source, source))
for source, expected in tidy_cases:
    for target in ('gfm', 'markdown', 'commonmark'):
        result = subprocess.run(['perl', str(ROOT/'lib/tidy-markdown.pl'), target],
                                input=source.encode(), capture_output=True, timeout=20)
        assert result.returncode == 0 and not result.stderr, result.stderr
        assert result.stdout == expected.encode(), (target, source, result.stdout)
print(f"OK: {len(cases) * 3} HTML-Roundtrips, {len(raw_cases)*2} Rohtextprüfungen, {len(tidy_cases)*3} Markdown-Prüfungen und unvollständige SVG-Eingaben; Text, Code, Links, Auszeichnung, Listen und Tabellen erhalten")
