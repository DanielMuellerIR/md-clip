# Changelog

## 1.1.1 — 2026-07-22

- macOS 11/12: Symlink-Auflösung ohne das erst ab macOS 13 verfügbare `realpath`.
- Classroom-Anhänge werden gezielt gruppiert, ohne bestehende geordnete Listen
  in ungeordnete Listen umzuschreiben.
- Leere HTML-Links werden vor pandoc ergänzt; URLs mit Klammern, Escapes und
  Link-Titeln bleiben intakt.
- Plain-Text bleibt einschließlich aller abschließenden Newlines bytegenau.
- Produkt und Fixtures verwenden dieselbe Pipeline aus `lib/pipeline.sh`;
  Clipboard-Helper entstehen in einem privaten Testlayout statt im Checkout.
- Linux und Installer prüfen den tatsächlichen pandoc-RTF-Reader (mindestens
  pandoc 2.14.2); unsichere Installationsziele werden nicht überschrieben.
- Bundle-Downloads und pandoc-COPYRIGHT sind per SHA-256 gepinnt und atomar
  gecacht; das Release-Skript löst nur sein eigenes DMG-Device.
- Launcher-Pfade werden nicht mehr in AppleScript-/Shell-Quelltext interpoliert.
- Der überholte ausführbare Spike wurde als historischer Text archiviert.
