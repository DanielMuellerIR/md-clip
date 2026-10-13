"""Zellstruktur der beiden Tabellen-Roundtrips prüfen."""
import json
import sys


def text(value):
    if isinstance(value, list):
        return "".join(text(item) for item in value)
    if not isinstance(value, dict):
        return ""
    kind = value.get("t")
    if kind == "Str":
        return value["c"]
    if kind in ("Space", "SoftBreak"):
        return " "
    if kind == "LineBreak":
        return "\n"
    return text(value.get("c", []))


document = json.load(sys.stdin)
tables = [block["c"] for block in document["blocks"] if block["t"] == "Table"]
assert len(tables) == 1, "Genau eine Tabelle erwartet"
table = tables[0]
rows = table[3][1] + [row for body in table[4] for row in body[2] + body[3]] + table[5][1]
mode = sys.argv[1]
assert len(rows) == (2 if mode == "simple" else 4)
cells = [row[1] for row in rows]
assert all(len(row) == 2 for row in cells), "Zellgrenzen verändert"
blocks = [[cell[4] for cell in row] for row in cells]
values = [[" ".join(text(block) for block in cell) for cell in row] for row in blocks]
if mode == "simple":
    assert values == [["A", "B"], ["x|y", "ok"]], values
else:
    expected = [["Spalte", "Wert"], ["Pipe | und Raute #", "ok"],
                ["Erste Zeile\nZweite Zeile" if mode == "markdown" else "Erste Zeile Zweite Zeile", "zwei"],
                ["Absatz eins Absatz zwei", "drei"]]
    assert values == expected, values
    assert len(blocks[3][0]) == (2 if mode == "markdown" else 1), "Absatzgrenzen verändert"
