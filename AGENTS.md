# md_clip

## Typ & Zweck
- **Typ:** CLI/Terminal-Tool
- **Zweck:** Wandelt formatierten Clipboard-Text in sauberes Markdown, per CLI, Dock-Klick oder Hotkey.
- **Plattform:** macOS (CLI + Dock-Wrapper) und Linux (CLI, X11 + Wayland)

## Arbeitsregeln

- **Plattform-Weiche:** Alles Plattformabhängige gehört in den Abschnitt
  „Plattform-Weiche" in `bin/md-clip` (`clip_read_*`, `clip_write_text`,
  `rtf_to_html`, `notify`). Der Rest des Skripts bleibt plattformneutral.
  Erkennung über `uname -s` und `$WAYLAND_DISPLAY` — **nicht** über `$DISPLAY`,
  das ist unter Wayland (XWayland) ebenfalls gesetzt.
- **`tests/run-tests.sh` dupliziert die Pipeline-Funktionen aus `bin/md-clip`**
  (bewusster Trade-off, dort kommentiert). Wer eine dieser Funktionen ändert,
  muss die Kopie mitziehen.
- **Beide Plattformen laufen gegen dieselben Erwartungsdateien.** Wenn ein
  Linux-Ergebnis abweicht, ist das ein Befund — nicht der Anlass, eine zweite
  Erwartung einzuführen. Expected-Dateien nie still regenerieren.
- **Vor Linux-Änderungen testen:** `./tests/run-tests.sh` (macOS) und ein
  Linux-Lauf. Rezept für den Container-Lauf ohne fremde Systeme anzufassen:
  `tasks/2026-07-05-linux-port/plan.md`.
- **macOS-only und unangetastet lassen:** `wrappers/` (Dock-App, Automator),
  `assets/` (Icons, DMG), `helpers/*.swift`.

## Verzeichnisstruktur

<!-- directory-structure: generated -->
- [AGENTS.md](AGENTS.md) — Projektprofil, Arbeitsregeln und dieses Datei-Verzeichnis.
- [README.md](README.md) — Projekt-Einstieg und Nutzerdokumentation.
- [docs/DISTRIBUTION.md](docs/DISTRIBUTION.md) — Projektdokumentation.
- [docs/ENCODING.md](docs/ENCODING.md) — Projektdokumentation.
- [docs/archive/BLUEPRINT.md](docs/archive/BLUEPRINT.md) — Projektdokumentation.
- `assets/` — Projektbestandteil; Details stehen im Code bzw. in der verlinkten Dokumentation.
- `bin/` — Projektbestandteil; Details stehen im Code bzw. in der verlinkten Dokumentation.
- `docs/` — Projektbestandteil; Details stehen im Code bzw. in der verlinkten Dokumentation.
- `helpers/` — Projektbestandteil; Details stehen im Code bzw. in der verlinkten Dokumentation.
- `spike/` — Projektbestandteil; Details stehen im Code bzw. in der verlinkten Dokumentation.
- `tasks/` — Projektbestandteil; Details stehen im Code bzw. in der verlinkten Dokumentation.
- `tests/` — Projektbestandteil; Details stehen im Code bzw. in der verlinkten Dokumentation.
- `wrappers/` — Projektbestandteil; Details stehen im Code bzw. in der verlinkten Dokumentation.
<!-- /directory-structure -->
