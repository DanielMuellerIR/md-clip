#!/usr/bin/env python3
"""Bildpolitik über die gemeinsame Pipeline und alle Markdown-Ziele prüfen."""
import json
import os
from pathlib import Path
import subprocess
import tempfile

ROOT = Path(__file__).resolve().parents[1]


def nodes(value, kind):
    out = []
    if isinstance(value, dict):
        if value.get("t") == kind:
            out.append(value)
        for child in value.values():
            out.extend(nodes(child, kind))
    elif isinstance(value, list):
        for child in value:
            out.extend(nodes(child, kind))
    return out


with tempfile.TemporaryDirectory(prefix="md-clip-images-") as tmp:
    report = Path(tmp) / "result"

    def convert(html, mode, target, strict=False, success=True):
        report.write_bytes(b"")
        env = dict(os.environ, MD_CLIP_RESULT_FILE=str(report), MD_CLIP_IMAGES=mode,
                   MD_CLIP_STRICT="1" if strict else "0")
        p = subprocess.run(["bash", "-c", 'set -o pipefail; source "$1"; convert_html "$2"',
                            "image-test", str(ROOT / "lib/pipeline.sh"), target],
                           input=html.encode(), capture_output=True, env=env, timeout=20)
        assert (p.returncode == 0) == success, (mode, target, p.stderr)
        records = dict(line.split("\t") for line in report.read_text().splitlines())
        if not success:
            assert not p.stdout
            return None, records
        reader = {"gfm": "gfm-autolink_bare_uris", "commonmark": "commonmark+pipe_tables"}.get(target, target)
        parsed = subprocess.run(["pandoc", "-f", reader, "-t", "json"], input=p.stdout,
                                capture_output=True, check=True, timeout=20)
        return json.loads(parsed.stdout), records

    for target in ("gfm", "markdown", "commonmark"):
        doc, records = convert('<img src="x" alt="Diagramm">', "keep", target, strict=True)
        assert len(nodes(doc, "Image")) == 1 and not records
        for mode in ("keep", "alt", "omit"):
            doc, records = convert('<p>before <img src="https://example.invalid/a.png" alt="Diagramm"> after</p>', mode, target)
            assert len(nodes(doc, "Image")) == (1 if mode == "keep" else 0)
            text = [n["c"] for n in nodes(doc, "Str")]
            assert "before" in text and "after" in text
            assert ("Diagramm" in text) == (mode != "omit")
            assert records == ({} if mode == "keep" else {"images-" + ("alt" if mode == "alt" else "omitted"): "1"}), records
            linked = '<p><a href="https://example.invalid/target" title="Titel"><img src="https://example.invalid/a.png" alt="Logo"></a></p>'
            doc, _ = convert(linked, mode, target)
            links = nodes(doc, "Link")
            assert len(links) == 1 and links[0]["c"][2] == ["https://example.invalid/target", "Titel"], links
            svg = '<p>text</p><svg xmlns="http://www.w3.org/2000/svg" width="1" height="1"><rect width="1" height="1"/></svg>'
            doc, _ = convert(svg, mode, target)
            images = nodes(doc, "Image")
            assert len(images) == (1 if mode == "keep" else 0)
            if images:
                assert images[0]["c"][2][0].startswith("data:image/svg+xml;base64,")
            data_uri = 'data:image/png;base64,aGVsbG8='
            doc, _ = convert('<p>text<img src="' + data_uri + '" alt="Pixel"></p>', mode, target)
            images = nodes(doc, "Image")
            assert len(images) == (1 if mode == "keep" else 0)
            if images:
                assert images[0]["c"][2][0] == data_uri
            table = '<table><tr><th>A</th></tr><tr><td><img src="x" alt="Icon"></td></tr></table>'
            doc, _ = convert(table, mode, target)
            assert len(nodes(doc, "Table")) == 1
            code = '<pre><code>&lt;img src="x" alt="Y"&gt;\n\\# keep\\\n</code></pre>'
            doc, records = convert(code, mode, target, strict=True)
            assert nodes(doc, "CodeBlock")[0]["c"][1] == '<img src="x" alt="Y">\n\\# keep\\'
            assert not records
            doc, records = convert('<p>no image</p>', mode, target, strict=True)
            assert not records
            if mode != "keep":
                _, records = convert('<p>text<img src="x" alt="Y"></p>', mode, target, strict=True, success=False)
                assert records == {"images-" + ("alt" if mode == "alt" else "omitted"): "1"}
        doc, _ = convert('<img src="x" alt="Diagramm">', "alt", target)
        assert [n["c"] for n in nodes(doc, "Str")] == ["Diagramm"]
        for html, mode in [('<img src="x" alt="Diagramm">', "omit"), ('<img src="x">', "alt"), ('<img src="x">', "omit")]:
            _, records = convert(html, mode, target, success=False)
            assert records["empty-document"] == "1"
print("OK: Bildpolitik, Links/Titel, SVG/data-URLs, Tabellen, Code, Leere und Strict in drei Zielen")
