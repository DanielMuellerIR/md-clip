# macOS-App bauen und veröffentlichen

Die App unterstützt macOS 14 oder neuer auf Apple Silicon. Sie enthält pandoc,
Sparkle, die Konvertierungsressourcen und native Helfer. Installationsschritte
für ein fertiges DMG stehen in der [README](../README.md#macos-app-installieren).

## Einstiegspunkte

| Befehl | Ergebnis |
|---|---|
| `./build.sh` | Unsignierte App in `build/md-clip.app` |
| `./install.sh` | CLI aus dem aktuellen Klon für macOS oder Linux |
| `./install-app.sh` | Developer-ID-signierte und notarisierte App in `/Applications` |
| `./release.sh` | Signiertes und notarisiertes DMG unter `build/` |

Der App-Build benötigt die Xcode Command Line Tools mit Swift 6 und für den ersten Bau
Internetzugriff. Er prüft die gepinnten Archive von pandoc und Sparkle anhand
ihrer SHA-256-Prüfsummen vor der Verwendung. Die App verwendet die Ressourcen
unter `Contents/Resources/bin/` und findet darüber auch ihr eingebettetes
pandoc. Die Lizenztexte liegen unter `Contents/Resources/Licenses/`.

## Kommandozeile aus der App

Der Launcher richtet den Befehl optional aus `/Applications` oder
`~/Applications` ein. Das Ziel in `/usr/local/bin/md-clip` ist ein Symlink
zum Skript im Bundle. Dadurch verwendet auch der Terminalaufruf den gebündelten
Konverter und folgt App-Updates. Ein bestehendes gültiges Ziel bleibt erhalten.
Beim Start aus einem kurzlebigen Pfad wie dem gemounteten DMG zeigt die App
statt der Symlink-Einrichtung den Hinweis zum Verschieben nach Programme.

Wer „Nicht mehr fragen“ gewählt hat, kann den Dialog für den nächsten
regulären App-Start wieder aktivieren:

```bash
defaults delete io.github.danielmuellerir.md-clip CliInstallDeclined
```

## Signatur und Notarisierung

`install-app.sh` und `release.sh` benötigen eine
Developer-ID-Application-Identität und ein lokales notarytool-Profil. Einmalig
das Profil erstellen und das App-spezifische Passwort interaktiv eingeben:

```bash
xcrun notarytool store-credentials "<profil>" \
  --apple-id "<apple-id>" --team-id "<team-id>"
git config --local mdClip.notaryProfile "<profil>"
```

`NOTARY_PROFILE` kann die Einstellung für einen Lauf überschreiben.
`security find-identity -v -p codesigning` zeigt verfügbare Signieridentitäten.
Für eine eigene Signieridentität unterstützen die Skripte `APPLE_TEAM_ID`
und `CODESIGN_IDENTITY`.

Die Skripte signieren zuerst die ausführbaren Bestandteile von innen nach außen
und zuletzt das Bundle mit Hardened Runtime und Zeitstempel. Der Bundle-Prüfer
verifiziert Signaturen, Team-ID, Mindestversion und Update-Konfiguration. Nach
der App-Notarisierung heften die Skripte das Ticket an und prüfen das Bundle
mit Gatekeeper. `release.sh` erstellt danach das DMG mit eigener Signatur,
Notarisierung und angeheftetem Ticket. Die App behält damit ihren Nachweis
auch nach dem Kopieren aus dem DMG.

`./release.sh --no-finder-layout` überspringt das optionale Finder-Layout,
das sonst ein Finder-Fenster öffnet. Beim Ändern des Layouts Fenstergröße und
Icon-Positionen mit dem [Hintergrundgenerator](../assets/generate-dmg-background.swift)
abgleichen. Der Build hängt das Image in einem privaten Verzeichnis ein.
Beim Aufräumen löst er nur das Gerät, das diesem Mountpoint zugeordnet wurde.

## Release prüfen

1. Produktversion in `bin/md-clip` mit Changelog und Tag abgleichen.
2. Die Basis- und plattformspezifischen Prüfungen ausführen. Das gebaute
   Bundle mit `./tests/run-all.sh --bundle build/md-clip.app` prüfen.
   [Testanleitung](../CONTRIBUTING.md#prüfungen)
3. Mit `./release.sh` das DMG erzeugen. App und DMG anhand der angehefteten
   Tickets und Gatekeeper prüfen. Bei Änderungen am Launcher oder an der
   Vorschau auch die notarisiert installierte App in einer grafischen
   macOS-Sitzung starten und Bedienung, Fokus sowie Undo prüfen.
4. Das stabile Release enthält genau ein DMG. Tag, App-Version und
   DMG-Dateiname müssen übereinstimmen. Anschließend den Feed und die
   Aktualisierung aus einer älteren App prüfen. [Sparkle-Ablauf](SPARKLE-RELEASE.md)
