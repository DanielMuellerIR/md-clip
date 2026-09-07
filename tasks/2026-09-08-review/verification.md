# Review-Korrekturen 1.3.1

## Befunde und Nachweis

- Formatierte unsichtbare Zeichen: Die Vorversion liefert für
  `<p><strong>&lrm;</strong></p>` Exit 0 und Markdown mit ausschließlich
  unsichtbarem Nutzinhalt. `lib/tables.lua` prüft jetzt Textknoten vor dem
  Writer mit den Unicode-Eigenschaften von Perl. HTML-Metadaten zählen nicht;
  Bilder, Tabellen und Trennlinien zählen als sichtbare Elemente.
- stdout-Schreibfehler: Ein nur lesbarer Ausgabedeskriptor liefert vorher
  Exit 1, jetzt wie dokumentiert Exit 3. `bin/md-clip` fängt den Fehler ab.
- `try_html` und `try_rtf`: Keine Aufrufer im Repository; Definitionen und
  überholte Kommentare entfernt.

`tests/test-cli-inputs.py` prüft formatierte unsichtbare Zeichen, Codeblöcke,
HTML-Titel, alle drei Ausgabeformate, sichtbare Gegenbeispiele sowie Auto-Fallback
und unverändertes Clipboard bei expliziter HTML-Quelle. Die isolierte Runtime
enthält echte Konverter und Attrappen für die Clipboard-Werkzeuge.

## Verifikation am 2026-09-08

- macOS, pandoc 3.9.0.2: `MD_CLIP_SKIP_CLIPBOARD=1 bash tests/run-tests.sh`
  besteht mit 40/40; echtes Host-Clipboard bewusst übersprungen.
- macOS: alle vier `tests/test-*.sh` einschließlich nativer Wrapper-/Bundle-,
  Swift-, AppleScript- und Signaturprüfungen bestanden.
- macOS: `python3 tests/test-cli-inputs.py` besteht mit Darwin-, X11- und
  Wayland-Attrappen und den Terminaltests für die Vorschau.
- Ubuntu 24.04 im isolierten Container, pandoc 3.1.3: 40/40 ohne Display,
  43/43 über Xvfb und 43/43 über den isolierten Wayland-Compositor.
- Ubuntu: alle vier Shell-Testskripte und die CLI-Vertragstests bestanden.
  macOS-spezifische Swift-/AppKit-/CryptoKit-Tests werden dort übersprungen.
- Erwartungsdateien unverändert; keine Signierung, Notarisierung, Installation
  oder Veröffentlichung im Rahmen dieser Korrekturen.
