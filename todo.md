# md_clip — Todos

## Aus der Handoff-Frontier übernommen (2026-08-29)

- Die beiden Reviews vom 2026-08-19 sind mit dem aktuellen Code abgeglichen:
  15 Funde im ersten und sechs im zweiten Review. Zitatlisten, HTML-Attributfolge
  und direkte Signaturprüfung der Clipboard-Helfer sind in 1.4.0 korrigiert.
  Frühere Fixes wurden nicht erneut umgesetzt. Noch offen sind:
  - Ein fehlendes Icon bleibt beim App-Build bewusst optional; eine Änderung
    braucht eine Produktentscheidung.
  Zwei nur paraphrasiert erhaltene Installationsfunde lassen sich ohne
  ursprüngliche Reproduktion nicht als aktuelle Fehler bestätigen.

Die beiden Linux-Funde sind in 1.4.1 korrigiert: Homebrew-Pfade ergänzt die CLI
nur auf macOS; Linux behält den vom Aufrufer gewählten Suchpfad. Die Linux-CI
verwendet Ubuntu 24.04 und prüft vor den Tests pandoc 3.1.3. Paketkorrekturen
der Distribution bleiben möglich; eine andere pandoc-Version bricht den Lauf
mit einer klaren Diagnose ab. Die gezielten PATH-Verträge stehen in
`tests/test-dependencies.sh`.

Der Icon-Cleanup-Eintrag war überholt: `assets/build-icns.sh` räumt seit
`cc524b9` über den EXIT-Trap auch bei gewöhnlichen Fehlern auf. Isolierte
Fehlerproben für Skalierung und `iconutil` bestätigen die Bereinigung.

Die Compare-/Testskript-Funde sind korrigiert: `compare-file.sh` baut Loader und
beide Lesehelfer in einem privaten Laufzeitverzeichnis. `compare.sh` bricht bei
Konvertierungsfehlern mit deren Exit-Code ab und speichert auch identische
manuelle Apple-Markdown-Ausgabe einschließlich Schluss-LFs. Die isolierten
Verträge stehen in `tests/test-compare.py`. `tests/test-plain-newlines.sh` prüft
vier LF-Varianten über macOS/X11/Wayland-Attrappen sowie Leertext mit exakt Exit 1,
ohne stdout-Ausgabe oder Clipboard-Ersetzung. Die macOS-Matrix läuft auf macOS.

## Aus dem Code-Review und der CodeQA-Kampagne 2026-09-03

- **Toter Worktree im Repo-Verzeichnis.** `.claude/worktrees/festive-greider-8d3ac0/`
  ist ein Arbeitsbaum vom 2026-05-19; das Repo, zu dem er gehörte, gibt es nicht
  mehr, `git worktree list` kennt ihn nicht, und der globale gitignore blendet
  `.claude/` aus. Er enthält einen alten Projektstand (736 KB, noch mit
  `BLUEPRINT.md` im Wurzelverzeichnis). Nicht gelöscht — bitte einmal ansehen
  und dann wegräumen oder behalten.

- **Alter AppleScript-Applet-Ordner.** `wrappers/md-clip.app/` liegt ungetrackt
  im Arbeitsbaum und wird von `.gitignore` als „früherer Ausgabeort" geführt.
  Der heutige Build schreibt nach `build/md-clip.app`. Ebenfalls nicht gelöscht.

## Release-Lücke nach 1.2.9

- Entscheiden, welche Version nach dem bestehenden Tag `v1.3.0` veröffentlicht
  werden soll; der aktuelle Implementierungsstand ist 1.4.0. Für die gewählte Version
  ein notarisiertes DMG mit festgelegtem Finder-Layout (oder ausdrücklich
  `--no-finder-layout`) erzeugen und anschließend GitHub-Release sowie
  signierten Appcast prüfen.

## Abgenommen am 2026-09-30

- **Einmaliges Undo mit vollständiger Formatsicherung.** Implementiert für
  macOS, X11 und unterstützte Wayland-Sitzungen; Vertrag und Grenzen:
  [docs/CLIPBOARD-UNDO.md](docs/CLIPBOARD-UNDO.md).
- **Echter Linux-Browserweg.** Firefox unter Cinnamon/X11: formatierten Text
  mit Liste, Link und Tabelle kopiert, `--replace` ausgeführt, Markdown in
  Firefox eingefügt; nach `--undo` ließ sich derselbe Abschnitt wieder mit
  Fett-/Kursivformatierung, Liste, Link und Tabelle einfügen.
- **Native Linux-Prüfungen.** Je 33 Undo-Vertragsprüfungen unter Xvfb und sway
  headless bestanden; die gemeinsame Pipeline bestand je 43/43 Prüfungen.
  Unabhängige xclip- und wl-clipboard-Roundtrips stellten auch große HTML- und
  Binärformate bytegenau wieder her. Die macOS-Kernprüfungen und die CLI des
  notarisierten Bundles bestanden.
- **macOS-App-Abnahme.** Das aktuelle Developer-ID-signierte, notarisierte
  und gestapelte Bundle wurde mit Gatekeeper-Akzeptanz regulär gestartet.
  Replace, die sichtbare HUD-Meldung und einmaliges Undo aller ursprünglichen
  Items und Formatbytes sind geprüft. Das vorherige Clipboard wurde aus einer
  RAM-Sicherung wiederhergestellt.
