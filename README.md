# md-clip

**Verwandelt formatierten Text aus dem macOS-Clipboard in sauberes Markdown — per Befehl, Dock-Klick oder Hotkey.**

Beim Einfügen in einen Markdown-Editor möchte man Markdown — nicht den HTML-Code, der beim Kopieren mit übernommen wurde. `md-clip` macht genau diese eine Sache.

## Installation der fertigen App

Lade die neueste Version von der **[Releases-Seite](https://github.com/DanielMuellerIR/md-clip/releases/latest)** als `.dmg` herunter:

1. `md-clip-X.Y.Z.dmg` doppelklicken
2. md-clip-Icon in den **Programme**-Ordner ziehen
3. md-clip aus dem Programme-Ordner per Doppelklick starten
4. Beim ersten Start fragt md-clip, ob der Kommandozeilen-Befehl `md-clip` zusätzlich eingerichtet werden soll. Empfehlung: ja — damit lässt sich md-clip auch in Skripten oder im Terminal aufrufen. macOS fragt einmalig nach dem Anmelde-Passwort, weil ein Verweis in `/usr/local/bin/` angelegt wird.
5. Optional: App ins Dock ziehen

Ab jetzt: formatierten Text irgendwo markieren (`⌘C`), md-clip-Icon klicken, in einem Markdown-Editor `⌘V` — Markdown ist da.

**Falls man im Erststart-Dialog „Nicht mehr fragen" gewählt hat und sich umentscheidet:** im Terminal `defaults delete io.github.danielmuellerir.md-clip CliInstallDeclined` ausführen, dann fragt md-clip beim nächsten Start wieder.

Voraussetzung: macOS 11 oder neuer auf Apple Silicon. Eine separate Installation von Homebrew oder pandoc ist nicht erforderlich — alles Nötige ist im Programm enthalten.

## Beispiel

Du kopierst folgenden Absatz aus einem Browser:

> Das ist **fetter** Text mit einem [Link](https://example.com) und einer Liste:
> - Erster Punkt
> - Zweiter Punkt

Dann im Terminal:

```bash
md-clip --replace
```

Das Clipboard enthält jetzt:

```markdown
Das ist **fetter** Text mit einem [Link](https://example.com) und einer Liste:

- Erster Punkt
- Zweiter Punkt
```

Einfügen, fertig.

## Installation aus dem Quelltext

Voraussetzungen: macOS, [Homebrew](https://brew.sh), Xcode Command Line Tools (`xcode-select --install`).

```bash
git clone https://github.com/DanielMuellerIR/md-clip.git
cd md-clip
brew bundle           # installiert pandoc
./install.sh          # kompiliert die Helper, legt /usr/local/bin/md-clip an
```

## Benutzung

Drei typische Aufrufe:

```bash
md-clip                       # Markdown auf den Bildschirm schreiben
md-clip --replace             # Clipboard durch Markdown ersetzen
md-clip --plain --replace     # Alle Format-Reste entfernen, nur Klartext lassen
```

Alle Optionen im Überblick:

| Option | Kurzform | Wirkung |
|---|---|---|
| `--replace` | `-r` | Ergebnis zurück ins Clipboard schreiben |
| `--plain` | `-p` | Keine Konvertierung, nur Klartext durchreichen |
| `--from FORMAT` | `-f` | Eingabe erzwingen: `auto`, `html`, `rtf`, `plain` |
| `--to FORMAT` | `-t` | Markdown-Dialekt: `gfm`, `markdown`, `commonmark` |
| `--notify` | `-n` | macOS-Benachrichtigung bei Erfolg anzeigen |
| `--quiet` | `-q` | Keine Statusmeldungen |
| `--verbose` | `-V` | Diagnose-Ausgabe, welcher Pfad gewählt wurde |
| `--version` | `-v` | Versionsnummer |
| `--help` | `-h` | Hilfetext |

## Dock-App

Damit du nicht jedes Mal das Terminal öffnen musst, liegt im Ordner `wrappers/` ein Bauskript für eine Mini-App. Einmal ausführen:

```bash
./wrappers/build-app.sh
```

Das erzeugt `wrappers/md-clip.app`. Diese App ziehst du ins Dock. Ein Klick darauf konvertiert das Clipboard und zeigt eine Benachrichtigung.

Eigenes Icon zuweisen: Rechtsklick auf die App → **Informationen** → ein Bild auf das kleine App-Symbol oben links ziehen.

## Globaler Hotkey

macOS-Bordmittel reichen für einen system-weiten Tastatur-Shortcut:

1. **Kurzbefehle.app** öffnen (in den Programmen, deutsche Übersetzung von Shortcuts.app).
2. **Neuen Kurzbefehl** anlegen, Name z.B. „Clipboard zu Markdown".
3. Aktion **„Shell-Skript ausführen"** hinzufügen, Inhalt:
   ```bash
   /usr/local/bin/md-clip --replace --notify
   ```
4. Oben rechts auf das **Info-Symbol** klicken, **Tastaturkurzbefehl hinzufügen** wählen, eine Tastenkombination drücken. Vorschlag: **`⌃⌥⌘M`**.

Ab jetzt: Text irgendwo markieren, `⌘C`, `⌃⌥⌘M`, `⌘V` — das Eingefügte ist Markdown.

**Hinweis für macOS Tahoe (und vermutlich neuere Versionen):** Beim ersten Auslösen erscheint die Meldung *„Diese Aktion kann nicht ausgeführt werden, da Skriptaktionen deaktiviert sind"*. Aus Sicherheitsgründen sind Skript-Ausführungen in Kurzbefehlen standardmäßig blockiert. Über den Hinweis-Dialog oder in den Einstellungen von Kurzbefehle.app **Skriptaktionen erlauben** aktivieren, dann läuft es.

## Vergleich mit der eingebauten macOS-Alternative

macOS hat seit einigen Jahren eine eingebaute Kurzbefehl-Aktion namens **„Markdown aus formatiertem Text erstellen"** (in älteren Versionen „Aus Rich Text Markdown erstellen"). Für einfache Texte reicht sie. Bei dokumenten-typischem Material — Tabellen, Code-Schnipsel, längerem Aufbau — fallen reproduzierbare Unterschiede auf.

| Inhalt | macOS-Kurzbefehl | md-clip |
|---|---|---|
| HTML-Tabellen | werden zu unstrukturiertem Plain Text flachgewalzt | bleiben Markdown-Pipe-Tabellen |
| Inline-Code (`<code>`) | wird als normaler Text wiedergegeben | wird mit Backticks umrahmt |
| Aufruf aus Skripten und Pipes | nur über den Umweg eines Kurzbefehls | direkter CLI-Befehl |
| Microsoft-Word-Dokumente | linearer Output mit Sternchen-Artefakten und Wingdings-`l`-Bullets | echte Markdown-Listen, keine Artefakte |

**Reproduzierbares Beispiel:** Eine längere README mit Feature-Tabelle aus dem Browser kopieren (z.B. [github.com/NousResearch/hermes-agent](https://github.com/NousResearch/hermes-agent)). In der gleichen Stichprobe gemessen:

- md-clip übersetzt die Feature- und Kommando-Tabellen 1:1 als Markdown-Pipe-Tabellen (72 Tabellen-Zeilen erhalten).
- Apples Aktion gibt **null** Markdown-Tabellen-Zeilen aus — Spalten landen als isolierte Plain-Text-Zeilen ohne Trennzeichen, die Tabellenstruktur ist verloren.
- md-clip übersetzt 44 Inline-Code-Schnipsel in `` `Backticks` ``. Apple lässt davon nur 2 stehen, der Rest erscheint als normaler Text.

## Was nicht funktioniert

- **Code-Blöcke** kommen meist als 4-Leerzeichen-Einrückung statt als ` ``` `-Fence. Beides ist gültiges Markdown und wird von allen Renderern korrekt erkannt.
- **Sprach-Annotation** für Code-Blöcke geht verloren — die meisten Quellen liefern sie ohnehin nicht mit.
- **Bilder** werden weggelassen. Nur Text wird konvertiert.
- **Microsoft-Word-Dokumente mit komplexer Bild-Einbettung**: Bilder werden nicht extrahiert (keine `![]()`-Referenzen). Der Text und Tabellen-Inhalt kommt sauber raus, Bildplätze aber leer.

## Tests

```bash
bash tests/run-tests.sh
```

## Mitwirken

Bug-Reports und Pull-Requests sind willkommen. Bitte ein neues Issue eröffnen, bevor du an einer größeren Änderung arbeitest.

## Basiert auf pandoc

Die eigentliche Konvertierung von HTML nach Markdown übernimmt [pandoc](https://pandoc.org) von John MacFarlane — ohne pandoc gäbe es md-clip nicht. md-clip ist im Wesentlichen ein macOS-spezifischer Vorverarbeiter, der Clipboard-Eigenheiten und HTML-Müll von Webseiten und Editoren glättet, bevor pandoc die schwere Arbeit erledigt.

Das DMG enthält ein unverändertes pandoc-Binary (Version siehe `md-clip --version`). Quellcode und Lizenz: [github.com/jgm/pandoc](https://github.com/jgm/pandoc).

## Lizenz

md-clip steht unter der [MIT-Lizenz](LICENSE).

Das im DMG mitgelieferte pandoc-Binary steht unter der **GPL v2 oder neuer**. Der vollständige Lizenztext und ein Verweis auf den pandoc-Quellcode liegen im App-Bundle unter `Contents/Resources/Licenses/`. MIT- und GPL-Komponenten werden hier als Aggregation distribuiert, nicht als abgeleitetes Werk — md-clip selbst ruft pandoc als externes Programm auf.

Gemäß GPL stellen wir den vollständigen Quellcode der jeweils mitgelieferten pandoc-Version auf Anfrage für mindestens drei Jahre bereit (Kontakt: <apple-id>). Der Quellcode ist zusätzlich öffentlich unter [github.com/jgm/pandoc](https://github.com/jgm/pandoc) am jeweiligen Versions-Tag verfügbar.
