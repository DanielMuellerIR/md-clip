# Linux-Port: md-clip

Stand: 2026-07-05 · Ziel: `md-clip` läuft zusätzlich unter Linux (X11 UND Wayland) —
im selben Repo, über eine Plattform-Weiche im Skript. Kein separates Repo: die
Kern-Pipeline (pandoc + Perl-Preprocessing + Bash) ist bereits plattformneutral,
nur die Ränder (Clipboard, Notification, RTF-Konvertierung, Helper) sind macOS.

## Ausgangslage (verifiziert 2026-07-05)

- `bin/md-clip`: Bash-Hauptskript; macOS-Ränder: `pbpaste`/`pbcopy`, `osascript`
  (Notifications), `textutil` (RTF→HTML), `defaults` (Erstinstall-Detection).
- `helpers/clipboard-html.swift`, `helpers/clipboard-rtf.swift`: lesen die
  HTML-/RTF-Flavors des macOS-Pasteboards via NSPasteboard (kompiliert mit swiftc).
- Tests sind fixture-basiert (`tests/fixtures/*.html|rtf` + `compare.sh`) — die
  Konvertierungs-Pipeline ist damit OHNE Clipboard testbar → läuft auf Linux fast direkt.
- Dock-App/Wrapper (`wrappers/`, Automator) sind macOS-only und bleiben unangetastet.

## Architektur-Entscheidung

Eine Plattform-Abstraktion im Hauptskript, einmal am Start per `uname` entschieden:

| Funktion | macOS (bestehend) | Linux X11 | Linux Wayland |
|---|---|---|---|
| Clipboard HTML lesen | swift-Helper (NSPasteboard) | `xclip -selection clipboard -t text/html -o` | `wl-paste -t text/html` |
| Clipboard RTF lesen | swift-Helper | `xclip … -t text/rtf -o` | `wl-paste -t text/rtf` |
| Clipboard Text lesen/schreiben | pbpaste/pbcopy | xclip | wl-paste/wl-copy |
| RTF → HTML | `textutil` | pandoc (`-f rtf -t html`) | pandoc |
| Notification | osascript | `notify-send` | `notify-send` |
| Erstinstall-Flag | `defaults` | Datei unter `~/.config/md-clip/` | dito |

Wayland/X11 zur Laufzeit erkennen (`$WAYLAND_DISPLAY` gesetzt → wl-clipboard, sonst xclip).

## Phasen

### Phase 1 — Plattform-Weiche + Clipboard-Layer (~1–2 PT)
- In `bin/md-clip` Funktionen einziehen: `clip_read_html`, `clip_read_rtf`,
  `clip_read_text`, `clip_write_text`, `notify`, `state_get/state_set` — alle
  bestehenden Aufrufstellen darauf umstellen (reines Refactoring, Verhalten auf
  macOS unverändert — Fixture-Tests vorher/nachher grün).
- Linux-Zweige implementieren (Tabelle oben). Fehlt ein Tool → klare Fehlermeldung
  mit Installationshinweis (`sudo apt install xclip wl-clipboard pandoc libnotify-bin`).
- RTF-Pfad: pandoc statt textutil; mit `tests/fixtures/word-rtf.rtf` gegen die
  erwartete Ausgabe prüfen — WEICHEN pandoc-Ergebnisse ab, Erwartung pro Plattform
  parametrisieren statt die macOS-Fixtures zu ändern.
- **Erfolgskriterium:** `tests/run-tests.sh` grün auf macOS (unverändert) UND in einem
  Linux-Container (Fixture-Modus, ohne echtes Clipboard).

### Phase 2 — Echtes Clipboard Ende-zu-Ende auf Linux (~1 PT)
- Auf einem Linux-Desktop (X11 und Wayland je einmal): Browser-Auswahl kopieren →
  `md-clip` → Markdown liegt im Clipboard. Die realen Browser-Fixtures
  (safari-article, claude-desktop-codeblock, google-classroom-links) als manuelle
  Testfälle durchgehen; neue Linux-spezifische Eigenheiten (Firefox/Chromium-HTML-
  Flavors) als zusätzliche Fixtures einchecken.
- **Erfolgskriterium:** dokumentierte manuelle Testmatrix (2 Desktops × 2 Browser) ok.

### Phase 3 — Installation + CI (~1 PT)
- `install.sh` um Linux-Zweig erweitern (Dependency-Check, Symlink nach
  `~/.local/bin`); Brewfile bleibt macOS.
- GitHub-Actions-Job `ubuntu-latest`: Dependencies installieren, Fixture-Tests fahren.
- README: Linux-Abschnitt (Installation, Abhängigkeiten, bekannte Grenzen: keine
  Dock-App, kein System-Hotkey — Hotkey ist Desktop-Environment-Sache, nur dokumentieren).
- **Erfolgskriterium:** frische Linux-VM → `install.sh` → funktionierender Aufruf.

## Rahmenbedingungen

- Die Swift-Helper bleiben für macOS unverändert (KEIN Umbau auf „portable" Helper —
  auf Linux werden sie schlicht nie aufgerufen).
- Chirurgisch: Dock-App, Icon-Assets, DMG-Distribution nicht anfassen.
- Phasen als Junior-Dev-Briefs delegierbar (klare Funktionen, Fixture-Erfolgskriterien);
  Diff-Review vor Merge obligatorisch.
