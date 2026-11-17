# md_clip

## Typ & Zweck
- **Typ:** CLI/Terminal-Tool
- **Zweck:** Wandelt formatierten Clipboard-Text in sauberes Markdown, per CLI, Dock-Klick oder Hotkey.
- **Plattform:** macOS (CLI + Dock-Wrapper) und Linux (CLI, X11 + Wayland)

## Arbeitsregeln

Produkt und Fixtures verwenden gemeinsam `lib/pipeline.sh`. Plattformdetails
gehören in den Plattformadapter. Export, Auswertung, Konvertierung und
Clipboard-Schreibzugriff bleiben getrennt. Code und SVG bei der Aufbereitung
erhalten. macOS und Linux verwenden dieselben Erwartungsdateien.

Vor Änderungen am betroffenen Pfad die einschlägigen Regeln lesen.

- [Konvertierung und plattformübergreifende Tests](AGENT-REFERENCE.md#konvertierung-und-plattformübergreifende-tests)
- [Version, Prüfung und Installation](AGENT-REFERENCE.md#version-prüfung-und-installation)
- [macOS-Oberfläche, Vorschau und Updates](AGENT-REFERENCE.md#macos-oberfläche-vorschau-und-updates)

## Verzeichnisstruktur

- [AGENTS.md](AGENTS.md) — Projektprofil, Arbeitsregeln und dieses Datei-Verzeichnis.
- [README.md](README.md) — Projekt-Einstieg und Nutzerdokumentation.
- [todo.md](todo.md) — offene Punkte, die eine Person von Hand erledigen muss.
- [docs/DISTRIBUTION.md](docs/DISTRIBUTION.md) — Projektdokumentation.
- [docs/ENCODING.md](docs/ENCODING.md) — Projektdokumentation.
- [docs/PREVIEW.md](docs/PREVIEW.md) — native Vorschau, Generation und Lebenszyklus.
- [docs/CONVERSION-REPORT.md](docs/CONVERSION-REPORT.md) — Ergebnisbewertung und strenger Modus.
- [docs/CONVERSION.md](docs/CONVERSION.md) — Quellenwahl, Inhaltsgrenzen und prüfbare Konvertierungsbeispiele.
- [docs/SPARKLE-RELEASE.md](docs/SPARKLE-RELEASE.md) — Sparkle-Updates bauen, signieren und veröffentlichen.
- [docs/archive/BLUEPRINT.md](docs/archive/BLUEPRINT.md) — Projektdokumentation.
- `assets/` — Projektbestandteil; Details stehen im Code bzw. in der verlinkten Dokumentation.
- `bin/` — Projektbestandteil; Details stehen im Code bzw. in der verlinkten Dokumentation.
- `docs/` — Projektbestandteil; Details stehen im Code bzw. in der verlinkten Dokumentation.
- `helpers/` — Projektbestandteil; Details stehen im Code bzw. in der verlinkten Dokumentation.
- `lib/` — gemeinsame, seiteneffektfreie Konvertierungs-Pipeline.
- `tasks/` — Projektbestandteil; Details stehen im Code bzw. in der verlinkten Dokumentation.
- `tests/` — Projektbestandteil; Details stehen im Code bzw. in der verlinkten Dokumentation.
- `wrappers/` — Projektbestandteil; Details stehen im Code bzw. in der verlinkten Dokumentation.
