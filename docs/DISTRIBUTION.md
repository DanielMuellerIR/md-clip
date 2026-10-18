# macOS-App bauen und veröffentlichen

Dieses Dokument beschreibt den bestehenden Build- und Release-Weg für die
signierte, notarisierte macOS-App. Die App enthält ihre Laufzeitabhängigkeiten;
Nutzer benötigen weder Homebrew noch eine eigene pandoc-Installation.

## Status (Stand: 2026-10-18)

- Verbindlich für die Version sind zwei Quellen, nicht dieses Dokument:
  `bin/md-clip --version` nennt die Produktversion im Quellcode,
  `git describe --tags --abbrev=0` den jüngsten Release-Tag. Zwischen zwei
  Releases kann die Produktversion weiter als der jüngste veröffentlichte Tag
  sein — beim Release müssen Quelle, Tag, App und DMG übereinstimmen.
  Der Sparkle-Update-Weg ist vollständig belegt:
  Eine installierte App lädt ein signiertes DMG, prüft es und tauscht sich
  ohne ungefragten Neustart aus.

- **Stufe A — Self-contained App bauen.** ✅ Erledigt.
- **Stufe B — Signieren und notarisieren.** ✅ Erledigt.
- **Erststart-Dialog für optionale CLI-Installation.** ✅ Erledigt
  (v1.0.2), in v1.0.3 verbessert.
- **DMG-Installations-Layout** (Hintergrundbild, Applications-Symlink,
  Drag-Anleitung). ✅ Erledigt in v1.0.3.
- **pandoc-Würdigung + Lizenz-Klarstellung in README, pandoc-Version
  in `--version`-Output.** ✅ Erledigt in v1.0.3.
- **Sparkle-Auto-Update** (Framework im Bundle, Updater-Helfer,
  Appcast-Workflow). ✅ Erledigt in v1.2.0 — Details in
  [SPARKLE-RELEASE.md](SPARKLE-RELEASE.md).
- **Native Vorschau und eigene Undo-App-Aktion.** Seit v1.10.0 beziehungsweise
  v1.9.0 im Bundle; Bedienung und Prüfgrenzen stehen in
  [PREVIEW.md](PREVIEW.md) und [CLIPBOARD-UNDO.md](CLIPBOARD-UNDO.md).
- **Stufe C — GitHub Action für automatisierte DMG-Releases.** ⏳ Geplant.
  Appcast-Erzeugung und Veröffentlichung laufen bereits getrennt und
  abgesichert über GitHub Actions.

### Was in v1.0.3 dazukam

- **DMG-Installations-Layout:** Beim Doppelklick auf das DMG öffnet sich
  ein Fenster mit Hintergrundbild „md-clip installieren — Ziehe das
  md-clip-Symbol in den Ordner Programme", links das App-Icon, rechts
  ein Applications-Symlink, dazwischen ein Pfeil. Macht den
  Installations-Schritt für Nutzer ohne Terminal-Erfahrung
  selbsterklärend. Hintergrundbild liegt unter
  [`assets/dmg-background.png`](../assets/dmg-background.png), wird
  von [`assets/generate-dmg-background.swift`](../assets/generate-dmg-background.swift)
  per CoreGraphics erzeugt (600×400, 2× für Retina).
- **Launcher-Logik verbessert** ([`wrappers/launcher.sh`](../wrappers/launcher.sh)):
  - Erkennt jetzt **dangling Symlinks** in `/usr/local/bin/md-clip` (z.B.
    aus einer früheren git-clone-Installation, deren Quellordner
    inzwischen weg ist) und überschreibt sie beim Install.
  - Prüft **vor** dem CLI-Install-Dialog, ob das laufende Bundle
    tatsächlich in `/Applications` oder `~/Applications` liegt. Sonst
    erscheint ein Hinweis-Dialog „Bitte ziehe md-clip in den Ordner
    Programme", weil ein CLI-Symlink ins DMG oder ins Downloads-
    Verzeichnis sonst zum dangling Symlink wird, sobald das DMG
    ausgeworfen / der Downloads-Ordner aufgeräumt wird.
  - Bug-Fix: vorher kam die Warnung nicht, wenn eine korrekte
    `/Applications`-Installation existierte und der Nutzer aus
    Versehen die DMG-Kopie startete (der lebende Symlink in den
    `/Applications`-Pfad hatte den Warn-Pfad blockiert).
- **pandoc-Sichtbarkeit:**
  - Neuer README-Abschnitt „Basiert auf pandoc" mit Link zu pandoc.org
    und github.com/jgm/pandoc, sachliche Würdigung.
  - Lizenz-Abschnitt klargestellt: md-clip MIT, mitgeliefertes pandoc
    GPL v2+, Verweis auf `Contents/Resources/Licenses/` im Bundle.
  - `md-clip --version` gibt jetzt zusätzlich die pandoc-Version aus
    (gebundelt vs. System), hilfreich beim Bug-Reporting.

### Gut zu wissen / Stolpersteine aus v1.0.3

- **DMG-Hintergrundbild und AppleScript-Layout müssen synchron bleiben.**
  Die Fenstergröße `{200,120,800,520}` (=600×400 innen) und die
  Icon-Positionen `{150,180}`/`{450,180}` im AppleScript-Block in
  [`wrappers/sign-and-release.sh`](../wrappers/sign-and-release.sh)
  müssen zu den im Generator-Skript hartcodierten Werten
  (`width=600, height=400`, `appCenter={150,180}`, `dirCenter={450,180}`)
  passen. Wenn man eine Stelle ändert, die andere mitziehen — sonst
  wandert der Pfeil neben den Icons ins Leere.
- **`.background`-Ordner muss vor neugierigen Nutzern versteckt werden.**
  Nur `chflags hidden` reicht NICHT, wenn der Nutzer im Finder
  „unsichtbare Dateien anzeigen" (Cmd+Shift+.) aktiviert hat. Lösung:
  zusätzlich per AppleScript `set position of item ".background" of
  container window to {900, 900}` — also weit außerhalb der 600×400-
  Fensterfläche parken. Greift in beiden Modi.
- **AppleScript-Pfade nicht interpolieren.** Launcher und DMG-Layout nutzen
  gequotete Heredocs. Pfade werden über Umgebungsvariablen eingelesen und bei
  Shell-Aufrufen mit AppleScripts `quoted form of` maskiert; Apostrophe oder
  Shell-Metazeichen bleiben dadurch reine Daten.

---

## Stufe A — Self-contained App (✅ erledigt)

Das Skript [`wrappers/build-app-bundled.sh`](../wrappers/build-app-bundled.sh)
baut eine `build/md-clip.app`, die ohne Homebrew, ohne pandoc-Install, ohne
Terminal-Wissen läuft. Im Bundle liegen:

- `Contents/MacOS/md-clip` — Bash-Launcher, kopiert aus
  [`wrappers/launcher.sh`](../wrappers/launcher.sh). Macht zwei Dinge: erst
  Erststart-Dialog (siehe unten), dann eigentlicher md-clip-Lauf mit
  `--replace --notify`.
- `Contents/Resources/bin/md-clip` — Kopie des Hauptskripts
- `Contents/Resources/bin/pipeline.sh` — gemeinsame Produkt-/Test-Pipeline
- `Contents/Resources/bin/preprocess-html.pl` — HTML-Quellenreparaturen
- `Contents/Resources/bin/tidy-markdown.pl` — Markdown-Strukturerkennung und Aufräumregeln
- `Contents/Resources/bin/tables.lua` — strukturelle Tabellenprüfung in pandoc
- `Contents/Resources/bin/pandoc` — pandoc 3.9.0.2, arm64-only
- `Contents/Resources/bin/clipboard-html`, `clipboard-rtf` — kompilierte
  Swift-Helper
- `Contents/Resources/bin/clipboard-undo` — native Sicherung und Rücknahme
- `Contents/MacOS/md-clip-preview`, `md-clip-hud`, `md-clip-updater` — native
  Vorschau, Erfolgsmeldung und Sparkle-Laufzeit
- `Contents/Resources/Licenses/` — GPL-Volltext für pandoc, MIT-Hinweis
- `Contents/Resources/md-clip.icns` — App-Icon
- `Contents/Info.plist` — Bundle-Metadaten (Identifier
  `io.github.danielmuellerir.md-clip`, `LSUIElement` true → keine Dock-Präsenz,
  `CFBundleIconFile` referenziert das Icon)

**Größe nach Komprimierung im DMG:** ca. 42 MB. Vollständig wegen pandoc
(Haskell-Runtime + Lua + Daten). Intel-Support haben wir bewusst rausgenommen
— neue Macs sind seit 2020 alle arm64, und Universal hätte das DMG auf
~140 MB getrieben.

`bin/md-clip` ist seit dieser Stufe **zweilayout-fähig**: es findet pandoc
und die Helper sowohl im Projekt-Layout (`bin/` + `helpers/`) als auch im
Bundle-Layout (alles in `Resources/bin/`).

Der Bundle-Build prüft den gepinnten pandoc-Zip und das COPYRIGHT-Dokument
vor jeder Wiederverwendung per SHA-256, entpackt nur den exakten Archivpfad
und verifiziert `pandoc --version`. Downloads und Binary-Staging werden erst
nach erfolgreicher Prüfung atomar übernommen. Das Release-DMG wird in einen
privaten Mountpoint unter `build/` eingehängt; die Aufräumroutine löst nur das
von `hdiutil attach -plist` für diesen Lauf gemeldete Device.

### Bekannte Stolpersteine, schon gelöst

1. **PATH-Vererbung in GUI-Launches.** Dock-/Shortcuts-Aufrufe erben den
   Shell-PATH nicht. Fix in `bin/md-clip` ganz oben:
   `export PATH="/opt/homebrew/bin:/usr/local/bin:$PATH"` (homebrew-Pfad
   zuerst, damit auch bei verwaisten alten pandoc-Binaries unter
   `/usr/local/bin/` das aktuelle brew-pandoc gewinnt).
2. **Locale in GUI-Launches.** Ohne `LC_ALL` interpretieren pandoc/perl/sed
   UTF-8-Bytes als ASCII/Latin-1, Umlaute werden zerlegt. Fix:
   `export LC_ALL=en_US.UTF-8`.
3. **pbcopy/pbpaste-Locale-Falle.** macOS' pbcopy und pbpaste arbeiten
   nur dann korrekt mit UTF-8, wenn `LC_ALL` auf eine **named**
   UTF-8-Locale wie `en_US.UTF-8` gesetzt ist. Bei `LC_ALL=C`/leer/bare
   `UTF-8` interpretieren sie als MacRoman → Mojibake im Clipboard für
   alle anderen Apps. Lösung ist EINFACH der globale Export aus Punkt 2;
   alle pbcopy/pbpaste-Aufrufe erben den. Vollständige Geschichte inkl.
   Symmetrie-Falle bei Roundtrip-Tests: siehe `docs/ENCODING.md`.

### So baust du Stufe A neu

```bash
bash wrappers/build-app-bundled.sh
# Ergebnis: build/md-clip.app, unsigniert
# Größe: ~172 MB unkomprimiert, kommt auf ~43 MB im DMG
```

---

## Erststart-Dialog (✅ erledigt, Teil von v1.0.2)

[`wrappers/launcher.sh`](../wrappers/launcher.sh) wird beim Doppelklick auf
md-clip.app ausgeführt. Bevor er die eigentliche Konvertierung startet,
prüft er, ob in `/usr/local/bin/md-clip` bereits ein Verweis auf das
aktuelle App-Bundle liegt. Falls nicht und der Nutzer nicht früher „Nicht
mehr fragen" gewählt hat, erscheint ein AppleScript-Dialog mit drei
Optionen.

### Logik im Detail

| Zustand von `/usr/local/bin/md-clip` | Dialog erscheint? |
|---|---|
| Symlink ins eigene Bundle | Nein — schon installiert |
| Symlink woandershin (z.B. nach `git clone`) | Nein — Nutzer hat eigene Lösung |
| Reguläre Datei | Nein — Nutzer hat anderweitig installiert |
| Nichts da, `defaults read CliInstallDeclined` = 1 | Nein — Nutzer hat abgelehnt |
| Nichts da, kein Decline-Flag | **Ja** — Dialog erscheint |

### Drei Dialog-Buttons

| Button | Aktion |
|---|---|
| Ja, einrichten | `osascript "do shell script ... with administrator privileges"` legt `/usr/local/bin/` an (falls nötig) und symlinkt darin md-clip ins Bundle. macOS-Passwort-Prompt einmalig. |
| Später | Nichts speichern, beim nächsten Start wieder fragen. Auch ESC oder Cancel-Klick führen hierher. |
| Nicht mehr fragen | `defaults write io.github.danielmuellerir.md-clip CliInstallDeclined -bool true` |

### Reset

Wer „Nicht mehr fragen" gewählt hat und es sich umentscheidet, löscht den
Flag im Terminal:

```bash
defaults delete io.github.danielmuellerir.md-clip CliInstallDeclined
```

Beim nächsten App-Start erscheint der Dialog wieder. Steht so auch in der
README.

### Warum Symlink statt Kopie

Der Symlink zeigt direkt auf das Skript im App-Bundle. Konsequenz:

- Der CLI-Aufruf nutzt automatisch das **im Bundle eingebettete pandoc**
  — keine zusätzliche Homebrew-Installation nötig.
- Bei einem App-Update wird auch der CLI automatisch aktualisiert, weil
  beide auf dasselbe Skript zeigen.
- Konsistenz garantiert: CLI- und App-Version sind immer identisch.

`bin/md-clip` löst den Symlink portabel mit `readlink` und `pwd -P` auf, findet so sein
`SCRIPT_DIR` im Bundle und nimmt die dort liegenden Helper und pandoc
über die schon vorhandene Zwei-Layout-Logik.

---

## Stufe B — Signieren und notarisieren (✅ erledigt)

Ziel war: ein DMG, das bei beliebigen macOS-Nutzern per Doppelklick öffnet,
ohne Sicherheits-Warnung. Erfüllt mit v1.0.1.

### Voraussetzungen — wurden erfüllt

- **Apple Developer Account** aktiv
- **Developer ID Application-Zertifikat** in der Login-Keychain installiert.
  Prüfen mit:
  ```bash
  security find-identity -v -p codesigning
  # Soll zeigen: Developer ID Application: Daniel Mueller (9QSWKSR4NQ)
  ```
- **Team-ID:** `9QSWKSR4NQ`
- **Apple-ID:** eigene Apple-ID; sie wird nur beim einmaligen
  `store-credentials` gebraucht und danach nirgends mehr gelesen.
- **App-spezifisches Passwort** für `notarytool` als Schlüsselbund-Profil
  hinterlegt. Der Profilname ist frei wählbar und steht bewusst nicht im Repo:
  Schlüsselbund-Profile sind pro Mac lokal. Eingerichtet mit:
  ```bash
  xcrun notarytool store-credentials "<profilname>" \
    --apple-id "deine@apple-id.example" \
    --team-id  "9QSWKSR4NQ"
  # → fragt App-spezifisches Passwort INTERAKTIV ab; landet nicht in der History
  ```
- **Profilname an den Releasepfad übergeben.** Ohne diesen Schritt bricht
  `release.sh` ab, bevor überhaupt gebaut wird. Entweder einmalig für diesen
  Clone hinterlegen oder je Lauf über die Umgebung setzen:
  ```bash
  git config --local mdClip.notaryProfile "<profilname>"
  # oder:
  NOTARY_PROFILE="<profilname>" ./release.sh
  ```

### Was im Build-Skript passiert

[`wrappers/sign-and-release.sh`](../wrappers/sign-and-release.sh):

1. Profilname aus `NOTARY_PROFILE` bzw. `git config mdClip.notaryProfile`
   bestimmen; fehlt beides, bricht der Lauf sofort ab.
2. Sanity-Checks: Identität + Profil vorhanden?
3. Stufe A aufrufen → frisches Bundle bauen
4. `wrappers/sign-bundle.sh` signiert von innen nach außen: pandoc, beide
   Clipboard-Helfer, Updater- und HUD-Helfer, Sparkles Autoupdate-Programm,
   Updater-App, Framework und zuletzt das App-Bundle. Jeder Aufruf nutzt
   `--options runtime --timestamp`; `--deep` dient nur der anschließenden
   Prüfung und wird nicht zum Signieren verwendet.
5. `wrappers/verify-bundle.sh --signed` prüft alle Signaturen, Team-ID,
   Bundle-ID, Laufzeitziele und Update-Konfiguration.
6. App notarisieren, Ticket anheften, mit `spctl --type execute` prüfen.
7. DMG erzeugen und signieren.
8. DMG per `notarytool` notarisieren und das Ticket anheften.
9. `stapler validate` und `spctl --assess --type open` prüfen das DMG; erst
   danach erhält es den endgültigen Release-Dateinamen.

Dauer: Build ~30 s, Notarization typisch 2–3 min. Insgesamt ~4 min.

### Erkenntnisse aus dem ersten Lauf

- **Hardened Runtime + Bash-Launcher** war im Plan als Risiko notiert.
  In der Praxis: läuft anstandslos. Keine Entitlements nötig.
- **Pandoc-Signatur überschreiben**: pandoc-Binary von github.com/jgm/pandoc
  kommt mit Apple-Entwickler-Signatur einer dritten Person. Mit `--force`
  überschreiben wir das. Notarization akzeptiert das.
- **DMG-Größe**: das fertige DMG ist 42 MB (UDZO-komprimiert).
- **`stapler staple` erfolgreich**, daher öffnet das DMG offline ohne
  Gatekeeper-Online-Check.

### Ausgaben

- `build/md-clip-1.0.1.dmg`: signiert + notarisiert + stapled
- Hochgeladen als GitHub-Release-Asset:
  https://github.com/DanielMuellerIR/md-clip/releases/tag/v1.0.1

---

## Stufe C — automatisierter DMG-Build (geplant)

Ein signiertes und notarisiertes DMG wird derzeit lokal mit `./release.sh`
gebaut. Ein automatischer DMG-Build aus einem Release-Tag ist noch nicht
implementiert. Dafür wären eigene, passend abgesicherte Signing- und
Notarisierungszugänge für den Build-Runner nötig.

Die vorhandenen GitHub-Workflows bauen kein DMG: `request-appcast.yml` und
`publish-appcast.yml` veröffentlichen den Sparkle-Feed zu einem bereits
hochgeladenen Release. Ihr Ablauf und die erforderlichen Prüfungen stehen in
[SPARKLE-RELEASE.md](SPARKLE-RELEASE.md).

## Aktueller Release-Ablauf

1. Produktversion, Changelog und Benutzerdokumentation abgleichen. Konvertierung
   mit System- und Bundle-pandoc sowie unter Linux prüfen; das tatsächlich
   gebaute Bundle zusätzlich mit `tests/test-bundle-conversion.py` testen.
2. `./release.sh` baut und signiert die App, notarisiert sie und erstellt danach
   das ebenfalls signierte, notarisierte DMG. `--no-finder-layout` ermöglicht
   einen Lauf ohne Finder-Fokus; das Image enthält dann kein eingerichtetes
   Finder-Fensterlayout.
3. Den ausgehenden Quellstand einschließlich Historie und Release-Text prüfen.
   Branch und genau den zugehörigen Tag veröffentlichen, keine pauschale
   Übertragung aller lokalen Tags. Tag, App, DMG-Dateiname und Produktversion
   müssen übereinstimmen.
4. Ein stabiles GitHub-Release mit genau einem DMG anlegen. Download und
   Prüfsumme anschließend verifizieren. Der Appcast-Workflow erzeugt den
   signierten Feed; Version, Download-URL und Archivsignatur im Feed prüfen.
5. Das Update aus einer älteren notarisierten App prüfen. Sparkle darf die App
   nach dem Austausch nicht automatisch starten, weil das eine ungefragte
   Clipboard-Konvertierung auslösen würde.

---

## Einstieg für die nächste Arbeitssitzung

Der aktuelle Produktstand steht in `bin/md-clip` und `CHANGELOG.md`.
`AGENTS.md` hält die dauerhaft verbindlichen Plattform-, Pipeline-, Test- und
Release-Regeln fest. Für Distribution sind anschließend diese beiden
Dokumente maßgeblich:

1. `docs/DISTRIBUTION.md` für App-Bau, Signatur, Notarisierung und den noch
   geplanten automatischen DMG-Release.
2. `docs/SPARKLE-RELEASE.md` für Schlüssel, Appcast und den bereits
   implementierten Update-Weg.

Offen ist weiterhin Stufe C: Ein Workflow soll ein signiertes und
notarisiertes DMG aus einem stabilen Tag bauen und als Release-Artefakt
veröffentlichen. Die getrennten Workflows `request-appcast.yml` und
`publish-appcast.yml` übernehmen danach bereits die sichere Feed-Erzeugung.
