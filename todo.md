# md_clip — Todos

## Von Hand zu prüfen

- **Echter Klickweg auf einem Linux-Desktop.** In Firefox oder Chromium einen
  formatierten Abschnitt markieren, kopieren, `md-clip --replace` auslösen und
  das Ergebnis wieder einfügen. Das braucht einen bedienten Desktop mit echtem
  Browser und lässt sich deshalb weder in der CI noch im Container nachstellen —
  es bleibt eine manuelle Sichtprüfung.

  Die darunterliegenden Schnittstellen sind automatisiert abgedeckt:
  `tests/run-tests.sh` prüft UTF-8- und UTF-16-HTML bytegenau. Der X11-Weg lief
  am 2026-08-20 im Ubuntu-24.04-Container unter Xvfb mit 28/28 Tests, der
  Wayland-Weg am 2026-07-16 mit sway headless mit 9/9 Tests.

## Aus der Handoff-Frontier übernommen (2026-08-29)

- **Zwei nie importierte Code-Reviews vom 2026-08-19** (rund 19 Funde, unter
  anderem `lib/pipeline.sh:319`, `install-app.sh:121`,
  `wrappers/verify-bundle.sh:233`) sichten und importieren oder begründet
  verwerfen. Aus einer früheren Aufräum-Sitzung übernommen.
  Hinweis vom 2026-09-03: Der Code-Review und die CodeQA-Kampagne dieses Tages
  haben genau diese drei Dateien vollständig durchgesehen (siehe CHANGELOG 1.2.9
  und `.codeqa/coverage.json`). Beim Import lässt sich also abgleichen, welche
  der rund 19 Funde noch offen sind — die Zeilennummern von damals passen
  allerdings nicht mehr.

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
