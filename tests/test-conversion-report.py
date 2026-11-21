#!/usr/bin/env python3
"""Konvertierungsbericht und strikte Abbrüche ohne Clipboard prüfen."""
import os
from pathlib import Path
import subprocess
import tempfile

ROOT = Path(__file__).resolve().parents[1]
with tempfile.TemporaryDirectory(prefix="md-clip-report-") as tmp:
    result_file = Path(tmp) / "result"
    source_file = Path(tmp) / 'RTF source with space'
    for data, valid in ((br'{\rtf1\ansi text}', True), (br'{\rtf1}', True),
                        (br'{\rtf1', True),
                        (b' ' * 4094 + br'{\rtf1\ansi text}', True),
                        (b'\xef\xbb\xbf' + b' ' * 10000 + br'{\rtf1\ansi text}', True),
                        (br'{\rtf1\bin4 '+b'\x00\xff\x01\x02}', True),
                        (b'plain', False), (b'<p>text</p>', False), (b' ' * 20000, False),
                        (br'{\rtf10\ansi text}', False), (br'{\rtf1broken}', False)):
        source_file.write_bytes(data);result_file.write_bytes(b'')
        p = subprocess.run(['bash','-c','source "$1"; check_rtf_header "$2"',
                            'rtf-header-test',str(ROOT/'lib/pipeline.sh'),str(source_file)],
                           env=dict(os.environ,MD_CLIP_RESULT_FILE=str(result_file)),capture_output=True,timeout=5)
        assert p.returncode == (0 if valid else 1), p.stderr
        assert not p.stdout and source_file.read_bytes() == data
        assert result_file.read_text() == ('' if valid else 'rtf-header-invalid\t1\n')

    def pipeline(function, data, strict=False, target="gfm", success=True):
        result_file.write_bytes(b"")
        env = dict(os.environ, MD_CLIP_RESULT_FILE=str(result_file), MD_CLIP_STRICT="1" if strict else "0")
        process = subprocess.run(["bash", "-c", 'set -o pipefail; source "$1"; rtf_to_html() { cat; }; "$2" "$3"',
                                  "report-test", str(ROOT / "lib/pipeline.sh"), function, target],
                                 input=data.encode(), capture_output=True, env=env, timeout=20)
        assert (process.returncode == 0) == success, process.stderr
        if not success:
            assert not process.stdout, process.stdout
        records = [line.split("\t") for line in result_file.read_text().splitlines()]
        assert all(len(record) == 2 and record[1].isdigit() for record in records), records
        return records, process.stdout

    table = '<table><tr><th>A</th><th>B</th></tr><tr><td>one<br>two</td><td><p>three</p><p>four</p></td></tr></table>'
    for target in ("gfm", "commonmark"):
        records, output = pipeline("convert_html", table, target=target)
        assert records == [["table-cells-flattened", "2"]], records
        assert b"one two" in output and b"three four" in output
        records, _ = pipeline("convert_html", table, strict=True, target=target, success=False)
        assert records == [["table-cells-flattened", "2"]], records
    records, _ = pipeline("convert_html", table, strict=True, target="markdown")
    assert not records
    for html, reason in (("<p>&nbsp;</p>", "empty-document"),
                         ("<strong>&nbsp;</strong>", "empty-document"),
                         ('<table><tr><td colspan="2">x</td></tr></table>', "table-spanned"),
                         ('<table><tr><td><table><tr><td>x</td></tr></table></td></tr></table>', "table-nested")):
        records, _ = pipeline("convert_html", html, success=False)
        assert records == [[reason, "1"]], records
    # Auch ohne AST sind die tatsächlichen Ausgabebytes zu prüfen.
    for writer_output in ("\u00a0", "\u200e", "\u2061", "  "):
        process = subprocess.run(["bash", "-c", 'source "$1"; tidy_markdown gfm --require-visible',
                                  "report-test", str(ROOT / "lib/pipeline.sh")],
                                 input=writer_output.encode(), capture_output=True, timeout=5)
        assert process.returncode == 1 and not process.stdout and not process.stderr
    layout = '<table><tr><td><p>first</p></td></tr></table><table><tr><td><p>second</p></td></tr></table>'
    records, output = pipeline("preprocess_rtf_html", layout)
    assert records == [["layout-tables-flattened", "2"]], records
    assert b"first" in output and b"second" in output and b"<table" not in output
    records, _ = pipeline("preprocess_rtf_html", layout, strict=True, success=False)
    assert records == [["layout-tables-flattened", "1"]], records
    nested = '<table><tr><td>outer<table><tr><td>inner</td></tr></table></td></tr></table>'
    records, _ = pipeline("preprocess_rtf_html", nested)
    assert records == [["layout-tables-flattened", "2"]], records
    records, _ = pipeline("convert_rtf", '<table><tr><td>layout</td></tr></table>' + table)
    assert records == [["layout-tables-flattened", "1"], ["table-cells-flattened", "2"]], records
    # Aufeinanderfolgende Stufen hängen an, statt die frühere Meldung zu verlieren.
    result_file.write_text("layout-tables-flattened\t1\n")
    env = dict(os.environ, MD_CLIP_RESULT_FILE=str(result_file), MD_CLIP_STRICT="0")
    p = subprocess.run(["bash", "-c", 'set -o pipefail; source "$1"; convert_html gfm',
                        "report-test", str(ROOT / "lib/pipeline.sh")], input=table.encode(),
                       capture_output=True, env=env, timeout=20)
    assert p.returncode == 0, p.stderr
    assert result_file.read_text() == "layout-tables-flattened\t1\ntable-cells-flattened\t2\n"
    # Beide Produzenten müssen einen defekten Berichtspfad melden, bevor
    # Markdown aus einer unvollständig protokollierten Konvertierung ankommt.
    env['MD_CLIP_RESULT_FILE'] = tmp
    for function, html in (("preprocess_rtf_html", layout), ("convert_html", table)):
        process = subprocess.run(["bash", "-c", 'set -o pipefail; source "$1"; "$2" gfm',
                                  "report-test", str(ROOT / "lib/pipeline.sh"), function],
                                 input=html.encode(), capture_output=True, env=env, timeout=20)
        assert process.returncode != 0 and not process.stdout
        assert "Konvertierungsbericht konnte nicht geschrieben werden.".encode() in process.stderr
print("OK: Berichtskennungen, Anzahlen, Anhängen und strikte Abbrüche vor Ausgabe")
