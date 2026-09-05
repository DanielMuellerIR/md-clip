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
- **Eine Tabellenzeile beginnt nur deshalb immer mit `|`, weil `run_pandoc` es
  erzwingt.** `pandoc_table_extensions` in `lib/pipeline.sh` schaltet dafür beim
  Ziel `markdown` die „simple"- und „multiline"-Tabellen ab (die Gittertabelle
  bleibt, ihre Inhaltszeilen beginnen ebenfalls mit `|`) und beim Ziel
  `commonmark` die Erweiterung `pipe_tables` an. Wer diese Zeilen entfernt,
  hebelt den Tabellenschutz von `tidy_markdown` aus: In einer „simple"-Tabelle
  stehen die Spalten an festen Zeichenpositionen, ein entfernter Backslash macht
  die Zeile ein Zeichen kürzer, und der Text der Folgespalte rutscht in die
  Nachbarzelle — aus `x|y` und `ok` wurde `x|y o` und `k` (Review-Fund
  2026-09-03). Ohne `pipe_tables` schreibt pandoc beim Ziel `commonmark` gar
  keine Tabelle, sondern den Text `[TABLE]`.
- **Tabellenstruktur vor dem Writer prüfen.** `lib/tables.lua` läuft in pandoc
  und lehnt verschachtelte Tabellen und verbundene Zellen strukturell ab. Keine
  Suche nach dem Ausgabetext `[TABLE]`: dieser Text darf wörtlich vorkommen.
  Für GFM/CommonMark werden Zellblöcke rekursiv zu Inline-Inhalt mit Leerzeichen
  zwischen Blöcken; Code-Newlines dürfen keine neue Tabellenzeile erzeugen.
  `markdown` behält Zellblöcke als Gittertabelle. Neue Fälle müssen im Roundtrip
  dieselbe Anzahl Zellen/Zeilen und den vollständigen Zelltext nachweisen.
- **Runtime-Ressourcen reisen gemeinsam.** `lib/pipeline.sh` bleibt Einstieg;
  `lib/tidy-markdown.pl` und `lib/tables.lua` liegen im Bundle daneben. Build,
  Bundle-Prüfer und isolierte Testkopien müssen neue Ressourcen mitführen.
- **Quelle, Konvertierung, Bewertung und Ausgabe bleiben getrennt.** Clipboard-
  Auto versucht HTML/RTF/Plain, bei Word RTF/HTML/Plain; explizites `--from` ist
  strikt. Datei/stdin ohne `--replace` darf keine Clipboard-Werkzeuge verlangen
  oder aufrufen. Plain-Text bleibt ohne pandoc bytegenau.
- **Die Perl-Schnipsel benutzen nur Kernbordmittel — kein `use <Modul>`.**
  Debian und Ubuntu liefern als Pflichtpaket nur `perl-base` aus; Module wie
  `Encode` stecken erst im vollen `perl`-Paket. `command -v perl` bestand auf
  einem schlanken System deshalb, und trotzdem brach jede Konvertierung mit
  „Can't locate Encode.pm in @INC" ab (Review-Fund 2026-09-03, im
  Ubuntu-24.04-Container belegt; die CI merkt es nicht, weil der GitHub-Runner
  das volle `perl`-Paket hat). Statt `Encode::decode` steht dort jetzt das
  eingebaute `utf8::decode`. Test 10f3 prüft beides: einen Lauf mit einem
  absichtlich kaputten `Encode.pm` ganz vorn in `@INC` und den Vertrag, dass
  außer `strict` und `warnings` kein Modul geladen wird. Aus demselben Grund
  ermittelt `wrappers/verified-cache.sh` die Prüfsumme über `sha256_of`:
  `shasum` gibt es auf macOS, aber auf einem schlanken Linux nur mit dem vollen
  `perl`-Paket; `sha256sum` ist dort umgekehrt immer da.
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
- **Die Produktversion liest überall dieselbe Grammatik.** Sie steht als
  `VERSION="…"` in `bin/md-clip` und wird an sechs Stellen gebraucht. Die fünf
  Shell-Einstiegspunkte — `build.sh`, `wrappers/build-app-bundled.sh`,
  `wrappers/verify-bundle.sh`, `install-app.sh`, `wrappers/sign-and-release.sh` —
  sourcen `wrappers/version.sh` und rufen `md_clip_version`. Vorher standen dort
  drei Schreibweisen nebeneinander, und die im Appcast-Workflow kam ohne `head`
  aus — bei zwei `VERSION`-Zeilen hätte sie etwas anderes gelesen als der Build.
  **Der Appcast-Workflow schreibt die Grammatik aus und darf die Funktion NICHT
  sourcen.** Sein Tooling kommt aus einer fest gepinnten Revision, und ein Pin
  ist älter als jede neu dort angelegte Datei: `source
  tooling/wrappers/version.sh` ließ den Lauf zu v1.2.9 mit „No such file or
  directory" abbrechen, und der Feed blieb auf der Vorversion stehen
  (2026-09-03). Wer dort eine Tooling-Datei ergänzen will, braucht zuerst einen
  geprüften neuen Pin. `tests/test-wrapper-safety.sh` hält beides fest: dieselbe
  Grammatik an allen sechs Stellen und kein anderes `source tooling/…` als das
  nachweislich vorhandene.
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
  `io.github.danielmuellerir.md-clip.notifier` ist auf dem Entwicklungs-Mac genau so
  verbrannt. Deshalb: kein UserNotifications-Anlauf ohne neues Konzept;
  der osascript-Weg in `notify()` bleibt nur Fallback der git-Installation.
- **Sparkle-Updates:** Die App aktualisiert sich über Sparkle (exakt gepinnt in
  `wrappers/build-app-bundled.sh`, Prüfsumme gegen den Homebrew-Cask
  gegenverifiziert). Weil die App nur ein Shell-Launcher ist, treibt der
  kompilierte Helfer `helpers/md-clip-updater.swift` (im Bundle:
  `Contents/MacOS/md-clip-updater`) Sparkle an — er ist die Sparkle-Laufzeit
  der App. Cocoa-basiert ist er damit nicht allein: `helpers/md-clip-hud.swift`
  importiert ebenfalls AppKit und startet eine `NSApplication`. Wer Signatur,
  Laufzeit oder Kompatibilität prüft, muss beide Helfer ansehen. Nach einem
  Update startet Sparkle die App bewusst NICHT neu (Delegate-Methode
  `updaterShouldRelaunchApplication` im Updater): Jeder Start der App führt
  sofort `md-clip --replace` aus und ersetzte damit ungefragt das Clipboard.
  Signiert wird zentral über `wrappers/sign-bundle.sh`
  (innen nach außen, ohne `--deep`), geprüft über `wrappers/verify-bundle.sh`.
  Das Ed25519-Schlüsselpaar ist bewusst dasselbe wie bei Poor Man's Text und
  Fastra; eine Rotation betrifft alle drei Apps. Nach jedem GitHub-Release
  veröffentlicht `.github/workflows/publish-appcast.yml` den signierten Feed.
  Ablauf und Begründungen: [docs/SPARKLE-RELEASE.md](docs/SPARKLE-RELEASE.md).

## Verzeichnisstruktur

- [AGENTS.md](AGENTS.md) — Projektprofil, Arbeitsregeln und dieses Datei-Verzeichnis.
- [README.md](README.md) — Projekt-Einstieg und Nutzerdokumentation.
- [todo.md](todo.md) — offene Punkte, die eine Person von Hand erledigen muss.
- [docs/DISTRIBUTION.md](docs/DISTRIBUTION.md) — Projektdokumentation.
- [docs/ENCODING.md](docs/ENCODING.md) — Projektdokumentation.
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
