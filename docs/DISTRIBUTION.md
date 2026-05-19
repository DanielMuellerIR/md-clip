# Self-Contained .app Distribution — Status und nächste Schritte

Dieses Dokument beschreibt den Plan, **md-clip** als signierte, notarisierte
macOS-App zu veröffentlichen, sodass auch Nutzer ohne Terminal-Erfahrung sie
einfach per Doppelklick installieren können. Es ist in drei Stufen gegliedert.

## Status (Stand: 18.05.2026)

- **Stufe A — Self-contained App bauen.** ✅ Erledigt.
- **Stufe B — Signieren und notarisieren.** ⏳ Nächste Session.
- **Stufe C — GitHub-Action für automatisierte Releases.** ⏳ Danach.

---

## Stufe A — Self-contained App (✅ erledigt)

Das Skript [`wrappers/build-app-bundled.sh`](../wrappers/build-app-bundled.sh)
baut eine `build/md-clip.app`, die ohne Homebrew, ohne pandoc-Install, ohne
Terminal-Wissen läuft. Im Bundle liegen:

- `Contents/MacOS/md-clip` — Bash-Launcher, ruft das eigentliche md-clip mit
  `--replace --notify` auf
- `Contents/Resources/bin/md-clip` — Kopie des Hauptskripts
- `Contents/Resources/bin/pandoc` — pandoc 3.9.0.2, arm64-only
- `Contents/Resources/bin/clipboard-html`, `clipboard-rtf` — kompilierte
  Swift-Helper
- `Contents/Resources/Licenses/` — GPL-Volltext für pandoc, MIT-Hinweis
- `Contents/Info.plist` — Bundle-Metadaten (Identifier
  `io.github.danielmuellerir.md-clip`, `LSUIElement` true → keine Dock-Präsenz)

**Größe:** ca. 172 MB. Vollständig wegen pandoc (Haskell-Runtime + Lua + Daten).
Intel-Support haben wir bewusst rausgenommen — neue Macs sind seit 2020 alle
arm64, und Universal hätte 277 MB bedeutet.

`bin/md-clip` ist seit dieser Stufe **zweilayout-fähig**: es findet pandoc
und die Helper sowohl im Projekt-Layout (`bin/` + `helpers/`) als auch im
Bundle-Layout (alles in `Resources/bin/`).

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
# Größe: ~172 MB
```

Die unsignierte App **funktioniert auf deinem eigenen Rechner**, aber beim
Verteilen meldet Gatekeeper bei jedem fremden Nutzer:

> „md-clip kann nicht geöffnet werden, weil Apple Schadsoftware nicht prüfen
> konnte."

Workaround per Rechtsklick → Öffnen geht, aber ist genau die Reibung, die
Terminal-Muffel abschrecken soll. Daher Stufe B.

---

## Stufe B — Signieren und notarisieren (⏳ nächste Session)

Ziel: ein DMG, das bei beliebigen macOS-Nutzern per Doppelklick öffnet,
ohne Sicherheits-Warnung.

### Voraussetzungen — schon erledigt

- **Apple Developer Account** aktiv
- **Developer ID Application-Zertifikat** in der Login-Keychain installiert.
  Verifizierbar mit:
  ```bash
  security find-identity -v -p codesigning
  # Soll zeigen: Developer ID Application: Daniel Mueller (9QSWKSR4NQ)
  ```
- **Team-ID:** `9QSWKSR4NQ`
- **Apple-ID:** <apple-id>

### Voraussetzung — vom User noch zu beschaffen

- **App-spezifisches Passwort für `notarytool`.**
  appleid.apple.com → Anmelden → „Anmelden & Sicherheit" → „App-spezifische
  Passwörter" → „+" → Label `md-clip-notarytool`. Apple zeigt das Passwort
  einmal an, am besten direkt in den nächsten Schritt einfügen, danach nicht
  mehr abrufbar.

### Vorgehen (für die nächste Claude-Session)

**Schritt 1: Schlüsselbund-Profil anlegen.** Einmalig, manuell durch User:

```bash
xcrun notarytool store-credentials "md-clip-notarytool" \
  --apple-id "<apple-id>" \
  --team-id "9QSWKSR4NQ" \
  --password "<app-spezifisches-passwort>"
```

Speichert die Credentials unter dem Schlüsselbund-Label
`md-clip-notarytool`. Das Build-Skript referenziert nur dieses Label —
das Passwort selbst landet nie in Source-Code, Logs oder Repo.

**Schritt 2: Build-Skript erweitern.** Vorschlag: separates Skript
`wrappers/sign-and-release.sh`, das `build-app-bundled.sh` aufruft, dann
signiert, DMG erzeugt, notarisiert, stapelt, verifiziert. Vorlage der
Befehle:

```bash
IDENTITY="Developer ID Application: Daniel Mueller (9QSWKSR4NQ)"

# Alle Binaries im Bundle einzeln signieren (innen nach außen).
# --options runtime: Hardened Runtime — Voraussetzung für Notarization.
# --timestamp: secure timestamp — Voraussetzung dass Notarization nicht
#              nach Cert-Ablauf invalidiert.
for binary in \
    "$APP_BUNDLE/Contents/Resources/bin/pandoc" \
    "$APP_BUNDLE/Contents/Resources/bin/clipboard-html" \
    "$APP_BUNDLE/Contents/Resources/bin/clipboard-rtf"; do
  codesign --sign "$IDENTITY" --options runtime --timestamp \
           --force "$binary"
done

# App-Bundle selbst signieren (mit --deep, damit alle bereits-signierten
# inneren Binaries als "weiterhin signiert" erkannt werden).
codesign --sign "$IDENTITY" --options runtime --timestamp \
         --force --deep "$APP_BUNDLE"

# Signatur prüfen.
codesign --verify --strict --verbose=2 "$APP_BUNDLE"

# DMG erzeugen.
hdiutil create -volname "md-clip" -srcfolder "$APP_BUNDLE" \
               -ov -format UDZO "build/md-clip.dmg"

# DMG ebenfalls signieren.
codesign --sign "$IDENTITY" --timestamp --force "build/md-clip.dmg"

# Bei Apple zur Notarization einreichen, auf Ergebnis warten.
xcrun notarytool submit "build/md-clip.dmg" \
  --keychain-profile "md-clip-notarytool" \
  --wait

# Notarization-Ticket ans DMG heften (sonst muss Gatekeeper jedes Mal online).
xcrun stapler staple "build/md-clip.dmg"

# Final verifizieren.
xcrun stapler validate "build/md-clip.dmg"
spctl --assess --type open --context context:primary-signature \
      -v "$APP_BUNDLE"
```

**Schritt 3: Erstmals laufen lassen** und Notarization-Output prüfen.

Bei Fehlern hilft:
```bash
xcrun notarytool log <submission-id> \
  --keychain-profile "md-clip-notarytool"
```

### Mögliche Stolpersteine

- **Hardened Runtime und bash-Launcher.** Unser `Contents/MacOS/md-clip`
  ist ein Bash-Skript. Apple lässt das zu, aber manche Entitlements machen
  Probleme. Falls Notarization scheitert, müssen wir entweder
  `entitlements.plist` mit `com.apple.security.cs.allow-unsigned-executable-memory`
  hinzufügen — oder den Launcher in ein kompiliertes Swift-Binary
  umschreiben. Ich tippe auf „läuft so, weil keine JIT-Allocs". Test
  zeigt's.
- **pandoc-Binary von github.com/jgm/pandoc** ist möglicherweise schon mit
  einem ANDEREN Zertifikat signiert. Mit `--force` überschreiben wir; das
  ist OK, weil wir es ja als Aggregat neu verteilen.
- **Notarization-Dauer**: 1–10 Minuten, manchmal auch 30+. Geduld.

### README anpassen

Sobald Stufe B durch ist, gehört im README eine Sektion **„Installation
ohne Terminal"** dazu:

1. Auf den Releases-Tab vom Repo gehen
2. Neueste `md-clip.dmg` herunterladen
3. Doppelklick → ins „Programme"-Ordner-Symbol ziehen
4. Fertig (kein Gatekeeper-Tanz)

---

## Stufe C — GitHub Action für Tag-Releases (⏳ später)

Sobald Stufe B lokal funktioniert: in CI heben.

### Skizze des Workflow

`.github/workflows/release.yml`:

- Trigger: `push: tags: ['v*']`
- Runner: `macos-latest` (ist arm64 seit 2024)
- Schritte:
  1. Apple-Cert aus Secret `MACOS_CERTIFICATE_P12_BASE64` in Runner-Keychain
     importieren (siehe Apple-Docs zu „importing a code-signing certificate
     in CI")
  2. Skript `wrappers/sign-and-release.sh` ausführen
  3. Notarization mit `--apple-id` / `--team-id` / `--password` aus Secrets
     statt aus Keychain (Keychain-Profile funktionieren in CI nicht
     zuverlässig)
  4. Stapler
  5. DMG als Release-Asset hochladen via `softprops/action-gh-release` oder
     `gh release create`

### Secrets, die in GitHub gesetzt werden müssen

| Secret | Inhalt |
|---|---|
| `MACOS_CERTIFICATE_P12_BASE64` | `.p12`-Export des Developer-ID-Application-Zertifikats als base64 |
| `MACOS_CERTIFICATE_P12_PASSWORD` | Passwort für den `.p12`-Export |
| `MACOS_NOTARIZATION_APPLE_ID` | <apple-id> |
| `MACOS_NOTARIZATION_TEAM_ID` | 9QSWKSR4NQ |
| `MACOS_NOTARIZATION_PASSWORD` | das App-spezifische Passwort |
| `MACOS_KEYCHAIN_PASSWORD` | Beliebiges starkes Passwort, schützt die temporäre Runner-Keychain während des Builds |

`.p12` exportieren:
- Schlüsselbundverwaltung öffnen
- Zertifikat „Developer ID Application: Daniel Mueller …" auswählen
- Rechtsklick → Exportieren → Format `.p12` → Passwort setzen
- Datei mit `base64 -i cert.p12 | pbcopy` ins Secret kopieren
  *(Vorsicht: pbcopy hier mit `LC_ALL=C` aufrufen, sonst Unicode-Bug)*

---

## Wenn du in einer neuen Claude-Session weitermachst

Zum Onboarden reicht:

> „Lies `docs/DISTRIBUTION.md`, wir wollen mit **Stufe B** weitermachen.
> Mein App-spezifisches Passwort habe ich/habe ich noch nicht im
> Schlüsselbund als Profil `md-clip-notarytool` hinterlegt."

Diese Datei ist self-contained — sie nennt alle Pfade, Team-ID, Befehle und
Stolpersteine.
