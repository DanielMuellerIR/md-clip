# Linux-Port: md-clip

Stand: 2026-07-16 · **Umgesetzt und verifiziert** (Phasen 1–3 abgeschlossen, v1.1.0).
Ziel war: `md-clip` läuft zusätzlich unter Linux (X11 UND Wayland) — im selben Repo,
über eine Plattform-Weiche im Skript. Kein separates Repo: die Kern-Pipeline
(pandoc + Perl-Preprocessing + Bash) ist plattformneutral, nur die Ränder
(Clipboard, Notification, RTF-Konvertierung, Helper) waren macOS-spezifisch.

## Ergebnis

| Was | Wo |
|---|---|
| Plattform-Weiche | `bin/md-clip`, Abschnitt „Plattform-Weiche" |
| Plattformneutrale API | `clip_read_html/_rtf/_text`, `clip_write_text`, `rtf_to_html`, `notify` |
| Tests | `tests/run-tests.sh` — läuft auf macOS und Linux, Clipboard-Teil überspringt sich sichtbar ohne Display |
| CI | `.github/workflows/ci.yml` — Ubuntu, Fixtures ohne Display + X11-Clipboard unter Xvfb |
| Nutzerdoku | `README.md`, Abschnitt „Linux" |

Umgesetzte Abbildung:

| Funktion | macOS (unverändert) | Linux X11 | Linux Wayland |
|---|---|---|---|
| Clipboard HTML/RTF lesen | Swift-Helper (NSPasteboard) | `xclip -t text/html` bzw. `text/rtf` | `wl-paste -t …` |
| Clipboard Text lesen/schreiben | pbpaste/pbcopy | xclip | wl-paste/wl-copy |
| RTF → HTML | `textutil` | pandoc (`-f rtf`) | pandoc |
| Notification | osascript | `notify-send` | `notify-send` |

Erkennung zur Laufzeit: `uname -s` für die Plattform, `$WAYLAND_DISPLAY` für das
Backend (NICHT `$DISPLAY` — das ist unter Wayland via XWayland ebenfalls gesetzt).

## Verifikation (2026-07-16)

Linux-Läufe in einem lokalen Ubuntu-24.04-Container (Docker; das Hostsystem
blieb unangetastet, dort ist kein passwortloses sudo eingerichtet).

| Umgebung | Ergebnis |
|---|---|
| macOS 26, pandoc 3.9.0.2 | 8/8 grün (unverändert zu vorher) |
| Linux, ohne Display | 7/7 grün, Clipboard-Tests sichtbar übersprungen |
| Linux X11 (Xvfb), pandoc 3.1.3 | 9/9 grün |
| Linux Wayland (sway headless) | 9/9 grün |
| `install.sh` frisches Linux | legt `~/.local/bin` an, `md-clip` läuft |
| Fehlerpfade Linux | leeres Clipboard → Exit 1; fehlendes xclip → Exit 2 mit apt-Hinweis |

Phase 2 des Plans verlangte eine manuelle Testmatrix (2 Desktops × 2 Browser) an
einem echten Gerät. Ersetzt durch die reproduzierbaren Roundtrip-Tests oben: Die
kritische Browser-Eigenheit ist die HTML-Kodierung auf dem Clipboard, und die
prüfen wir jetzt byte-genau (siehe „Firefox" unten) statt per Augenschein. Was
damit NICHT abgedeckt ist und Daniels Blick braucht: der echte Klick-Weg auf einem
Desktop (Firefox/Chromium markieren → kopieren → md-clip → einfügen).

## Drei Befunde, die den Port geprägt haben

1. **`en_US.UTF-8` gibt es auf Linux oft nicht.** Das Skript setzte die Locale hart
   auf `en_US.UTF-8` (nötig, weil pbcopy/pbpaste sonst MacRoman annehmen). Auf Linux
   müssen Locales erst erzeugt werden; im Ubuntu-Container existiert **nur** `C.UTF-8`.
   Eine nicht existierende Locale kippt perl zurück auf C → Umlaut-Salat, also genau
   der Fehler, den die Zeile verhindern sollte. Linux nutzt jetzt `C.UTF-8`
   (fest in glibc eingebaut, immer da).

2. **Firefox legt HTML als UTF-16 aufs Clipboard, Chromium als UTF-8.** Ohne
   Behandlung liest pandoc aus einer Firefox-Kopie Müll — und Firefox ist der
   Standardbrowser auf Mint. `to_utf8` in `bin/md-clip` erkennt die BOM und wandelt
   per iconv. Wichtig: Das muss über eine Temp-Datei laufen, weil Bash in `$(...)`
   NUL-Bytes verwirft — der UTF-16-Text wäre sonst kaputt, bevor man ihn ansieht.
   Ein Test pinnt den Fall byte-genau (`utf16-html-clipboard`).

3. **pandocs RTF-Reader kennt die `\par`-Kurzform nicht.** Die RTF-Spec (1.9.1) sagt:
   Backslash direkt vor einem Zeilenumbruch = `\par` (Absatzende). TextEdit schreibt
   genau das, textutil versteht es, pandoc nicht — dasselbe RTF hätte je Plattform
   anderes Markdown ergeben. Der Plan hatte dafür „Erwartung pro Plattform
   parametrisieren" vorgesehen; stattdessen gleicht `rtf_fix_escaped_newlines` die
   Lücke aus. Begründung: Die Abweichung wäre ein gfm-Hard-Break aus **zwei
   unsichtbaren Leerzeichen** gewesen — genau das, was der Kommentar zum
   `trailing-hardbreak`-Test schon als „nicht stabil in einem Expected-File
   abbildbar" festhält. Jetzt laufen beide Plattformen gegen **dieselbe**
   Erwartungsdatei, und der Test bewacht damit die Gleichheit selbst.
   (Zweiter Ausgleich: `unwrap_list_paragraphs` gegen pandocs lose Listen.)

## Abweichungen vom ursprünglichen Plan

- **Kein `state_get/state_set`.** Der Plan listete ein „Erstinstall-Flag" via
  `defaults` als zu portierenden Rand. `defaults` steht aber ausschließlich in
  `wrappers/launcher.sh` (Dock-App, macOS-only und laut Plan unangetastet) —
  `bin/md-clip` hat gar keinen Zustand. Nichts zu tun.
- **Keine plattform-parametrisierte RTF-Erwartung** — siehe Befund 3.
- **Kein `xsel`-Zweig.** Der Plan nannte „xclip/xsel"; xsel kann keine eigenen
  MIME-Targets lesen und ist für den HTML-Flavor damit unbrauchbar. Nur xclip.

## Offen / bewusst nicht gemacht

- **Wayland ist nicht CI-abgedeckt.** Ein Compositor im GitHub-Runner wäre
  unverhältnismäßig; lokal ist der Pfad mit sway headless verifiziert (9/9).
- **Dock-App, Icons, DMG-Distribution** unangetastet (macOS-only, so beschlossen).
- **Kein Linux-Paket** (AppImage/deb). `install.sh` + Distro-Pakete reichen; der
  Plan nannte AppImage nur als Option.
- **Echter Browser-Klickweg** auf einem Linux-Desktop — Daniels Test (s.o.).

## Falle fürs nächste Mal (Test-Harness, nicht Produkt)

`xvfb-run` als **letzter** Befehl in `docker run … bash -c '…'` hängt: Bash exect den
letzten Befehl, xvfb-run wird damit Container-PID-1 und bekommt als PID 1 das
Bereitschaftssignal von Xvfb nicht zugestellt — es hängt, *bevor* die Tests starten
(sieht aus wie ein Test-Hänger, ist keiner). Abhilfe: irgendein Befehl dahinter,
z.B. `echo EXIT=$?`.

Davon zu unterscheiden — das ist ein **echter** Stolperstein: `xclip` forkt sich in
den Hintergrund, um die X11-Auswahl zu halten, und erbt dabei stdout. Ohne
`>/dev/null 2>&1` hält es das Schreibende der Pipe offen, und jeder Konsument
(`md-clip --replace | cat`, ein CI-Job) wartet ewig auf ein EOF. Steht so in
`bin/md-clip` und `tests/run-tests.sh` kommentiert. `wl-copy` daemonisiert sauber
und braucht das nicht (verifiziert).
