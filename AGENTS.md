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
- **Eine Pipeline-Quelle:** Produkt und Fixture-Tests sourcen gemeinsam
  `lib/pipeline.sh`. Nur die plattformspezifische Funktion `rtf_to_html`
  bleibt an den jeweiligen Rändern. Keine Pipeline-Kopie in Tests anlegen.
- **`tidy_markdown` fasst Code-Blöcke nicht an.** Dort ist ein Backslash am
  Zeilenende echter Inhalt (Shell-Fortsetzung) und `\-` echter Code. Die
  Funktion markiert deshalb zuerst alle Code-Zeilen — eingezäunte (``` oder
  ~~~), eingerückte (vier Spalten jenseits des Listen-Containers) und die
  Leerzeilen innerhalb eines eingerückten Blocks — und überspringt sie in
  jeder Aufräumregel. Wer eine neue Regel hinzufügt, hängt sie in einen der
  Durchläufe mit `next if $is_code[$i]` ein, nicht als blindes `perl -0pe`
  über das ganze Dokument.
- **Überzählige Escapes nimmt `tidy_markdown` zurück, Tabellenzeilen nicht.**
  `\-` am Zeilenanfang, `\_\_\_`, sowie `\|` und `\#` im Fließtext werden
  entescapt. Escaped bleiben drei Stellen: die Raute am Anfang eines Blocks —
  also am Zeilenanfang **und** direkt hinter einem Listenmarker, denn `- # Text`
  wäre eine Überschrift im Listenpunkt —, **alles in einer Tabellenzeile** (die
  beginnt mit `|`) und **alles in Inline-Code** zwischen Backticks. In der
  Tabelle gehören die Escapes zur Spaltenbreite; ein Zeichen daraus zu entfernen
  verschiebt die Ausrichtung. Ein `\#` in einer Zelle bleibt deshalb bewusst
  stehen; wer das ändern will, muss die Tabelle neu ausrichten. In Inline-Code
  ist der Backslash echter Inhalt: `` `\#` `` bedeutet dort Backslash-Raute.
  **„Listenmarker" heißt dabei: beliebig viele hintereinander** — pandoc
  schreibt verschachtelte Listen als `- - \# tief` —, und beim Ziel `markdown`
  zählen auch alphabetische (`a.`, `b)`) sowie Definitionslisten-Marker (`:`,
  `~`) dazu. Erkennt die Regel nur den ersten, wird aus dem Text eine
  Überschrift. **„Zwischen Backticks" heißt: zwischen NICHT maskierten
  Backticks** — `` \` `` ist ein wörtlicher Backtick und keine Code-Grenze,
  sonst bliebe im Fließtext dahinter ein sichtbares `\#` stehen. Beide Regeln
  stammen aus dem Review vom 2026-08-05 und sind in
  `tests/fixtures/escaped-markers.*` festgehalten.
- **Zeilenumbruch im Absatz = zwei Leerzeichen, kein `\`.** pandoc schreibt
  Hard-Breaks als sichtbaren Backslash; `tidy_markdown` ersetzt ihn. Umbrüche,
  die nur Layout waren (vor Leerzeile, vor Listenpunkt, am Dokumentende),
  fallen ganz weg. Die zwei Leerzeichen in `tests/fixtures/*.expected.md` sind
  Prüfgegenstand — nicht wegformatieren.
- **Beide Plattformen laufen gegen dieselben Erwartungsdateien.** Wenn ein
  Linux-Ergebnis abweicht, ist das ein Befund — nicht der Anlass, eine zweite
  Erwartung einzuführen. Expected-Dateien nie still regenerieren.
  Die Erwartungen laufen dabei auch gegen zwei pandoc-Versionen (macOS 3.9.0.2,
  Ubuntu 24.04 3.1.3). Ein Fixture darf deshalb nichts festschreiben, was von
  der pandoc-Version abhängt. Konkret verifiziert am 2026-07-29: Die
  Sprachangabe eines Code-Blocks gehört in `<code class="language-x">`. Steht
  sie zusätzlich am `<pre>`, schreibt pandoc 3.1.3 ` ``` language-x `, 3.9 aber
  ` ``` x ` — und dasselbe Fixture kann nicht beide erfüllen.
- **Vor Linux-Änderungen testen:** `./tests/run-tests.sh` (macOS) und ein
  Linux-Lauf. Rezept für den Container-Lauf ohne fremde Systeme anzufassen:
  `tasks/2026-07-05-linux-port/plan.md`.
- **Zur kleinsten Testgruppe gehören auch die vier `tests/test-*.sh`.** Sie
  brauchen weder Display noch echtes Clipboard, weil sie sich ihre Werkzeuge
  als Attrappen selbst hinstellen — und laufen deshalb in der Linux-CI als
  eigene Schritte mit. Wer eine solche Attrappe ergänzt, deckt alle drei
  Plattform-Wege ab (pbcopy/pbpaste, xclip, wl-copy/wl-paste); sonst prüft das
  Skript still nur die Plattform, auf der es gerade läuft.
- **macOS-only bewusst prüfen:** Änderungen unter `wrappers/`, `assets/` oder
  `helpers/*.swift` brauchen zusätzlich isolierte Wrapper-/Bundle-Tests; reale
  Signing-, Notary- und Mount-Läufe nur bei einem ausdrücklich beauftragten Release.
- **Vier Einstiegspunkte, bewusst getrennt:** `install.sh` ist das
  plattformübergreifende CLI-Setup (läuft auch auf Linux) und installiert **keine**
  App. Der macOS-App-Weg liegt daneben: `build.sh` baut nur, `install-app.sh` baut,
  notarisiert und installiert nach `/Applications`, `release.sh` packt das DMG und
  installiert nie. Beide notarisieren zuerst die App selbst; ein Image erzeugt
  und notarisiert danach nur `release.sh` — `install-app.sh` baut gar keines.
  Profilname aus `NOTARY_PROFILE` oder `git config mdClip.notaryProfile` — kein
  Default im Repo, das ist ein öffentliches Repository.
- **Profil-Vorabcheck immer mit Wiederholung.** `xcrun notarytool history` meldet
  gelegentlich fälschlich „No Keychain password item found", obwohl das Profil da
  ist (2026-07-26 belegt). Ein einzelner Fehlversuch würde einen kompletten
  Release-Lauf grundlos abbrechen — deshalb fünf Versuche.
- **Erfolgsmeldung als HUD, nicht übers Notification Center.** Die App zeigt
  „Markdown ist im Clipboard" über `helpers/md-clip-hud.swift` (im Bundle:
  `Contents/MacOS/md-clip-hud`) als kurzes eigenes Einblend-Fenster — ohne
  jede Erlaubnis-Mechanik. Zwei am 2026-08-06 auf macOS 26 belegte Gründe:
  osascript-Meldungen laufen unter „Skripteditor"-Identität, und die
  UserNotifications-Erlaubnis wird nur nach nutzerinitiiertem Start einer
  gültig signierten App an einem ordentlichen Ort erfragt — kommt die Anfrage
  je aus einem Automationskontext (Hotkey, Skript, CLI, Kind-Prozess), setzt
  macOS die Bundle-ID still und ohne Reset-Weg auf „verweigert". Die ID
  `io.github.danielmuellerir.md-clip.notifier` ist auf Daniels M3 genau so
  verbrannt. Deshalb: kein UserNotifications-Anlauf ohne neues Konzept;
  der osascript-Weg in `notify()` bleibt nur Fallback der git-Installation.
- **Sparkle-Updates:** Die App aktualisiert sich über Sparkle (exakt gepinnt in
  `wrappers/build-app-bundled.sh`, Prüfsumme gegen den Homebrew-Cask
  gegenverifiziert). Weil die App nur ein Shell-Launcher ist, treibt der
  kompilierte Helfer `helpers/md-clip-updater.swift` (im Bundle:
  `Contents/MacOS/md-clip-updater`) Sparkle an — er ist die einzige
  Cocoa-Laufzeit der App. Signiert wird zentral über `wrappers/sign-bundle.sh`
  (innen nach außen, ohne `--deep`), geprüft über `wrappers/verify-bundle.sh`.
  Das Ed25519-Schlüsselpaar ist bewusst dasselbe wie bei Poor Man's Text und
  Fastra; eine Rotation betrifft alle drei Apps. Nach jedem GitHub-Release
  veröffentlicht `.github/workflows/publish-appcast.yml` den signierten Feed.
  Ablauf und Begründungen: [docs/SPARKLE-RELEASE.md](docs/SPARKLE-RELEASE.md).

## Verzeichnisstruktur

<!-- directory-structure: generated -->
- [AGENTS.md](AGENTS.md) — Projektprofil, Arbeitsregeln und dieses Datei-Verzeichnis.
- [README.md](README.md) — Projekt-Einstieg und Nutzerdokumentation.
- [docs/DISTRIBUTION.md](docs/DISTRIBUTION.md) — Projektdokumentation.
- [docs/ENCODING.md](docs/ENCODING.md) — Projektdokumentation.
- [docs/SPARKLE-RELEASE.md](docs/SPARKLE-RELEASE.md) — Sparkle-Updates bauen, signieren und veröffentlichen.
- [docs/archive/BLUEPRINT.md](docs/archive/BLUEPRINT.md) — Projektdokumentation.
- `assets/` — Projektbestandteil; Details stehen im Code bzw. in der verlinkten Dokumentation.
- `bin/` — Projektbestandteil; Details stehen im Code bzw. in der verlinkten Dokumentation.
- `docs/` — Projektbestandteil; Details stehen im Code bzw. in der verlinkten Dokumentation.
- `helpers/` — Projektbestandteil; Details stehen im Code bzw. in der verlinkten Dokumentation.
- `lib/` — gemeinsame, seiteneffektfreie Konvertierungs-Pipeline.
- `spike/` — Projektbestandteil; Details stehen im Code bzw. in der verlinkten Dokumentation.
- `tasks/` — Projektbestandteil; Details stehen im Code bzw. in der verlinkten Dokumentation.
- `tests/` — Projektbestandteil; Details stehen im Code bzw. in der verlinkten Dokumentation.
- `wrappers/` — Projektbestandteil; Details stehen im Code bzw. in der verlinkten Dokumentation.
<!-- /directory-structure -->
