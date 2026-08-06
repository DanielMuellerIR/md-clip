# Self-Contained .app Distribution — Status und nächste Schritte

Dieses Dokument beschreibt den Plan, **md-clip** als signierte, notarisierte
macOS-App zu veröffentlichen, sodass auch Nutzer ohne Terminal-Erfahrung sie
einfach per Doppelklick installieren können. Es ist in drei Stufen gegliedert.

## Status (Stand: 2026-08-06)

- Quellstand: **v1.2.1, veröffentlicht am 2026-08-06** (zusammen mit v1.2.0
  am selben Tag; der Zwischenstand v1.1.2 ging in v1.2.0 auf). Der
  Sparkle-Update-Weg ist einmal komplett im Ernstfall durchlaufen: Eine
  installierte v1.2.0 hat v1.2.1 über den Feed gefunden, geladen, die
  Signatur geprüft und sich selbst ausgetauscht.

- **Stufe A — Self-contained App bauen.** ✅ Erledigt.
- **Stufe B — Signieren und notarisieren.** ✅ Erledigt.
- **Erststart-Dialog für optionale CLI-Installation.** ✅ Erledigt
  (v1.0.2), in v1.0.3 verbessert.
- **DMG-Installations-Layout** (Hintergrundbild, Applications-Symlink,
  Drag-Anleitung). ✅ Erledigt in v1.0.3.
- **pandoc-Würdigung + Lizenz-Klarstellung in README, pandoc-Version
  in `--version`-Output.** ✅ Erledigt in v1.0.3.
- Zuletzt dokumentierte veröffentlichte Version: **v1.0.3** als signiertes,
  notarisiertes DMG unter
  [github.com/DanielMuellerIR/md-clip/releases](https://github.com/DanielMuellerIR/md-clip/releases).
- **Sparkle-Auto-Update** (Framework im Bundle, Updater-Helfer,
  Appcast-Workflow). ✅ Erledigt in v1.2.0 — Details in
  [SPARKLE-RELEASE.md](SPARKLE-RELEASE.md).
- **Stufe C — GitHub Action für automatisierte Releases.** ⏳ Nächste
  Session.

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
- `Contents/Resources/bin/pandoc` — pandoc 3.9.0.2, arm64-only
- `Contents/Resources/bin/clipboard-html`, `clipboard-rtf` — kompilierte
  Swift-Helper
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
4. Innere Binaries (pandoc, clipboard-html, clipboard-rtf) einzeln signieren
   mit `--options runtime --timestamp`
5. App-Bundle signieren mit `--options runtime --timestamp --deep`
6. App notarisieren, Ticket anheften, mit `spctl --type execute` prüfen
7. DMG via `hdiutil create` erzeugen, DMG ebenfalls signieren
8. `xcrun notarytool submit --keychain-profile "$NOTARY_PROFILE" --wait`
9. `xcrun stapler staple` heftet das Notarization-Ticket ans DMG
10. `xcrun stapler validate` + `spctl --assess --type open` auf dem DMG

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

## Stufe C — GitHub Action für Tag-Releases (⏳ nächste Session)

Sobald jemand `git tag v1.0.2 && git push --tags` macht, soll automatisch
ein signiertes + notarisiertes DMG gebaut und als Release-Asset hochgeladen
werden. Damit ist „Release rausgeben" ein einziger Tag-Push, keine lokale
Maschine mehr nötig.

### Workflow-Skizze

`.github/workflows/release.yml`:

```yaml
name: Release

on:
  push:
    tags:
      - 'v*'

jobs:
  build-and-release:
    runs-on: macos-15  # Apple Silicon, neueste verfügbare Version
    steps:
      - uses: actions/checkout@v4

      - name: Import Developer ID certificate
        env:
          P12_BASE64: ${{ secrets.MACOS_CERTIFICATE_P12_BASE64 }}
          P12_PASSWORD: ${{ secrets.MACOS_CERTIFICATE_P12_PASSWORD }}
          KEYCHAIN_PASSWORD: ${{ secrets.MACOS_KEYCHAIN_PASSWORD }}
        run: |
          echo "$P12_BASE64" | base64 --decode > /tmp/cert.p12
          security create-keychain -p "$KEYCHAIN_PASSWORD" build.keychain
          security default-keychain -s build.keychain
          security unlock-keychain -p "$KEYCHAIN_PASSWORD" build.keychain
          security import /tmp/cert.p12 -k build.keychain \
            -P "$P12_PASSWORD" -T /usr/bin/codesign
          security set-key-partition-list -S apple-tool:,apple: \
            -s -k "$KEYCHAIN_PASSWORD" build.keychain
          rm /tmp/cert.p12

      - name: Setup notarytool credentials
        env:
          APPLE_ID: ${{ secrets.MACOS_NOTARIZATION_APPLE_ID }}
          TEAM_ID: ${{ secrets.MACOS_NOTARIZATION_TEAM_ID }}
          NOTARY_PASSWORD: ${{ secrets.MACOS_NOTARIZATION_PASSWORD }}
        run: |
          xcrun notarytool store-credentials "ci-notarytool" \
            --apple-id "$APPLE_ID" \
            --team-id  "$TEAM_ID" \
            --password "$NOTARY_PASSWORD"

      # Der Profilname muss beim Release-Skript ankommen, sonst bricht es
      # vor dem Bauen ab.
      - name: Build, sign, notarize
        env:
          NOTARY_PROFILE: ci-notarytool
        run: bash wrappers/sign-and-release.sh

      - name: Upload DMG as release asset
        env:
          GH_TOKEN: ${{ secrets.GITHUB_TOKEN }}
        run: |
          VERSION="${GITHUB_REF#refs/tags/v}"
          gh release upload "v${VERSION}" \
            "build/md-clip-${VERSION}.dmg" \
            --clobber
```

### Repo-Secrets, die einmalig zu setzen sind

In den GitHub-Settings unter Settings → Secrets and variables → Actions:

| Secret-Name | Inhalt |
|---|---|
| `MACOS_CERTIFICATE_P12_BASE64` | `.p12`-Export des Developer-ID-Application-Zertifikats, base64-encoded |
| `MACOS_CERTIFICATE_P12_PASSWORD` | Passwort, mit dem das `.p12` beim Export gesichert wurde |
| `MACOS_NOTARIZATION_APPLE_ID` | deine Apple-ID (E-Mail-Adresse des Developer-Accounts) |
| `MACOS_NOTARIZATION_TEAM_ID` | `9QSWKSR4NQ` |
| `MACOS_NOTARIZATION_PASSWORD` | App-spezifisches Passwort für `notarytool` (dasselbe, das lokal im gewählten notarytool-Schlüsselbund-Profil liegt) |
| `MACOS_KEYCHAIN_PASSWORD` | Beliebig wählbares starkes Passwort, schützt nur die temporäre Runner-Keychain während des Build-Laufs |

### Wie der `.p12`-Export geht

Schlüsselbundverwaltung öffnen (`open /Applications/Utilities/Keychain\ Access.app` oder via Spotlight):

1. Anmeldung-Keychain auswählen
2. Im Filter „Eigene Zertifikate" wählen
3. Eintrag **„Developer ID Application: Daniel Mueller"** rechts-klicken → **„Exportieren …"**
4. Dateiformat: **Personal Information Exchange (.p12)**
5. Speicherort frei wählen (NICHT ins Repo!), z.B. `~/Desktop/md-clip-cert.p12`
6. **Passwort vergeben** — das wird das `MACOS_CERTIFICATE_P12_PASSWORD`
7. Dann in der Shell base64-encoden für `MACOS_CERTIFICATE_P12_BASE64`:
   ```bash
   base64 -i ~/Desktop/md-clip-cert.p12 | pbcopy
   # → Inhalt liegt im Clipboard, im GitHub-Secret-Formular einfügen
   # ACHTUNG: pbcopy hier braucht eine korrekte UTF-8-Locale, sonst Mojibake.
   # Im laufenden Terminal sollte LANG bereits gesetzt sein. Falls Zweifel:
   # LANG=en_US.UTF-8 base64 -i ~/Desktop/md-clip-cert.p12 | LANG=en_US.UTF-8 pbcopy
   ```
8. `.p12`-Datei lokal **sicher löschen** (z.B. `rm -P` für mehrfaches Überschreiben).

### Stolpersteine, die wahrscheinlich auftreten

- **`security set-key-partition-list`** ist nötig, sonst fragt jeder
  codesign-Aufruf nach dem Schlüsselbund-Passwort interaktiv — im
  Headless-CI ein tödlicher Hang.
- **`security unlock-keychain`** muss innerhalb derselben Job-Step laufen
  wie codesign — anderer Step = anderes Shell-Environment.
- **Cache pandoc-Downloads** wäre nice, ist aber Stufe-D. Erstmal einfach
  bei jedem Run neu herunterladen — sind ~60 MB pro Lauf.
- **`gh` CLI ist auf macos-15-Runner vorinstalliert**, `GH_TOKEN` aus
  `secrets.GITHUB_TOKEN` reicht für Release-Asset-Upload.
- **macos-latest auf GitHub Actions** war historisch mal Intel, ist
  inzwischen arm64 (seit 2024). Trotzdem in der workflow.yml explizit
  `macos-15` o.ä. pinnen, damit es bei Major-Image-Updates nicht plötzlich
  bricht.

### Schritt-für-Schritt für die nächste Session

1. **Cert als `.p12` exportieren** (siehe oben), base64-encoden, im Clipboard.
2. **GitHub Repo-Secrets anlegen** (6 Stück, siehe Tabelle).
3. **`.github/workflows/release.yml` schreiben** nach Skizze oben.
4. **Lokal trockenlaufen lassen**, soweit möglich: jeden einzelnen Step
   manuell durchgehen, prüfen, dass keine Surprises kommen.
5. **Test-Tag pushen**, z.B. `git tag v1.0.3-rc1 && git push --tags`,
   Workflow-Run beobachten, Logs debuggen.
6. **Funktionierenden Workflow als regulär markieren**, Test-Release
   löschen, echte Version taggen.
7. **README aktualisieren** mit Hinweis, dass neue Versionen per Tag-Push
   gebaut werden (für künftige Mitwirkende relevant).

---

## Onboarding für eine neue Claude-Session

Dieser Prompt allein reicht, um eine frische Session in den Stand zu
versetzen, an dem wir gerade aufgehört haben:

> Wir arbeiten am Projekt **md-clip** (GitHub: `DanielMuellerIR/md-clip`,
> Projektverzeichnis lokal klonen).
>
> Das Tool konvertiert macOS-Clipboard-Inhalt (HTML / RTF aus Browsern,
> Word, TextEdit usw.) zu Markdown. Es gibt ein Bash-Hauptskript
> (`bin/md-clip`), zwei Swift-Helper für NSPasteboard-Zugriff
> (`helpers/clipboard-html.swift`, `helpers/clipboard-rtf.swift`) und ein
> macOS-App-Bundle mit eingebettetem pandoc, das per signiertem +
> notarisiertem DMG ausgeliefert wird.
>
> Erst diese Dokumente lesen, damit du den Kontext kennst, bevor du was
> tust:
>
> 1. `docs/DISTRIBUTION.md` — Status der drei Distribution-Stufen, Apple-
>    Credentials (Team-ID `9QSWKSR4NQ`, Apple-ID nur beim einmaligen
>    `store-credentials`, Profilname aus `NOTARY_PROFILE` bzw.
>    `git config mdClip.notaryProfile`), kompletter Plan für **Stufe C**
>    inkl. Workflow-Skelett und den sechs benötigten GitHub-Secrets.
> 2. `docs/ENCODING.md` — Locale- und Encoding-Stolpersteine. Wichtigster
>    Punkt: alle Bash-Skripte exportieren oben `LC_ALL=en_US.UTF-8`, NIE
>    `LC_ALL=C` inline für pbcopy/pbpaste — das war ein Selbstbetrug, der
>    den Clipboard-Inhalt für alle anderen Apps verfälscht hat.
> 3. `README.md` — was Nutzer zu sehen bekommen.
> 4. `~/.claude/CLAUDE.md` (privat) — globale Verhaltensregeln, u.a.:
>    knapp antworten, Code für Anfänger kommentieren, bei Passwörter-im-
>    Terminal warnen + History-Cleanup anleiten, bei Komponenten-Upgrades
>    Output-Diffs zeigen statt nur „Tests grün" zu melden, in öffentlichen
>    Dokumenten keine umgangssprachlichen oder wertenden Bezeichnungen
>    für Nutzergruppen.
>
> Aktueller Stand:
> - **v1.0.3** als signiertes + notarisiertes DMG auf GitHub veröffent-
>   licht. DMG hat Installations-Layout mit Hintergrundbild und
>   Applications-Symlink. Erststart-Dialog für CLI-Installation
>   erkennt jetzt dangling Symlinks und warnt, wenn das Bundle aus
>   einem nicht-dauerhaften Ort (DMG-Mount, Downloads) gestartet wird.
>   pandoc ist in README und `--version` sichtbar gewürdigt; Lizenz-
>   Trennung (md-clip MIT, gebundeltes pandoc GPL v2+) klargestellt.
> - **Stufe C** ist der nächste Schritt: GitHub Action, die bei Tag-Push
>   automatisch baut, signiert, notarisiert, das DMG als Release-Asset
>   hochlädt.
> - Das Developer-ID-Zertifikat liegt in meinem Login-Keychain
>   (`security find-identity -v -p codesigning` listet es).
>
> Schaue dir die genannten Docs an, dann sag mir, wie du Stufe C angehen
> würdest und welche Infos / Geheimnisse du von mir brauchst.

Die nächste Session sollte mit diesem Prompt ohne Rückfragen weitermachen
können.
