# Verifikation und Laufzeiten

Stand: 2026-09-05. Vergleich: Ausgangsrevision `638b9b5` gegen Version 1.3.0.

## Messverfahren

Je fünf Läufe, Median der Wandzeit in Millisekunden; gleicher Rechner und
pandoc 3.9.0.2. Die Eingaben stehen im Benchmark-Skript: Artikel- und Code-
Fixtures, Word-RTF-Fixture, 450.000 Byte synthetisches HTML und 20 synthetische
Word-HTML-Tabellen. Kein Clipboard-Zugriff. Einzelstufen starten jeweils eine
neue Bash; ihre Zeiten lassen sich wegen Pipeline-Parallelität nicht addieren.

`python3 tests/benchmark.py --repo PFAD --runs 5` misst denselben Vertrag
gegen einen anderen Checkout. Rohwerte: `before.json` und `after.json`.

| Eingabe / Aufruf | Vorher ms | Nachher ms | Änderung |
|---|---:|---:|---:|
| CLI --help (Start ohne Konverter) | 19.11 | 16.20 | -15.2% |
| CLI --version (mit pandoc-Version) | 42.36 | 42.62 | +0.6% |
| Artikel | 37.13 | 39.34 | +6.0% |
| Word-RTF | 61.10 | 75.54 | +23.6% |
| Code-Fixture | 35.10 | 38.04 | +8.4% |
| 450 KB HTML | 583.21 | 539.24 | -7.5% |
| Word-HTML-Tabellen | 34.50 | 50.42 | +46.1% |

Die große Eingabe benötigt in `tidy_markdown` 121.54 → 88.73 ms.
Der Vorabtest auf behandelbare Escapes spart den zeichenweisen Durchlauf bei
gewöhnlichen Absätzen. Drei Claude-Perl-Prozesse wurden zu einem vereinigt;
elf Eingaben einschließlich NUL-/div-Sample lieferten im unabhängigen Vergleich
bytegleichen Output. Der Tabellenscan benötigt keine temporäre Datei und
aktiviert Lua nur bei möglichen Tabellen-Tags. Die Darstellbarkeitsprüfung
selbst erfolgt ausschließlich in pandocs Dokumentstruktur.

Kleine Eingaben und Tabellen werden durch die zusätzliche Prüfung teilweise
langsamer. Diese Mehrkosten sind ausgewiesen; eine pauschale Beschleunigung
wird nicht behauptet. Der Lua-Prototyp wird ausschließlich für Tabellen
übernommen: Er erkennt echte Verschachtelungen, Kommentare und Attribute
korrekt und benötigt keinen zweiten pandoc-Prozess. Allgemeine HTML-Bereinigung
bleibt unverändert. `blocks_to_inlines` wurde verworfen, weil Zitate wieder
LineBreaks erzeugten und Listenpunkte verklebten; der begrenzte rekursive
Zellfilter ist durch Roundtrips abgesichert.

## Prüfungen

- macOS/pandoc 3.9.0.2: 40/40 Fixture-Tests ohne Host-Clipboard.
- Ubuntu 24.04/pandoc 3.1.3: 40/40 Fixtures; Xvfb/X11 und headless sway/Wayland
  jeweils 43/43, einschließlich UTF-16-Clipboard.
- Alle vier `test-*.sh` auf beiden Systemen bestanden.
- CLI-Verträge: drei Backend-Attrappen auf macOS, beide Linux-Backends im
  Container; strikte Quellen, Rich-Fallback, NUL-/Newline-Bytes, Doctor ohne
  Inhalte, verschachtelte und verbundene Zellen, mehrzeilige Tags und Literal
  `[TABLE]`. Tabellen-Roundtrips prüfen Zeilen, Zellen und Text.
- Vorschau: isoliertes Terminal prüft Bestätigung, Ablehnung und EOF.
- Unsignierter vollständiger macOS-Build in temporärem Verzeichnis: Bundle-
  Prüfung bestanden, Ressourcen bytegleich, eingebettete CLI konvertiert
  Tabellenzellen. Kein Start einer GUI, keine Signierung oder Installation.
- Unabhängiges Review der Pipeline/CLI und der Performance-Änderungen:
  Funde korrigiert und nachgeprüft; keine offenen Review-Befunde.
- Expected-Fixtures unverändert. macOS-CI und Wayland-CI ergänzt; entfernte
  CI-Läufe wurden nicht ausgelöst.

## Grenzen

Ein einmaliges Undo ist nicht implementiert. Der konkrete Folgeplan steht in
`docs/CLIPBOARD-UNDO.md`. Der echte Browser-Klickweg bleibt ein manuelles Todo.
Der Testrunner behandelt `--help` ohne Teststart. Fixture-Läufe ohne Clipboard
verwenden ausdrücklich `MD_CLIP_SKIP_CLIPBOARD=1`.
