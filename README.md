# md-clip

**Verwandelt formatierten Text aus dem macOS-Clipboard in sauberes Markdown — per Befehl, Dock-Klick oder Hotkey.**

Du kopierst Text aus einem Browser, aus Claude Desktop, aus Notion, aus Word. Beim Einfügen in einen Markdown-Editor willst du eigentlich Markdown, nicht den HTML-Müll, der mitkopiert wurde. `md-clip` macht genau diese eine Sache.

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

## Installation

Voraussetzungen: macOS, [Homebrew](https://brew.sh), Xcode Command Line Tools (`xcode-select --install`).

```bash
git clone https://github.com/DanielMuellerIR/md-clip.git
cd md-clip
brew bundle           # installiert pandoc
./install.sh          # kompiliert den Helper, legt /usr/local/bin/md-clip an
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

macOS hat seit einigen Jahren eine eingebaute Kurzbefehl-Aktion namens **„Aus Rich Text Markdown erstellen"**. Wenn du nur ein paar Sätze in eine Notiz schieben willst, reicht die meistens. Auf realen Webseiten und in Dokumenten zeigen sich aber spürbare Unterschiede:

| Inhalt | macOS-Kurzbefehl | md-clip |
|---|---|---|
| Tabellen | Spalten und Zeilen werden zusammengeschoben, Struktur weg | bleiben echte Markdown-Tabellen |
| Fettdruck an Übergängen | erzeugt regelmäßig `**Wort******` mit überzähligen Sternchen | sauber |
| `<code>`-Inline-Schnipsel im HTML | werden als normaler Text wiedergegeben | werden mit Backticks umrahmt |
| Webseiten ohne Rich-Text-Anteil (z.B. Claude Desktop, viele Web-Apps) | liefert nichts | konvertiert normal über den HTML-Pfad |
| Aufruf aus Skripten und Pipes | nur über den Umweg eines Kurzbefehls möglich | direkter CLI-Befehl |
| Microsoft-Word-Dokumente | sauberer linearer Output | derzeit unsauberer als die Apple-Variante, siehe Roadmap |

Konkretes Beispiel an einem einzigen Satz mit einem Fett-zu-Link-Übergang:

**Original (kopiert aus dem Browser):**
> **The self-improving AI agent built by [Nous Research](https://nousresearch.com).**

**macOS-Kurzbefehl:**
```markdown
**The self-improving AI agent built by ****[Nous Research**](https://nousresearch.com)**.**
```

**md-clip:**
```markdown
**The self-improving AI agent built by** [**Nous Research**](https://nousresearch.com)**.**
```

Die vier aufeinanderfolgenden Sternchen `****` in der Apple-Variante sind kaputter Markdown — der Renderer zeigt sie wörtlich an oder verschluckt sie ganz.

## Was nicht funktioniert

- **Code-Blöcke** kommen meist als 4-Leerzeichen-Einrückung statt als ` ``` `-Fence. Beides ist gültiges Markdown und wird von allen Renderern korrekt erkannt.
- **Sprach-Annotation** für Code-Blöcke geht verloren — die meisten Quellen liefern sie ohnehin nicht mit.
- **Bilder** werden weggelassen. Nur Text wird konvertiert.
- **Microsoft-Word-Inhalte** enthalten Office-Layout-Tabellen, die `md-clip` derzeit als HTML-Block im Output stehen lässt. Apples eingebaute Aktion ist hier momentan besser — sie flacht das Layout linear. Verbesserung steht auf der Roadmap.

## Tests

```bash
bash tests/run-tests.sh
```

## Mitwirken

Bug-Reports und Pull-Requests sind willkommen. Bitte ein neues Issue eröffnen, bevor du an einer größeren Änderung arbeitest.

## Lizenz

[MIT](LICENSE)
