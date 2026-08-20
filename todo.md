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
