# Zu md-clip beitragen

Fehlerberichte und Pull Requests sind willkommen. Bei Konvertierungsfehlern
helfen die Ausgabe von `md-clip --version`, Betriebssystem, Quelle und Zielformat
sowie ein möglichst kleines Beispiel ohne private Clipboard-Inhalte. Größere
Änderungen vorab in einem Issue besprechen.

## Aufbau und Konvertierung

- `bin/md-clip` koordiniert Eingabe, Konvertierung und Ausgabe. Den
  Clipboard-Zugriff und plattformspezifische Werkzeuge bündelt `lib/platform.sh`.
  Doctor liegt in `lib/doctor.sh`, die Ergebnisauswertung in
  `lib/conversion-report.sh`.
  Die Sitzungserkennung prüft unter Linux zuerst `WAYLAND_DISPLAY`, weil
  `DISPLAY` durch XWayland ebenfalls gesetzt sein kann.
- Produkt und Fixtures verwenden `lib/pipeline.sh`. Export, Konvertierung,
  Konvertierungsbericht und Clipboard-Schreibzugriff bleiben eigene Schritte.
  Datei/stdin brauchen ohne `--replace` kein Clipboard. Klartext bleibt
  bytegenau und benötigt weder pandoc noch Perl.
- Perl-Code muss mit dem minimalen Debian-/Ubuntu-Paket `perl-base` laufen.
  Module wie `Encode` aus dem vollständigen Perl-Paket sind deshalb keine
  Laufzeitvoraussetzung. Code und SVG werden bei der Aufbereitung geschützt.
- HTML-Quellenreparaturen laufen vor dem Reader. `lib/pandoc-filter.lua`
  prüft Tabellen anhand der geparsten Struktur. Der wörtliche Text `[TABLE]`
  ist zulässig. `lib/tidy-markdown.pl` erhält Code, Inline-Code und alle
  Escapes in den mit `|` beginnenden Tabellenzeilen. Die Writer-Optionen
  müssen diese Zeilenform erhalten.
- Gemeinsame Fixtures haben auf macOS und Linux dieselben Erwartungsdateien.
  Sprachangaben im HTML gehören an `<code class="language-x">`. Eine
  zusätzliche Sprache am `<pre>` kann zwischen pandoc-Versionen unterschiedlich
  ausgegeben werden. Zwei Leerzeichen am Ende einer Fixture-Zeile können ein
  erwarteter Markdown-Zeilenumbruch sein. Änderungen an erwarteten Ausgaben
  gehören mit der Begründung in denselben Beitrag.

## Prüfungen

```bash
./tests/run-all.sh                          # isolierte Basis auf macOS oder Linux
./tests/run-all.sh --x11                    # Linux unter Xvfb
./tests/run-all.sh --wayland                # Linux in eigener Wayland-Sitzung
./tests/run-all.sh --bundle build/md-clip.app   # macOS, mit ./build.sh erzeugt
./tests/run-all.sh --lint                   # Syntax und statische Prüfungen
```

Die Basis benötigt pandoc, Perl, unzip und Python 3.8 oder neuer. Für native
macOS-Tests werden außerdem die Xcode Command Line Tools mit Swift 6 benötigt. Die beiden
Linux-Sitzungstests benötigen die Clipboard-Werkzeuge ihres Backends sowie
Xvfb bzw. einen headless sway-Compositor. Wayland muss als unprivilegierter
Benutzer laufen. Der Runner startet seine eigene Sitzung. Bei Xvfb in
Containern einen Init-Prozess verwenden, damit das Bereitschaftssignal
den wartenden Prozess erreicht. `--lint` verwendet Bash, ShellCheck,
Perl, `luac` und Actionlint.

Der zentrale Einstieg schützt die normale Zwischenablage. Manuelle
Vergleichsskripte und direkte Läufe von `tests/run-tests.sh` können das
aktuelle Clipboard ändern. Die macOS-Undo- und Vorschautests verwenden ein
privates Pasteboard. Hintergrundlebenszyklus und UI-Tastaturverhalten werden
getrennt geprüft. [Vorschau-Prüfungen](docs/PREVIEW.md#prüfgrenzen)

Die macOS-CI prüft System-pandoc und genau das im App-Bundle gepinnte pandoc.
Lokal stellt `tests/prepare-bundled-pandoc.sh VERZEICHNIS` den geprüften
Konverter bereit. Für denselben Writer und Roundtrip-Reader das Verzeichnis
an den Anfang des `PATH` setzen und im Test-Checkout `bin/pandoc` auf den
bereitgestellten Konverter verlinken. Der lokale Link hat in der CLI Vorrang
vor Homebrew.
Der Bundle-Test führt die eingebettete CLI aus und prüft die ausgelieferten
Ressourcen. Der [Fixture-Korpus](tests/fixtures/README.md) dokumentiert die
Formatabdeckung und Herkunft der Beispiele.

## App und Releases

Pipeline-Ressourcen müssen sowohl im Quelllayout als auch im Bundle verfügbar
sein. Bei neuen Ressourcen Build, Bundle-Prüfer und isolierte Testkopien
prüfen. Die App verwendet native Hilfsprogramme für Clipboard-Zugriff,
Vorschau, Einblendung und Updates. Die Vorschau übernimmt mit demselben
Undo-Token das bereits konvertierte Ergebnis. Ihre Statusabfrage liest nur
Metadaten und verlängert keine Frist.

Die Produktversion steht in `bin/md-clip`. Bei einem Release müssen Quelle,
App, DMG und Tag zusammenpassen. Das Appcast-Tooling läuft aus einer
vertrauenswürdigen gepinnten Revision. Änderungen an dort geladenen Dateien
erfordern einen passenden geprüften Pin. Die Build- und Signaturschritte stehen
in der [Distributionsanleitung](docs/DISTRIBUTION.md), die Feed-Prüfungen im
[Sparkle-Ablauf](docs/SPARKLE-RELEASE.md).
