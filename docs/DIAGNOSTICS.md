# Doctor-Diagnose

`md-clip --doctor` zeigt die lokale Werkzeug- und Sitzungsbereitschaft.
`md-clip --doctor --json` liefert dieselben Angaben maschinenlesbar. Der Befehl
behält Exit 0 auch bei gemeldeten Problemen; ungültige Aufrufe liefern Exit 2.
Die vorhandenen JSON-Felder bleiben erhalten. Neue Felder sind additiv.

## Datenschutz und Bedeutung

Doctor liest oder schreibt keine Clipboard-Formate, startet keinen Undo-Daemon
und keine GUI. Er fragt Werkzeugversionen ab, führt eine synthetische lokale
Tabellenkonvertierung durch und prüft Sitzungsmetadaten. Unter X11 wird eine
Verbindung mit XFixes geprüft; unter Wayland werden Registry und Seat-Angebot
abgefragt, ohne ein Data-Control-Gerät für Clipboard-Angebote zu binden.
Unter macOS werden Konsolensitzung und Benutzer anhand von CoreGraphics-Metadaten
geprüft, ohne auf NSPasteboard zuzugreifen.

`undo` meldet die Bereitschaft des Helfers. Es sagt nichts über eine vorhandene,
noch gültige Undo-Sicherung aus. Doctor prüft keine versprochenen Nutzdaten,
Größenlimits oder die spätere Stabilität eines Clipboard-Eigentümers.

## JSON-Ergänzungen, diagnostics_version 1

- `session`: `status` ist `ready`, `unavailable`, `unsupported` oder `unverified`;
  `code` ist `ok` oder eine feste Diagnosekennung. Fehlende Bibliotheken/Helfer
  verhindern eine Prüfung und ergeben `unverified`.
- `clipboard_tools`: Verfügbarkeit des Lesewerkzeugs bzw. Schreibwerkzeugs des
  gewählten Backends. Dies prüft unabhängig von der Sitzungsverbindung.
- `capabilities`: `plain_input`, `html_conversion`, `rtf_conversion`,
  `clipboard_read` und `clipboard_replace`. Die Konvertierung berücksichtigt
  Perl, Sandbox und den gemeinsamen Lua-Filter; RTF verwendet unter macOS
  textutil, unter Linux pandocs RTF-Reader.
- `clipboard_read` ist `null`, wenn Werkzeuge vorhanden sind, die Sitzung aber
  nicht ausreichend geprüft werden konnte. Ein fehlendes XFixes oder ungeeignetes
  Data-Control blockiert Undo, beweist jedoch nicht, dass ein anderes Lesewerkzeug
  ebenfalls scheitern muss. `clipboard_replace` benötigt ein Schreibwerkzeug und
  einen bereiten Undo-Helfer.
- `diagnostics`: Liste aus `code`, `severity` (`error`/`warning`), `message` und
  `next_step`. Nur `code` ist die stabile Maschinenkennung; Meldungstexte dürfen
  sich verbessern. Unbekannte Helferausgaben werden als `undo-helper-failed`
  behandelt und nicht ungefiltert in die Diagnose übernommen.

Werkzeugversionen sind auf eine kurze Zeile begrenzt und JSON-maskiert. Es werden
keine Dokumenttitel, URLs, Clipboard-Texte oder Sitzungsinhalte ausgegeben.

## Kennungen

| Kennung | Ursache / nächster Schritt |
|---|---|
| `pandoc-missing`, `pandoc-unusable` | pandoc fehlt oder startet nicht; Installation prüfen |
| `pandoc-no-sandbox` | Erforderliche Sandbox fehlt; aktuelles pandoc installieren |
| `pandoc-no-rtf` | Linux-RTF-Reader fehlt; pandoc mit RTF-Unterstützung verwenden |
| `table-filter-unavailable` | Synthetische Filterprüfung scheitert; Perl, lib-Ressourcen und pandoc prüfen |
| `perl-missing`, `textutil-missing` | Werkzeug des Rich-Text-Wegs fehlt |
| `html-helper-missing`, `rtf-helper-missing` | macOS-Lesehelfer fehlt; install.sh oder vollständige App verwenden |
| `clipboard-read-tool-missing`, `clipboard-write-tool-missing` | Werkzeug des gewählten Backends fehlt; xclip bzw. wl-clipboard installieren |
| `undo-helper-missing`, `undo-helper-failed` | Helfer fehlt, startet nicht oder liefert eine ungültige Diagnose |
| `python-missing`, `python-unsupported` | Linux-Helfer benötigt Python 3.8 oder neuer |
| `local-security-unsupported` | Sichere lokale Linux-Verbindungen werden nicht unterstützt |
| `x11-libraries-missing` | libX11/libXfixes fehlt oder ist nicht ladbar |
| `x11-session-missing`, `x11-connect-failed` | DISPLAY fehlt oder die Sitzung ist nicht erreichbar; grafische Sitzung/Berechtigung prüfen |
| `x11-xfixes-missing` | Server unterstützt XFixes nicht; Undo braucht einen geeigneten Server |
| `wayland-runtime-missing`, `wayland-connect-failed` | Sitzungsumgebung fehlt oder ist nicht erreichbar |
| `wayland-data-control-missing` | Compositor braucht ext_data_control_manager_v1 oder zwlr_data_control_manager_v1 |
| `wayland-seat-unsupported` | Undo unterstützt genau einen Seat |
| `runtime-unsafe` | XDG_RUNTIME_DIR fehlt, gehört einem anderen Benutzer oder ist nicht privat (0700) |
| `macos-session-missing` | Keine aktive Konsolensitzung für diesen Benutzer erkennbar |

Die Prüfung ist eine Momentaufnahme. Ein anschließender Clipboard-Zugriff kann
weiterhin scheitern, etwa bei wechselnden Eigentümern oder blockierenden Daten.
