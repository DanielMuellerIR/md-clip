# md-clip

md-clip wandelt formatierten Text aus der Zwischenablage in Markdown um. Auf
macOS gibt es eine App für Finder, Dock und Kurzbefehle. Die Kommandozeile läuft
auch unter Linux mit X11 oder Wayland und verarbeitet zusätzlich Dateien und
stdin.

## macOS-App installieren

Die fertige App benötigt macOS 14 oder neuer auf Apple Silicon. pandoc ist im
Bundle enthalten. [Aktuelles DMG herunterladen](https://github.com/DanielMuellerIR/md-clip/releases/latest)

1. Das DMG öffnen und md-clip in den Ordner **Programme** ziehen.
2. Die App aus **Programme** starten. Beim ersten Start kann sie den Befehl
   `md-clip` in `/usr/local/bin/` einrichten. macOS fragt dabei nach dem Passwort.
3. Formatierten Text kopieren, md-clip öffnen und das Ergebnis im Markdown-Editor
   einfügen. Für den nächsten Aufruf kann die App im Dock bleiben.

Die App beendet sich nach der Konvertierung. Ein separater Helfer sucht höchstens
einmal täglich nach einem Update. Installiert wird nach Bestätigung. Mit
`md-clip --check-updates` lässt sich die Suche sofort öffnen. Die aktualisierte App
läuft beim nächsten Start. [Details zum App-Start und zur
CLI-Einrichtung](docs/DISTRIBUTION.md#kommandozeile-aus-der-app)

## Kommandozeile aus dem Quelltext installieren

```bash
git clone https://github.com/DanielMuellerIR/md-clip.git
cd md-clip
```

**macOS:** Mit [Homebrew](https://brew.sh) und den Xcode Command Line Tools mit Swift 6
(`xcode-select --install`) im Projektverzeichnis ausführen:

```bash
brew bundle
./install.sh
```

**Linux:** Die CLI benötigt pandoc mit RTF-Reader und Sandbox, Perl sowie Python 3.
Für X11 sind `xclip`, `libX11` und `libXfixes` nötig. Unter Wayland liest
`wl-paste` aus dem Paket `wl-clipboard`. Der Compositor muss für Ersetzen und
Undo `ext-data-control` oder `wlr-data-control` anbieten. Die optionale
Erfolgsmeldung verwendet `notify-send`.

| Distribution | Paketinstallation |
|---|---|
| Debian, Ubuntu, Mint | `sudo apt install pandoc perl python3 xclip wl-clipboard libx11-6 libxfixes3` |
| Fedora | `sudo dnf install pandoc perl python3 xclip wl-clipboard libX11 libXfixes` |
| Arch | `sudo pacman -S pandoc perl python xclip wl-clipboard libx11 libxfixes` |

Nur die Pakete für die eigene Sitzung sind erforderlich. Ubuntu 22.04 braucht
eine neuere pandoc-Version mit RTF-Reader. [Offizielle pandoc-Downloads](https://github.com/jgm/pandoc/releases)

Anschließend `./install.sh` ausführen. Linux verlinkt den Befehl in
`~/.local/bin`, das im `PATH` liegen muss. Die CLI verwendet die Dateien des
Klons, solange der Link eingerichtet ist.

## Konvertieren und rückgängig machen

```bash
md-clip                         # Clipboard als Markdown auf stdout
md-clip --replace               # Clipboard durch Markdown ersetzen
md-clip --preview --replace     # vorher im Terminal prüfen
md-clip --undo                  # ursprüngliche Formate wiederherstellen
```

Zum Beispiel wird aus einem kopierten Absatz mit **Fettdruck** und einem
[Link](https://example.com) folgendes Markdown:

```markdown
Ein Absatz mit **Fettdruck** und einem [Link](https://example.com).
```

`--replace` sichert die ursprünglichen Formate, bevor es schreibt. Undo gilt
einmalig, höchstens zehn Minuten und bis zur nächsten Clipboard-Änderung.
Kann md-clip die Daten nicht vollständig sichern, bricht es ab. Die
Terminal-Vorschau übernimmt nach Eingabe von `ja`. [Undo-Vertrag und
Plattformgrenzen](docs/CLIPBOARD-UNDO.md)

## Dateien und stdin

```bash
printf '<p>Hallo <strong>Welt</strong></p>' | md-clip --stdin --from html
md-clip --input artikel.html > artikel.md
md-clip --input notizen.txt --plain > kopie.txt
```

Datei und stdin funktionieren ohne Desktop. Erst mit `--replace` schreiben sie
in die Zwischenablage. Bei Dateien erkennt md-clip `.html`, `.htm`, `.rtf`,
`.txt` und `.md` anhand der kleingeschriebenen Endung. stdin braucht
`--from html|rtf|plain` oder `--plain`. HTML-Dateien verwenden UTF-8 und
Klartext wird bytegenau durchgereicht.

stdout enthält die Nutzdaten. Status und Diagnose gehen an stderr.
`--quiet` blendet Statusmeldungen aus, Fehler bleiben sichtbar.

| Exit-Status | Bedeutung |
|---|---|
| `0` | Aktion erfolgreich |
| `1` | Quelle oder Sicherung nicht lesbar, Clipboard geändert oder Undo abgelaufen |
| `2` | Ungültige Eingabe oder fehlende Abhängigkeit |
| `3` | Konvertierung abgelehnt, verfügbarer Quellversuch fehlgeschlagen oder Schreiben gescheitert |
| `4` | Vorschau abgebrochen |
| `130`, `143` | Durch INT bzw. TERM beendet. Bereits auf stdout ausgegebene Teilbytes verwerfen. |

## Quellen und Markdown-Optionen

Automatisch versucht md-clip die verfügbaren Clipboard-Formate in der Reihenfolge
HTML, RTF, Klartext. Bei erkanntem Microsoft-Word-HTML hat RTF Vorrang.
`--from html` oder `--from rtf` wählen dieses Format ohne Rückfall.
`--verbose` zeigt den verwendeten Pfad und übersprungene Versuche.

| Option | Wirkung |
|---|---|
| `--plain`, `-p` | Klartext ausgeben |
| `--to gfm\|markdown\|commonmark` | Markdown-Dialekt wählen. Standard ist GFM. |
| `--strict` | Bekannte Vereinfachungen und den Rückfall von fehlgeschlagenem Rich Text auf Klartext ablehnen |
| `--tables reject\|text` | Komplexe Tabellen ablehnen oder mit deutschen Beschriftungen als Text darstellen |
| `--images keep\|alt\|omit` | Gelesene Bildreferenzen erhalten, durch Alternativtext ersetzen oder entfernen |
| `--notify`, `-n` | Erfolgsmeldung anzeigen |
| `--help` | Vollständige Liste der Optionen und Kurzformen anzeigen |

Formatierte Quellen können Informationen bereits beim Kopieren verlieren.
`--strict` lehnt bekannte Vereinfachungen der Konvertierung ab.
Sprachloser Code kann je nach pandoc-Version und Markdown-Dialekt eingerückt
oder mit Codezäunen erscheinen. Bildreferenzen bleiben standardmäßig erhalten.
Bei relativen Bildadressen muss die Datei am Ziel erreichbar sein.
Zeilenumbrüche innerhalb eines Absatzes erscheinen als zwei Leerzeichen am
Zeilenende. Beim Entfernen dieser Leerzeichen geht der Umbruch verloren.
[Beispiele und Inhaltsgrenzen](docs/CONVERSION.md) ·
[Komplexe Tabellen](docs/TABLES.md) ·
[Konvertierungsbericht und Strict](docs/CONVERSION-REPORT.md)

## Tastenkürzel und macOS-Vorschau

Auf macOS in **Kurzbefehle** eine Aktion **Shell-Skript ausführen** mit
`/usr/local/bin/md-clip --replace --notify` anlegen. In den Details des
Kurzbefehls lässt sich eine Tastenkombination hinzufügen. Falls macOS die
Ausführung blockiert, in den Kurzbefehle-Einstellungen Skriptaktionen zulassen.

Die App kann das vorbereitete Markdown vor der Übernahme in einem eigenen
Fenster zeigen. Beide Aufrufe funktionieren auch ohne eingerichteten CLI-Link:

```bash
open -n -a "md-clip" --args --preview   # ab App-Version 1.10.0
open -n -a "md-clip" --args --undo      # ab App-Version 1.9.0
```

Bei älteren Versionen kann ein App-Start mit Argumenten sofort konvertieren.
Die native CLI-Vorschau verwendet `md-clip --replace --preview-window`.
[Bedienung der nativen Vorschau](docs/PREVIEW.md)

Unter Linux lässt sich `md-clip --replace --notify` in den
Tastatureinstellungen der Desktop-Umgebung als Tastenkürzel hinterlegen.

## Diagnose und Entwicklung

```bash
md-clip --version
md-clip --doctor
md-clip --doctor --json
```

Doctor zeigt das verwendete Backend, vorhandene Werkzeuge und Fähigkeiten, ohne
Clipboard-Inhalte abzurufen. [Diagnosefelder](docs/DIAGNOSTICS.md) ·
[Zeichenkodierung](docs/ENCODING.md)

`./tests/run-all.sh` startet die zur Plattform passenden isolierten Basisprüfungen.
[Tests und Beiträge](CONTRIBUTING.md) ·
[macOS-App bauen und veröffentlichen](docs/DISTRIBUTION.md) ·
[Sparkle-Updates](docs/SPARKLE-RELEASE.md) · [Versionshistorie](CHANGELOG.md)

## pandoc und Lizenz

md-clip steht unter der [MIT-Lizenz](LICENSE). Die Konvertierung übernimmt
[pandoc](https://pandoc.org) von John MacFarlane, das md-clip als externes
Programm aufruft. Das DMG enthält ein unverändertes pandoc-Binary unter GPL
Version 2 oder neuer. Der Lizenztext und der Quellverweis liegen im App-Bundle
unter `Contents/Resources/Licenses/`. Das DMG bündelt beide Programme
als getrennte Komponenten.

Der vollständige Quellcode der mitgelieferten pandoc-Version ist mindestens drei
Jahre auf Anfrage über das [Projekt auf GitHub](https://github.com/DanielMuellerIR/md-clip)
erhältlich. Er steht auch unter dem jeweiligen Versions-Tag im
[pandoc-Repository](https://github.com/jgm/pandoc). Die mitgelieferte Version zeigt
`md-clip --version`.
