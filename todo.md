# md_clip — Todos

## Von Hand zu prüfen

- **macOS-App-Abnahme für 1.4.0.** Das aktuelle notarisiert installierte Bundle
  hat Replace und einmaliges Undo mit vollständigem Vergleich aller Items und
  Formatbytes bestanden. Der App-Start und die sichtbare HUD-Meldung sind nach
  einem Timeout der GUI-Steuerung noch offen.

## Aus der Handoff-Frontier übernommen (2026-08-29)

- Die beiden Reviews vom 2026-08-19 sind mit dem aktuellen Code abgeglichen:
  15 Funde im ersten und sechs im zweiten Review. Zitatlisten, HTML-Attributfolge
  und direkte Signaturprüfung der Clipboard-Helfer sind in 1.4.0 korrigiert.
  Frühere Fixes wurden nicht erneut umgesetzt. Noch offen sind:
  - Der CLI-Start ergänzt auch unter Linux den Homebrew-Pfad.
  - Die Linux-CI verwendet ein bewegliches Ubuntu-Image und pandoc aus dessen
    Paketquelle.
  - `tests/compare-file.sh` baut nur den Lesehelfer; `tests/compare.sh` kann nach
    einer fehlgeschlagenen Konvertierung weiterlaufen und verwirft identische
    Apple-Markdown-Ausgabe.
  - Der Leertext-Fehlertest akzeptiert jeden Fehlercode; die vollständigen
    Schluss-LF-Fälle werden noch nicht auf allen drei Clipboard-Wegen geprüft.
  - Der Icon-Build räumt bei gewöhnlichem Fehler nicht auf. Ein fehlendes Icon
    bleibt beim App-Build bewusst optional; eine Änderung braucht eine
    Produktentscheidung.
  Zwei nur paraphrasiert erhaltene Installationsfunde lassen sich ohne
  ursprüngliche Reproduktion nicht als aktuelle Fehler bestätigen.

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
  notarisierten Bundles bestanden; die oben genannte GUI-Abnahme bleibt offen.
