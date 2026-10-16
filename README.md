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

Voraussetzung: macOS 14 oder neuer auf Apple Silicon. Eine separate Installation von Homebrew oder pandoc ist nicht erforderlich — alles Nötige ist im Programm enthalten.

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
sudo apt install xclip wl-clipboard libnotify-bin python3 libx11-6 libxfixes3
# pandoc >= 2.15 aus den Distributions-Backports oder dem offiziellen Release

git clone https://github.com/DanielMuellerIR/md-clip.git
cd md-clip
./install.sh          # legt ~/.local/bin/md-clip an, kein sudo nötig
```

Für Fedora (`sudo dnf install pandoc xclip wl-clipboard libnotify python3 libX11 libXfixes`) und Arch (`sudo pacman -S pandoc xclip wl-clipboard libnotify python libx11 libxfixes`) gilt dasselbe, nur der Paketbefehl unterscheidet sich.

md-clip prüft nicht nur, ob `pandoc` vorhanden ist, sondern ob es das
Eingabeformat `rtf` wirklich unterstützt. Die Standardversion aus Ubuntu 22.04
ist zu alt; dort bitte ein aktuelles Paket von der
[offiziellen pandoc-Release-Seite](https://github.com/jgm/pandoc/releases) verwenden.

Zum Lesen reicht das Clipboard-Werkzeug der eigenen Sitzung — `xclip` für X11,
`wl-clipboard` für Wayland. Vollständiges Undo benötigt zusätzlich Python 3,
unter X11 `libX11` und `libXfixes`. Unter Wayland muss der Compositor das
`ext-data-control`- oder `wlr-data-control`-Protokoll anbieten; andernfalls
bleibt `--replace` gesperrt. `libnotify-bin` braucht nur, wer `--notify` nutzt.

### Benutzung

Identisch zu macOS — alle Optionen aus [Benutzung](#benutzung) gelten unverändert:

```bash
md-clip                 # Markdown nach stdout
md-clip --replace       # Clipboard durch Markdown ersetzen
md-clip --undo          # ursprüngliche Formate einmalig wiederherstellen
```

### Bekannte Grenzen unter Linux

- **Keine Dock-App und kein System-Hotkey.** Beides sind unter Linux Sache der Desktop-Umgebung, nicht des Programms. Einen Hotkey legt man in den Tastatur-Einstellungen an (GNOME: *Einstellungen → Tastatur → Eigene Tastenkombinationen*, KDE: *Systemeinstellungen → Kurzbefehle*) und hinterlegt dort als Befehl:
  ```
  md-clip --replace --notify
  ```
- **Firefox und Chromium legen HTML unterschiedlich kodiert ab** (Firefox UTF-16, Chromium UTF-8). md-clip erkennt und behandelt beides — falls doch einmal Zeichensalat auftaucht, ist das ein Bug und ein Issue wert.
- **RTF** wird von pandoc gelesen statt von Apples `textutil`. Für dieselbe Datei kommt auf beiden Plattformen dasselbe Markdown heraus (ein Test sichert das ab), pandocs RTF-Reader ist bei exotischen Dokumenten aber weniger erprobt.
- **Wayland und X11 laufen in der CI isoliert.** sway stellt eine eigene headless Wayland-Sitzung bereit; X11 läuft unter Xvfb. Der echte Desktop wird dabei nicht berührt.

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
| `--stdin` | | Eingabe von stdin; Format ausdrücklich angeben |
| `--input DATEI` | | Datei lesen, ohne Clipboard-Zugriff |
| `--doctor [--json]` | | Backend, Werkzeuge, Versionen und Fähigkeiten; keine Inhalte |
| `--preview` | | Ergebnis vor `--replace` am Terminal bestätigen |
| `--strict` | | Erkannte Strukturvereinfachungen und Rich-Text-Rückfall auf Klartext ablehnen |
| `--tables MODUS` | | Komplexe Tabellen: `reject` ablehnen (Standard), `text` beschriftet als Text darstellen |
| `--images MODUS` | | Bilder: `keep` erhalten (Standard), `alt` auf Alternativtext reduzieren, `omit` entfernen |
| `--replace` | `-r` | Ergebnis schreiben und alle ursprünglichen Formate für Undo sichern |
| `--undo` | | Letzte erfolgreiche Ersetzung einmalig zurücknehmen |
| `--plain` | `-p` | Keine Konvertierung, nur Klartext durchreichen |
| `--from FORMAT` | `-f` | Eingabe erzwingen: `auto`, `html`, `rtf`, `plain` |
| `--to FORMAT` | `-t` | Markdown-Dialekt: `gfm`, `markdown`, `commonmark` (mit Pipe-Tabellen) |
| `--notify` | `-n` | Erfolgsmeldung anzeigen (macOS-App: kurzes Einblend-Fenster der App selbst; Quellinstallation ohne App-Bundle: Mitteilungszentrale; Linux: `notify-send`) |
| `--quiet` | `-q` | Keine Statusmeldungen |
| `--verbose` | `-V` | Diagnose-Ausgabe, welcher Pfad gewählt wurde |
| `--version` | `-v` | Versionsnummer |
| `--help` | `-h` | Hilfetext |

## Dateien, stdin und Skripte

Clipboard bleibt die Standardquelle. Dateien und stdin benötigen weder einen
Desktop noch Clipboard-Werkzeuge:

```bash
printf '<p>Hallo <strong>Welt</strong></p>' | md-clip --stdin --from html
md-clip --input artikel.html > artikel.md
md-clip --input notizen.txt --plain > kopie.txt
md-clip --doctor --json
```

`--stdin` und `--input` schließen sich aus. stdin verlangt `--from html|rtf|plain`
oder `--plain`. Bei Dateien erkennt `auto` die Endungen `.html`, `.htm`, `.rtf`,
`.txt` und `.md` (kleingeschrieben); andere Namen benötigen `--from`. HTML-Dateien
verwenden UTF-8. Es gibt keine Inhaltsheuristik, die Klartext versehentlich als
HTML interpretiert. Verzeichnisse, fehlende oder unlesbare Dateien sind Fehler.
`--plain` widerspricht `--from html` und `--from rtf`.

stdout enthält ausschließlich Nutzdaten, auch ohne `--quiet`. Status und
Diagnose stehen auf stderr. `--quiet` unterdrückt Status, Verbose und HUD;
Fehler bleiben sichtbar. Auch `--quiet --notify` bleibt ohne Erfolgsmeldung; für HUD/Notification `--notify` ohne `--quiet` verwenden. `--verbose` nennt Quellen, Konvertierungsweg und
übersprungene Fehler. Erfolgsmeldungen unterscheiden „Markdown erzeugt“,
„Klartext übernommen“ und „Struktur vereinfacht“.

Klartext bleibt bytegenau, einschließlich NUL-Bytes und aller Schlusszeilen,
und benötigt kein pandoc oder Perl. HTML benötigt pandoc mit Sandbox und
Lua-Filter-Unterstützung sowie Perl ohne Zusatzmodule. RTF benötigt außerdem
`textutil` auf macOS bzw. pandocs RTF-Reader unter Linux. Der Installer prüft
weiterhin die vollständige Clipboard-Installation; die CLI prüft nur den
benötigten Weg.

### Reihenfolge und Inhaltsgrenzen

HTML-Layoutcontainer und leere Links werden nach dem HTML-Parsing normalisiert.
Anführungszeichen, `>` und Zeilenumbrüche in Attributen sind dabei kein Text;
Linkziele und Linktitel bleiben erhalten. Quellenreparaturen für Claude-Codezeilen
und Classroom-Anhänge berücksichtigen auch einfache Anführungszeichen und
großgeschriebene Attributnamen. Maskiertes HTML in Code bleibt unverändert.

Bei Clipboard-`auto` liest md-clip die vorhandenen HTML-, RTF- und Klartext-
Quellen einmal ein. Es versucht HTML → RTF → Klartext. Erkennt es Microsoft-
Word-HTML, gilt RTF → HTML → Klartext. Eine leere, unsichtbare, nicht verfügbare
oder fehlgeschlagene Rich-Text-Quelle führt zum nächsten Versuch. Ein explizites
`--from` bleibt strikt und fällt auf keine andere Quelle zurück.

Verschachtelte Tabellen und verbundene Zellen werden strukturell im pandoc-
Dokument erkannt und im Standardmodus abgelehnt. Im Auto-Modus bleibt der Rückfall verfügbar;
mit expliziter Quelle bleibt das Clipboard bei Fehlern unverändert. Der
wörtliche Text `[TABLE]` ist erlaubt und löst keine Sonderbehandlung aus.
Für `gfm` und `commonmark` werden Absätze, Listen, Zitate und Codeblöcke innerhalb
einer Tabellenzelle durch Leerzeichen getrennt zusammengeführt. Links und
Inline-Auszeichnung bleiben erhalten. Das Ziel `markdown` behält Zellblöcke als
Gittertabelle. Die bisherige RTF-Behandlung vereinfacht Layouttabellen weiterhin.

Bekannte Vereinfachungen werden mit Grund und Anzahl auf stderr gemeldet, etwa
„2 Tabellenzellen; Blockgrenzen und Umbrüche zusammengeführt“. Auto nennt auch
übersprungene Quellen und die anschließend verwendete Quelle.

Mit `--strict` werden diese Tabellenvereinfachungen und ein Rückfall von einem
gescheiterten vorhandenen Rich-Text-Angebot auf Klartext abgelehnt. Der Befehl
liefert dann Exit 3, gibt keine Nutzdaten aus und ersetzt das Clipboard nicht.
Ein erfolgreicher Wechsel zwischen HTML und RTF bleibt zulässig. Ursprünglicher
oder ausdrücklich gewählter Klartext bleibt bytegenau verwendbar. Strict prüft
die bekannten Fälle und ist keine allgemeine Verlustfreiheitsgarantie.
Der genaue Vertrag steht in [docs/CONVERSION-REPORT.md](docs/CONVERSION-REPORT.md).

### Diagnose ohne Clipboard-Inhalte

`md-clip --doctor` zeigt Werkzeuge, Konvertierungsfähigkeiten und konkrete
nächste Schritte. `--doctor --json` ergänzt die bisherigen Felder um feste
Diagnosekennungen und einen getrennten Sitzungsstatus. So lassen sich fehlende
X11-Bibliotheken, eine nicht erreichbare Sitzung und fehlendes Wayland-Data-Control
unterscheiden. Datei/stdin mit Klartext funktioniert auch ohne grafische Sitzung.

Doctor liest und schreibt keine Clipboard-Inhalte, startet keinen Undo-Dienst
und keine GUI. „Undo verfügbar“ bezeichnet die Fähigkeit des Helfers, keine
vorhandene Rücknahmesicherung. `null` bei einer Lesefähigkeit bedeutet, dass sie
nicht geprüft werden konnte. Vertrag und Kennungen stehen in
[docs/DIAGNOSTICS.md](docs/DIAGNOSTICS.md).

### Komplexe Tabellen als Text

`--tables text` stellt Tabellen mit verbundenen Zellen oder verschachtelten
Tabellen als beschrifteten Text in Zitaten dar. Jede geparste Zeile und Spalte
bekommt eine Zuordnung; Spannweiten und Fortsetzungen werden ausdrücklich genannt.
Zellinhalt erscheint einmalig, einschließlich Listen, Links und Codeblöcken.
Verschachtelte Tabellen stehen im zugehörigen Zellinhalt; leere Zellen bleiben
sichtbar. Einfache Tabellen behalten ihre normale Darstellung.

Der Standard `--tables reject` behält die bisherige Ablehnung komplexer Tabellen.
`--strict` verweigert eine tatsächlich nötige Textdarstellung vor der Ausgabe.
Im Textmodus wird die frühere RTF-Layouttabellenreparatur übersprungen, damit die
Matrix erhalten bleibt. Die Koordinaten beziehen sich auf pandocs geparste
Struktur; HTML-Reparaturen des Readers lassen sich damit nicht rückgängig machen.
Nicht positive oder widersprüchlich angegebene Spannweiten werden abgelehnt,
insbesondere `rowspan="0"`. Details und ein Beispiel stehen in
[docs/TABLES.md](docs/TABLES.md).

### Bildbehandlung

HTML-Bildreferenzen und Inline-SVG bleiben mit `--images keep` erhalten. Dabei
werden keine Bilder heruntergeladen oder aus Word-Dokumenten extrahiert.
`--images alt` ersetzt erkannte Bilder durch ihren Alternativtext; fehlt dieser,
entfällt das Bild. `--images omit` entfernt die Bilder vollständig. Die Anzahl
erscheint als Vereinfachung auf stderr. Die Politik gilt für konvertiertes HTML/RTF;
ursprünglicher oder ausdrücklich gewählter Klartext bleibt bytegenau.

Ein Link um ein Bild behält Ziel und Titel. Wird sein Inhalt durch die Bildpolitik
leer, erscheint wie bei anderen leeren Links die Ziel-URL als Linktext.
SVG ohne Alternativtext kann mit `alt` deshalb entfallen. Ein ausschließlich
bildhaltiges Dokument ohne verbleibenden Text wird abgelehnt und leert niemals
das Clipboard. Im Auto-Modus kann dann weiterhin eine andere Quelle verwendet
werden; `--from html` bleibt strikt. `--strict` lehnt tatsächlich erkannte
Bildvereinfachungen ab, erlaubt aber unveränderte Bilder mit `keep`.

### Ersetzen und Vorschau

`--replace` schreibt auch bei Datei-/stdin-Eingaben ausdrücklich ins Clipboard;
dann wird zusätzlich der Undo-Helfer der Sitzung benötigt. Ohne die Option
berühren diese Eingaben das Clipboard nicht. Leere oder abgelehnte Ergebnisse
werden niemals geschrieben. Bei konvertiertem Markdown entfällt vor dem
Schreiben genau pandocs letztes LF; durchgereichter Klartext bleibt bytegenau.

```bash
md-clip --preview --replace
```

Nur `--preview` stellt eine Rückfrage: Es zeigt das Ergebnis auf stderr und
liest `ja` von `/dev/tty`. Jede andere Antwort oder EOF bricht mit Exit 4 ab.
Ohne interaktives Terminal ist Vorschau ein Argumentfehler. Der direkte
Standardweg bleibt ohne Rückfrage. Die Vorschau zeigt den zuvor eingelesenen
Stand; sie sperrt das Clipboard während der Entscheidung nicht.

`md-clip --undo` stellt alle gesicherten Items und Formatbytes der letzten
erfolgreichen Ersetzung einmalig wieder her. Die Sicherung bleibt nur im RAM,
höchstens zehn Minuten ab dem Schreiben. Jeder neue Kopiervorgang macht sie
ungültig, auch wenn er identischen Text liefert. Konvertierung und Vorschau
bilden zusammen eine Ersetzung; ein Clipboard-Wechsel währenddessen verhindert
das Schreiben. Fehlt ein ursprüngliches Format oder kann es nicht vollständig
gelesen werden, bricht `--replace` ab. Aktive Datei-Versprechen sind keine
materialisierten Dateidaten und werden abgelehnt.

Der Helfer begrenzt die Sicherung auf 64 MiB und 128 Formate. Clipboard-Prüfung
und Schreiben sind keine atomare Operation: Eine neue Kopie genau zwischen der
letzten Prüfung und dem Schreiben kann weiterhin überschrieben werden. Unter
Linux muss der Helfer die angebotenen Daten bis zum nächsten Eigentümerwechsel
weiter ausliefern; sein Beenden verliert dieses Angebot. Details stehen in
[docs/CLIPBOARD-UNDO.md](docs/CLIPBOARD-UNDO.md).

| Code | Bedeutung |
|---|---|
| `0` | Nutzdaten ausgegeben/geschrieben oder Diagnose erfolgreich |
| `1` | Quelle/Sicherung nicht lesbar, Clipboard geändert oder Undo nicht mehr verfügbar |
| `2` | Ungültige Argumente/Datei oder benötigte Abhängigkeit fehlt |
| `3` | Konvertierung nicht darstellbar, alle vorhandenen Quellen scheitern oder Schreiben fehlgeschlagen |
| `4` | Vorschau abgebrochen |

`--doctor [--json]` prüft Werkzeuge und die tatsächlichen pandoc-Fähigkeiten.
Fehlende Funktionen erscheinen als `false`; der Diagnoseaufruf selbst liefert
Exit 0. `--json` ist nur mit `--doctor` erlaubt. Doctor lässt sich nicht mit
Datei-/stdin-Eingabe, Vorschau oder Ersetzen kombinieren.

## Dock-App (macOS)

`build.sh` erzeugt die vollständige App mit eingebettetem pandoc und den
Clipboard-Helfern:

```bash
./build.sh
```

Das Ergebnis liegt unter `build/md-clip.app`. Der lokale Build ist unsigniert
und bleibt deshalb im Build-Verzeichnis; eine Version für `/Applications`
entsteht ausschließlich über `install-app.sh`, das Signatur, Notarisierung und
Gatekeeper vor dem Installieren prüft. Ein Klick auf die App konvertiert das
Clipboard und zeigt das projektweit mitgelieferte Icon und Erfolgs-HUD.

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

### Eigener Hotkey für Undo

Die App akzeptiert genau eine Aktion. Ein normaler Dock-/Finder-Start oder
`--convert` konvertiert das Clipboard. `--undo` nimmt die letzte erfolgreiche
Ersetzung zurück; `--help` erklärt die Aktionen. Hilfe und ungültige Argumente
lösen keine Konvertierung aus. Undo zeigt keinen Erststart-Installationsdialog
und stößt keine Update-Suche an.

Für einen zweiten Kurzbefehl eine Aktion „Shell-Skript ausführen“ mit diesem
Befehl anlegen und eine freie Tastenkombination zuweisen:

```bash
open -n -a "md-clip" --args --undo
```

`-n` startet für jeden Hotkey-Aufruf eine neue App-Aktion, auch wenn noch ein HUD
oder Update-Helfer läuft. Ohne CLI-Installation funktioniert dieser App-Weg
weiterhin. Mit eingerichtetem Terminalbefehl ist auch Folgendes möglich:

```bash
md-clip --undo --notify
```

Nach Erfolg bestätigt das HUD die Wiederherstellung. Gibt es keine gültige
Sicherung, zeigt die App eine Erklärung: Undo gilt zehn Minuten, einmalig und
nur bis zum nächsten Kopieren. Ein Ablauf oder neuer Clipboard-Eigentümer
verändert das aktuelle Clipboard beim Undo-Versuch nicht. Andere technische
Fehler werden mit ihrem Grund angezeigt.

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
- **Automatische Spracherkennung für Code-Blöcke** findet nicht statt.
  Sprach-Annotationen bleiben erhalten, wenn die Quelle sie am
  `<code>`-Element mitliefert; fehlt die Angabe im Clipboard, ergänzt md-clip
  sie nicht durch Raten.
- **Zeilenumbrüche innerhalb eines Absatzes** werden als zwei Leerzeichen am Zeilenende geschrieben — das ist in Markdown ein harter Umbruch, aber unsichtbar. Ein Editor, der beim Speichern Leerzeichen am Zeilenende entfernt, löscht damit den Umbruch. Die Alternative wäre ein sichtbarer `\` am Zeilenende; die ist bewusst nicht gewählt.
- **Bilddaten werden nicht extrahiert.** HTML-Bildreferenzen bleiben standardmäßig
  erhalten; `--images alt|omit` steuert ihre Vereinfachung. Inline-SVG kann als
  eingebettete `data:`-Referenz erscheinen.
- **Microsoft-Word-Dokumente mit komplexer Bild-Einbettung**: Bilder werden nicht extrahiert (keine `![]()`-Referenzen). Der Text und Tabellen-Inhalt kommt sauber raus, Bildplätze aber leer.

## Tests

Die folgenden Prüfungen berühren das Host-Clipboard nicht. Sie benötigen pandoc,
Perl, unzip und Python 3.8 oder neuer. Die nativen macOS- und Wrapper-Prüfungen benötigen
zusätzlich die Xcode-Kommandozeilenwerkzeuge. Linux überspringt macOS-exklusive
Teile sichtbar.

```bash
MD_CLIP_SKIP_CLIPBOARD=1 bash tests/run-tests.sh
bash tests/test-plain-newlines.sh
bash tests/test-install-safety.sh
bash tests/test-dependencies.sh
bash tests/test-wrapper-safety.sh
bash tests/test-review-content.sh
python3 tests/test-cli-inputs.py
python3 tests/test-compare.py
python3 tests/test-html-normalization.py
python3 tests/test-conversion-report.py
python3 tests/test-images.py
python3 tests/test-tables-text.py
python3 tests/test-doctor.py
python3 tests/test-pandoc-pin.py
python3 tests/test-app-actions.py
python3 tests/test-undo-linux.py
python3 tests/test-undo-macos.py
```

Python-Attrappen der CLI-Matrix verwenden denselben Interpreter wie ihr
Testprozess, unabhängig vom Produkt-PATH. Die CI bindet `TEST_PYTHON` vor dem Testlauf
ausdrücklich und protokolliert dessen Version (Linux: `/usr/bin/python3`, macOS:
Interpreter des Runner-PATH). Lokal lässt sich der gewünschte
Interpreter ebenfalls über seinen absoluten Pfad starten.

Die Fixtures sourcen dieselbe Pipeline wie das Produkt. Beide Plattformen prüfen
dieselben Erwartungsdateien; RTF wird unter macOS von textutil und unter Linux von
pandoc gelesen. Der kleine [Quellenkorpus](tests/fixtures/README.md) dokumentiert
Formatabdeckung und Herkunftsgrenzen. Variantenprüfungen vergleichen zusätzlich
Text, Code, Links, Auszeichnung, Listen und Tabellen nach dem Markdown-Roundtrip.
`commonmark` verwendet dafür ausdrücklich die Erweiterung `pipe_tables`.

Für echte Linux-Clipboard-Prüfungen in eigenen unsichtbaren Sitzungen:

```bash
sudo apt install xclip xvfb sway wl-clipboard
xvfb-run -a ./tests/run-tests.sh
xvfb-run -a env MD_CLIP_UNDO_TEST_ISOLATED=1 python3 tests/test-undo-linux.py --integration
env -u WAYLAND_DISPLAY ./tests/run-wayland.sh
```

Wayland-Prüfungen benötigen einen unprivilegierten Benutzer und lehnen eine
bereits gesetzte WAYLAND_DISPLAY ab. Der eigene Compositor wird danach beendet.
Native macOS-Undo-Tests verwenden ausschließlich ein privates Pasteboard.
Ein ungeschützter Aufruf von `tests/run-tests.sh` kann dagegen das echte Clipboard
verwenden und restauriert nur dessen Klartext. Für normale macOS-Prüfungen daher
immer `MD_CLIP_SKIP_CLIPBOARD=1` setzen.

Die CI prüft Ubuntu 24.04/pandoc 3.1.3 sowie macOS 15 arm64 mit aktuellem
System-pandoc und dem exakt gebündelten pandoc. App-Build und CI lesen denselben
[Pin samt SHA-256](wrappers/pandoc-pin.sh); die Testbereitstellung baut keine App
und führt kein Signing aus. Lokal lässt sich derselbe Konverter bereitstellen:

```bash
bash tests/prepare-bundled-pandoc.sh /tmp/md-clip-pandoc
PATH="/tmp/md-clip-pandoc:$PATH" MD_CLIP_SKIP_CLIPBOARD=1 bash tests/run-tests.sh
```

`tests/test-compare.py` nutzt Clipboard-Attrappen. Die tatsächlichen manuellen
Vergleichsskripte benötigen dagegen macOS und verändern das Clipboard;
identische gespeicherte AppleMD-Ausgabe belegt allein keine Kurzbefehl-Ausführung.
Ein optionaler Laufzeitvergleich steht in `python3 tests/benchmark.py --runs 5`.

## Mitwirken

Bug-Reports und Pull-Requests sind willkommen. Bitte ein neues Issue eröffnen, bevor du an einer größeren Änderung arbeitest.

## Basiert auf pandoc

Die eigentliche Konvertierung von HTML nach Markdown übernimmt [pandoc](https://pandoc.org) von John MacFarlane — ohne pandoc gäbe es md-clip nicht. md-clip ist im Wesentlichen ein Vorverarbeiter, der Clipboard-Eigenheiten und HTML-Müll von Webseiten und Editoren glättet, bevor pandoc die schwere Arbeit erledigt.

Das DMG enthält ein unverändertes pandoc-Binary (Version siehe `md-clip --version`). Quellcode und Lizenz: [github.com/jgm/pandoc](https://github.com/jgm/pandoc).

## Lizenz

md-clip steht unter der [MIT-Lizenz](LICENSE).

Das im DMG mitgelieferte pandoc-Binary steht unter der **GPL v2 oder neuer**. Der vollständige Lizenztext und ein Verweis auf den pandoc-Quellcode liegen im App-Bundle unter `Contents/Resources/Licenses/`. MIT- und GPL-Komponenten werden hier als Aggregation distribuiert, nicht als abgeleitetes Werk — md-clip selbst ruft pandoc als externes Programm auf.

Gemäß GPL stellen wir den vollständigen Quellcode der jeweils mitgelieferten pandoc-Version auf Anfrage für mindestens drei Jahre bereit (Kontakt: GitHub-Issues oder Discussions unter [DanielMuellerIR/md-clip](https://github.com/DanielMuellerIR/md-clip)). Der Quellcode ist zusätzlich öffentlich unter [github.com/jgm/pandoc](https://github.com/jgm/pandoc) am jeweiligen Versions-Tag verfügbar.
