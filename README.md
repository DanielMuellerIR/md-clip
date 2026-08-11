# md-clip

**Verwandelt formatierten Text aus dem Clipboard in sauberes Markdown — per Befehl, Dock-Klick oder Hotkey.**

Beim Einfügen in einen Markdown-Editor möchte man Markdown — nicht den HTML-Code, der beim Kopieren mit übernommen wurde. `md-clip` macht genau diese eine Sache.

Läuft auf **macOS** und **Linux** (X11 und Wayland). Die fertige App mit Dock-Icon gibt es für macOS; unter Linux ist md-clip ein CLI-Werkzeug — siehe [Linux](#linux).

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

**Updates:** Dass sich md-clip nach einer Konvertierung sofort beendet, ist
beabsichtigt. Vorher startet die App einen getrennten Sparkle-Helfer, der im
Hintergrund weiterläuft und höchstens einmal täglich nach einer neuen Version
sucht. Ohne Fund beendet auch er sich still; bei einem Update zeigt er den
Sparkle-Dialog. Installiert wird nur nach Bestätigung. Eine sichtbare Suche lässt
sich jederzeit im Terminal starten:

```bash
md-clip --check-updates
```

Dieser Befehl zeigt auch an, wenn die installierte Version aktuell ist. Nach einem
Update startet Sparkle md-clip bewusst nicht erneut, weil ein App-Start sofort das
Clipboard konvertieren würde. Beim nächsten Dock-Klick, Hotkey- oder CLI-Aufruf
läuft automatisch die neue Version. Es werden keine Hardware- oder
Systemprofildaten übertragen.

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

## Installation aus dem Quelltext (macOS)

Voraussetzungen: macOS, [Homebrew](https://brew.sh), Xcode Command Line Tools (`xcode-select --install`). Für Linux siehe [Linux](#linux).

```bash
git clone https://github.com/DanielMuellerIR/md-clip.git
cd md-clip
brew bundle           # installiert pandoc
./install.sh          # kompiliert die Helper, legt /usr/local/bin/md-clip an
```

## Linux

md-clip läuft unter Linux als CLI-Werkzeug — dieselbe Konvertierungs-Pipeline wie auf macOS, nur die Clipboard-Anbindung ist eine andere. **X11 und Wayland** werden beide unterstützt; md-clip erkennt beim Start selbst, welche Sitzung läuft (`md-clip --version` zeigt es an).

### Installation

```bash
# Debian / Ubuntu / Mint (pandoc muss den RTF-Reader enthalten)
sudo apt install xclip wl-clipboard libnotify-bin
# pandoc >= 2.14.2 aus den Distributions-Backports oder dem offiziellen Release

git clone https://github.com/DanielMuellerIR/md-clip.git
cd md-clip
./install.sh          # legt ~/.local/bin/md-clip an, kein sudo nötig
```

Für Fedora (`sudo dnf install pandoc xclip wl-clipboard libnotify`) und Arch (`sudo pacman -S pandoc xclip wl-clipboard libnotify`) gilt dasselbe, nur der Paketbefehl unterscheidet sich.

md-clip prüft nicht nur, ob `pandoc` vorhanden ist, sondern ob es das
Eingabeformat `rtf` wirklich unterstützt. Die Standardversion aus Ubuntu 22.04
ist zu alt; dort bitte ein aktuelles Paket von der
[offiziellen pandoc-Release-Seite](https://github.com/jgm/pandoc/releases) verwenden.

Es reicht das Clipboard-Werkzeug der eigenen Sitzung — `xclip` für X11, `wl-clipboard` für Wayland. Beide zu installieren schadet nicht und überlebt einen Sitzungswechsel. `libnotify-bin` braucht nur, wer `--notify` nutzt.

### Benutzung

Identisch zu macOS — alle Optionen aus [Benutzung](#benutzung) gelten unverändert:

```bash
md-clip                 # Markdown nach stdout
md-clip --replace       # Clipboard durch Markdown ersetzen
```

### Bekannte Grenzen unter Linux

- **Keine Dock-App und kein System-Hotkey.** Beides sind unter Linux Sache der Desktop-Umgebung, nicht des Programms. Einen Hotkey legt man in den Tastatur-Einstellungen an (GNOME: *Einstellungen → Tastatur → Eigene Tastenkombinationen*, KDE: *Systemeinstellungen → Kurzbefehle*) und hinterlegt dort als Befehl:
  ```
  md-clip --replace --quiet --notify
  ```
- **Firefox und Chromium legen HTML unterschiedlich kodiert ab** (Firefox UTF-16, Chromium UTF-8). md-clip erkennt und behandelt beides — falls doch einmal Zeichensalat auftaucht, ist das ein Bug und ein Issue wert.
- **RTF** wird von pandoc gelesen statt von Apples `textutil`. Für dieselbe Datei kommt auf beiden Plattformen dasselbe Markdown heraus (ein Test sichert das ab), pandocs RTF-Reader ist bei exotischen Dokumenten aber weniger erprobt.
- **Wayland ist nicht durch die CI abgedeckt** (ein Compositor im CI-Runner wäre unverhältnismäßig aufwendig) — der Pfad wird von Hand geprüft. X11 läuft in der CI unter Xvfb mit.

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
| `--notify` | `-n` | Erfolgsmeldung anzeigen (macOS-App: kurzes Einblend-Fenster der App selbst; Quellinstallation ohne App-Bundle: Mitteilungszentrale; Linux: `notify-send`) |
| `--quiet` | `-q` | Keine Statusmeldungen |
| `--verbose` | `-V` | Diagnose-Ausgabe, welcher Pfad gewählt wurde |
| `--version` | `-v` | Versionsnummer |
| `--help` | `-h` | Hilfetext |

## Nutzung durch KI-Agenten und in Skripten (Headless)

`md-clip` ist für die nicht-interaktive Nutzung ausgelegt — etwa durch KI-Agenten, in Shell-Skripten oder in CI-Schritten. Es stellt nie eine interaktive Rückfrage und verhält sich vollständig über Argumente, Exit-Codes und Standard-Streams steuerbar.

**Ein- und Ausgabe**

- **Eingabe ist immer das Clipboard** (macOS: NSPasteboard, Linux: X11-/Wayland-Auswahl), nicht stdin. `md-clip` liest den Inhalt selbst aus dem Clipboard; es nimmt keinen Text über die Standardeingabe entgegen. Ein Agent, der eigenen Text konvertieren will, legt ihn vorher dort ab — per `pbcopy` (macOS), `xclip -selection clipboard` (X11) oder `wl-copy` (Wayland).
- **Ausgabe geht per Default nach stdout** — reines Markdown, ohne Zusätze. Damit lässt sich das Ergebnis direkt in einer Variablen einfangen:
  ```bash
  markdown="$(md-clip --quiet)"
  ```
- **`--quiet` / `-q` hält stdout sauber:** Status- und Diagnosemeldungen laufen ausschließlich über stderr. Mit `--quiet` entfallen sie ganz, sodass stdout garantiert nur das konvertierte Markdown enthält — wichtig, wenn ein Agent die Ausgabe maschinell weiterverarbeitet.
- **`--replace` / `-r` schreibt das Ergebnis zurück ins Clipboard** statt nach stdout. Für reine Pipelines ist die stdout-Variante (ohne `--replace`) meist die richtige.
- **Plain-Text ist bytegenau:** `--plain` und `--from plain` erhalten auch
  kein, ein oder mehrere abschließende Newlines; stdout fügt keinen hinzu.

**Deterministisches Verhalten erzwingen**

- **`--from FORMAT` / `-f`** umgeht die Auto-Erkennung und legt die Quelle fest: `html`, `rtf` oder `plain`. Nützlich, wenn ein Agent genau weiß, welches Format auf dem Clipboard liegt, und keine Heuristik will.
- **`--to FORMAT` / `-t`** wählt den Markdown-Dialekt: `gfm` (Default), `markdown` oder `commonmark`.

**Exit-Codes** (für Verzweigungen im aufrufenden Skript)

| Code | Bedeutung |
|---|---|
| `0` | Erfolg |
| `1` | Nichts Konvertierbares auf dem Clipboard (z.B. leer) |
| `2` | Fehlende Abhängigkeit (pandoc; macOS: textutil/Swift-Helper, Linux: xclip bzw. wl-clipboard) oder ungültiges Argument |
| `3` | Konvertierungsfehler (pandoc o.ä. mit Non-Zero-Exit) |

**Beispiel — Agent konvertiert eigenen HTML-Text:**

```bash
printf '%s' "$html" | pbcopy            # macOS: eigenen Inhalt ins Clipboard legen
if markdown="$(md-clip --from html --quiet)"; then
  printf '%s\n' "$markdown"             # nur sauberes Markdown auf stdout
else
  echo "md-clip fehlgeschlagen (Exit $?)" >&2
fi
```

Unter Linux tritt an die Stelle von `pbcopy` das Werkzeug der Sitzung, mit explizitem HTML-Flavor:

```bash
printf '%s' "$html" | xclip -selection clipboard -t text/html   # X11
printf '%s' "$html" | wl-copy --type text/html                  # Wayland
```

**Voraussetzung:** `md-clip` greift auf das Clipboard der GUI-Sitzung zu. In einer angemeldeten macOS- oder Linux-Desktop-Sitzung (auch im Terminal) funktioniert das. In einer reinen SSH- oder Hintergrund-Umgebung ohne Clipboard-Zugriff steht keines zur Verfügung — unter Linux lässt sich das für Skripte und CI mit `xvfb-run md-clip …` umgehen, das startet einen unsichtbaren X-Server samt Clipboard.

## Dock-App (macOS)

Damit du nicht jedes Mal das Terminal öffnen musst, liegt im Ordner `wrappers/` ein Bauskript für eine Mini-App. Einmal ausführen:

```bash
./wrappers/build-app.sh
```

Das erzeugt `wrappers/md-clip.app`. Diese App ziehst du ins Dock. Ein Klick darauf konvertiert das Clipboard und zeigt eine Benachrichtigung.

Eigenes Icon zuweisen: Rechtsklick auf die App → **Informationen** → ein Bild auf das kleine App-Symbol oben links ziehen.

### Bauen, installieren, Release

Im Repo-Root liegen die drei Einstiegspunkte für die App — bewusst getrennt von `install.sh`, das das plattformübergreifende CLI-Setup ist und auch auf Linux läuft:

```bash
./build.sh                        # baut md-clip.app nach build/, ohne zu signieren
./install-app.sh                  # baut, notarisiert, installiert nach /Applications
./release.sh                      # baut, notarisiert, packt das DMG — installiert nie
./release.sh --no-finder-layout   # ohne Finder-Fensterlayout (für headless Läufe)
```

`install-app.sh` und `release.sh` notarisieren zuerst die **App selbst** und heften ihr das Ticket an. Das ist der Punkt: Eine App, die nur im notarisierten Disk-Image steckt, verliert ihre Garantie, sobald jemand sie herauszieht.

Dafür braucht es ein „Developer ID Application"-Zertifikat und ein notarytool-Keychain-Profil. Keychain-Profile sind pro Mac lokal und werden nie synchronisiert, deshalb steht im Repo kein Name: Er kommt aus `NOTARY_PROFILE` oder aus der Konfiguration dieses Clones.

```bash
git config --local mdClip.notaryProfile <profil>
xcrun notarytool store-credentials <profil> --apple-id <apple-id> --team-id <team-id>
```

## Globaler Hotkey (macOS)

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
- **Zeilenumbrüche innerhalb eines Absatzes** werden als zwei Leerzeichen am Zeilenende geschrieben — das ist in Markdown ein harter Umbruch, aber unsichtbar. Ein Editor, der beim Speichern Leerzeichen am Zeilenende entfernt, löscht damit den Umbruch. Die Alternative wäre ein sichtbarer `\` am Zeilenende; die ist bewusst nicht gewählt.
- **Bilder** werden weggelassen. Nur Text wird konvertiert.
- **Microsoft-Word-Dokumente mit komplexer Bild-Einbettung**: Bilder werden nicht extrahiert (keine `![]()`-Referenzen). Der Text und Tabellen-Inhalt kommt sauber raus, Bildplätze aber leer.

## Tests

```bash
bash tests/run-tests.sh
bash tests/test-plain-newlines.sh
bash tests/test-install-safety.sh
bash tests/test-dependencies.sh
bash tests/test-wrapper-safety.sh
```

Die Fixture-Tests brauchen nur pandoc und perl und laufen überall. Die Clipboard-Roundtrip-Tests brauchen ein echtes Clipboard und überspringen sich sichtbar, wo keines erreichbar ist (etwa in einem Container). Unter Linux holt man sie mit einem unsichtbaren X-Server dazu:

```bash
sudo apt install xvfb
xvfb-run ./tests/run-tests.sh
```

Die Fixture-Tests sourcen exakt dieselbe Pipeline wie das Produkt. Auf macOS
kompilieren sie Produkt- und Test-Helper in ein privates temporäres
Bundle-Layout; ein sauberer Checkout braucht keine ignorierten Alt-Binaries.
Der RTF-Test läuft auf beiden Plattformen gegen dieselbe Erwartungsdatei,
obwohl dahinter zwei verschiedene RTF-Parser stecken (`textutil` auf macOS,
pandoc auf Linux).

## Mitwirken

Bug-Reports und Pull-Requests sind willkommen. Bitte ein neues Issue eröffnen, bevor du an einer größeren Änderung arbeitest.

## Basiert auf pandoc

Die eigentliche Konvertierung von HTML nach Markdown übernimmt [pandoc](https://pandoc.org) von John MacFarlane — ohne pandoc gäbe es md-clip nicht. md-clip ist im Wesentlichen ein Vorverarbeiter, der Clipboard-Eigenheiten und HTML-Müll von Webseiten und Editoren glättet, bevor pandoc die schwere Arbeit erledigt.

Das DMG enthält ein unverändertes pandoc-Binary (Version siehe `md-clip --version`). Quellcode und Lizenz: [github.com/jgm/pandoc](https://github.com/jgm/pandoc).

## Lizenz

md-clip steht unter der [MIT-Lizenz](LICENSE).

Das im DMG mitgelieferte pandoc-Binary steht unter der **GPL v2 oder neuer**. Der vollständige Lizenztext und ein Verweis auf den pandoc-Quellcode liegen im App-Bundle unter `Contents/Resources/Licenses/`. MIT- und GPL-Komponenten werden hier als Aggregation distribuiert, nicht als abgeleitetes Werk — md-clip selbst ruft pandoc als externes Programm auf.

Gemäß GPL stellen wir den vollständigen Quellcode der jeweils mitgelieferten pandoc-Version auf Anfrage für mindestens drei Jahre bereit (Kontakt: GitHub-Issues oder Discussions unter [DanielMuellerIR/md-clip](https://github.com/DanielMuellerIR/md-clip)). Der Quellcode ist zusätzlich öffentlich unter [github.com/jgm/pandoc](https://github.com/jgm/pandoc) am jeweiligen Versions-Tag verfügbar.
