#!/usr/bin/env bash
# wrappers/sign-and-release.sh — Stufe B: signiert das Bundle, packt es
# in ein DMG mit Installations-Layout (Applications-Shortcut, Hintergrund-
# bild, vorgegebene Icon-Positionen), schickt es zur Notarization an
# Apple und heftet das Ticket ans DMG. Ergebnis: ein DMG, das auf jedem
# Mac per Doppelklick öffnet, ohne Gatekeeper-Warnung.
#
# Voraussetzungen (einmalig):
#   1. Developer-ID-Application-Zertifikat in der Login-Keychain.
#      Prüfen: security find-identity -v -p codesigning
#   2. notarytool-Schlüsselbund-Profil 'md-clip-notarytool' eingerichtet:
#      xcrun notarytool store-credentials "md-clip-notarytool" \
#        --apple-id "<apple-id>" \
#        --team-id  "9QSWKSR4NQ"
#      (App-spezifisches Passwort INTERAKTIV eingeben, nicht als Argument)

set -euo pipefail

# ---------- Konstanten ----------

IDENTITY="Developer ID Application: Daniel Mueller (9QSWKSR4NQ)"
NOTARY_PROFILE="md-clip-notarytool"
TEAM_ID="9QSWKSR4NQ"

# DMG-Volume-Name = das, was im Finder über dem Fenster steht und in
# /Volumes/<name> gemountet wird. Wird auch im AppleScript referenziert.
DMG_VOLNAME="md-clip"

# ---------- Pfade ----------

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
PROJECT_ROOT="$(dirname "$SCRIPT_DIR")"
BUILD_DIR="$PROJECT_ROOT/build"
APP_BUNDLE="$BUILD_DIR/md-clip.app"
BACKGROUND_SRC="$PROJECT_ROOT/assets/dmg-background.png"

# Versions-String aus dem md-clip-Skript ziehen — Single Source of Truth.
APP_VERSION=$(grep '^VERSION=' "$PROJECT_ROOT/bin/md-clip" | head -1 | cut -d'"' -f2)
DMG_PATH="$BUILD_DIR/md-clip-${APP_VERSION}.dmg"
RW_DMG_PATH="$BUILD_DIR/md-clip-${APP_VERSION}-rw.dmg"

echo "==> md-clip Sign-and-Release v${APP_VERSION}"

# ---------- Sanity-Checks ----------

# Existiert die Signing-Identität?
if ! security find-identity -v -p codesigning | grep -q "$IDENTITY"; then
  echo "FEHLER: Signing-Identität nicht gefunden:" >&2
  echo "        $IDENTITY" >&2
  echo
  echo "Verfügbare Identitäten:" >&2
  security find-identity -v -p codesigning >&2
  exit 1
fi

# Existiert das Notary-Schlüsselbund-Profil?
# Wir testen es mit einem History-Aufruf — funktioniert nur mit gültigem Profil.
if ! xcrun notarytool history --keychain-profile "$NOTARY_PROFILE" >/dev/null 2>&1; then
  echo "FEHLER: notarytool-Schlüsselbund-Profil '$NOTARY_PROFILE' nicht eingerichtet." >&2
  echo
  echo "So einrichten (Passwort INTERAKTIV eingeben, NICHT als Argument!):" >&2
  echo "  xcrun notarytool store-credentials \"$NOTARY_PROFILE\" \\"  >&2
  echo "    --apple-id \"<apple-id>\" \\"                       >&2
  echo "    --team-id  \"$TEAM_ID\""                                   >&2
  echo
  echo "Danach fragt das Tool nach dem App-spezifischen Passwort." >&2
  exit 1
fi

# Hintergrundbild da?
if [ ! -f "$BACKGROUND_SRC" ]; then
  echo "FEHLER: DMG-Hintergrundbild nicht gefunden: $BACKGROUND_SRC" >&2
  echo "        Mit folgendem Befehl regenerieren:" >&2
  echo "        swift assets/generate-dmg-background.swift assets/dmg-background.png" >&2
  exit 1
fi

# ---------- 1. Bundle bauen (Stufe A) ----------

echo "==> Stufe A: Bundle bauen"
bash "$SCRIPT_DIR/build-app-bundled.sh"

# ---------- 2. Signieren ----------

# Reihenfolge: INNERE Binaries zuerst, dann das Bundle drumherum.
# Pandoc kommt ggf. schon mit der Apple-Signatur des pandoc-Releases — die
# überschreiben wir mit --force durch unsere Developer-ID-Signatur.
#
# --options runtime: Hardened Runtime aktivieren. Voraussetzung für
#                    Notarization seit 2020.
# --timestamp:       Apple's secure timestamp service einbinden. Sorgt
#                    dafür, dass die Signatur auch nach dem Ablauf des
#                    Zertifikats gültig bleibt.

echo "==> Signiere innere Binaries"
for binary in \
  "$APP_BUNDLE/Contents/Resources/bin/pandoc" \
  "$APP_BUNDLE/Contents/Resources/bin/clipboard-html" \
  "$APP_BUNDLE/Contents/Resources/bin/clipboard-rtf"
do
  echo "   $(basename "$binary")"
  codesign --sign "$IDENTITY" \
           --options runtime \
           --timestamp \
           --force \
           "$binary"
done

echo "==> Signiere App-Bundle"
# --deep stellt sicher, dass der Bundle-Code-Hash auch die schon
# signierten inneren Binaries einschließt. Apple rät zwar grundsätzlich
# von --deep ab, weil es bei komplexen Apps Macken hat — bei unserer
# flachen Struktur ist es aber unkritisch und einfacher als jedes Sub-
# Resource einzeln zu deklarieren.
codesign --sign "$IDENTITY" \
         --options runtime \
         --timestamp \
         --force --deep \
         "$APP_BUNDLE"

# Verifikation: bricht ab, wenn die Signatur kaputt oder unvollständig ist.
codesign --verify --strict --verbose=2 "$APP_BUNDLE"
echo "✓ Bundle signiert"

# ---------- 3. DMG mit Installations-Layout erzeugen ----------

# Strategie: schreibbares DMG bauen, mounten, Inhalte+Hintergrund rein-
# kopieren, Finder-Ansicht per AppleScript einrichten, aushängen, dann
# in komprimiertes Read-only-DMG konvertieren.

echo "==> Erzeuge DMG-Layout"

# Aufräumen von vorigen Läufen.
rm -f "$DMG_PATH" "$RW_DMG_PATH"

# Vorhandene Mounts mit gleichem Volume-Namen vorsichtig auswerfen.
# Wenn ein voriger Lauf abgebrochen ist, bleibt das DMG manchmal
# gemountet liegen und blockiert hdiutil create.
if [ -d "/Volumes/$DMG_VOLNAME" ]; then
  echo "   (vorhandenes Volume /Volumes/$DMG_VOLNAME wird ausgehängt)"
  hdiutil detach "/Volumes/$DMG_VOLNAME" -force >/dev/null 2>&1 || true
fi

# Größenbedarf grob abschätzen: Bundle + 20 MB Puffer für Hintergrund,
# DS_Store, Filesystem-Overhead. hdiutil reserviert das beim Erzeugen
# physisch, also nicht zu groß wählen — sonst wird das fertige DMG
# unnötig riesig, bevor wir es komprimieren.
BUNDLE_SIZE_MB=$(du -sm "$APP_BUNDLE" | cut -f1)
DMG_SIZE_MB=$((BUNDLE_SIZE_MB + 30))

# Schreibbares UDRW-DMG anlegen. HFS+ als Filesystem, weil das mit dem
# Finder-AppleScript-Layout problemlos zusammenspielt (APFS in DMGs ist
# inzwischen auch möglich, aber AppleScript-Set-Bounds verhält sich auf
# älteren macOS-Versionen unzuverlässig).
hdiutil create \
  -srcfolder "$APP_BUNDLE" \
  -volname   "$DMG_VOLNAME" \
  -fs        HFS+ \
  -fsargs    "-c c=64,a=16,e=16" \
  -format    UDRW \
  -size      "${DMG_SIZE_MB}m" \
  "$RW_DMG_PATH"

# Mounten. -nobrowse verhindert, dass das DMG im Finder als Fenster
# aufspringt während wir noch am Layout arbeiten.
MOUNT_DIR="/Volumes/$DMG_VOLNAME"
hdiutil attach "$RW_DMG_PATH" -mountpoint "$MOUNT_DIR" -nobrowse -noverify -noautoopen

# Applications-Shortcut (Symlink) reinlegen. Der Finder zeigt den
# automatisch mit Ordner-Icon „Applications" und Pfeil-Overlay an.
ln -s /Applications "$MOUNT_DIR/Applications"

# Hintergrundbild in versteckten Ordner kopieren. Doppelt absichern:
#   - Punkt-Präfix versteckt im Standard-Finder
#   - `chflags hidden` versteckt zusätzlich gegen das Finder-Setting
#     „unsichtbare Dateien anzeigen" (Cmd+Shift+. blendet sie trotzdem
#     wieder ein, aber wir positionieren das Element zusätzlich weit
#     außerhalb des sichtbaren Fensters — siehe AppleScript unten).
mkdir -p "$MOUNT_DIR/.background"
cp "$BACKGROUND_SRC" "$MOUNT_DIR/.background/background.png"
chflags hidden "$MOUNT_DIR/.background"

# Finder-Layout via AppleScript. Die Werte hier (Fenstergröße,
# Icon-Positionen) müssen mit dem Hintergrundbild zusammenpassen,
# das von assets/generate-dmg-background.swift erzeugt wird.
echo "==> Konfiguriere Finder-Ansicht"
osascript <<APPLESCRIPT
tell application "Finder"
  tell disk "$DMG_VOLNAME"
    open
    set current view of container window to icon view
    set toolbar visible of container window to false
    set statusbar visible of container window to false
    -- bounds {links, oben, rechts, unten} auf dem Bildschirm; die
    -- inneren Maße (rechts-links, unten-oben) müssen 600×400 ergeben
    -- — das ist die Größe des Hintergrundbilds.
    set the bounds of container window to {200, 120, 800, 520}
    set theViewOptions to the icon view options of container window
    set arrangement of theViewOptions to not arranged
    set icon size of theViewOptions to 128
    set text size of theViewOptions to 13
    set background picture of theViewOptions to file ".background:background.png"
    -- Icon-Positionen passend zu den Platzhalter-Rahmen im Hintergrund-
    -- bild. y=180 vertikal mittig, x=150 links / x=450 rechts.
    set position of item "md-clip.app" of container window to {150, 180}
    set position of item "Applications" of container window to {450, 180}
    -- .background-Ordner weit außerhalb der sichtbaren Fensterfläche
    -- parken. Das Fenster ist 600×400 — Koordinaten >800 sind sicher
    -- offscreen. Greift auch, wenn der Nutzer „unsichtbare Dateien
    -- anzeigen" aktiviert hat (Cmd+Shift+.); chflags hidden allein
    -- reicht in dem Fall nicht. try-Block, weil .background je nach
    -- Finder-Setting evtl. gar nicht als Item auftaucht.
    -- (Keine Backticks im Heredoc — sonst will Bash sie als Command-
    -- Substitution ausführen, weil der Heredoc nicht gequotet ist.)
    try
      set position of item ".background" of container window to {900, 900}
    end try
    update without registering applications
    close
  end tell
end tell
APPLESCRIPT

# Kurz warten, bis das Finder-AppleScript die .DS_Store geschrieben hat.
# Ohne das verliert das fertige DMG manchmal das Layout — Race-Condition
# zwischen Finder-Schreibe-Puffer und hdiutil detach.
sync
sleep 2

# Aushängen.
echo "==> Hänge RW-DMG aus"
hdiutil detach "$MOUNT_DIR" -force

# In komprimiertes Read-only-DMG konvertieren.
echo "==> Konvertiere zu UDZO (komprimiert, read-only)"
hdiutil convert "$RW_DMG_PATH" \
  -format UDZO \
  -imagekey zlib-level=9 \
  -o "$DMG_PATH"

rm -f "$RW_DMG_PATH"

# DMG selbst signieren. Sonst hängt Gatekeeper schon beim Download das
# Quarantine-Bit ans DMG, und das DMG selbst meckert beim ersten Öffnen.
codesign --sign "$IDENTITY" \
         --timestamp \
         --force \
         "$DMG_PATH"

echo "✓ DMG: $(basename "$DMG_PATH") ($(du -h "$DMG_PATH" | cut -f1))"

# ---------- 4. Bei Apple zur Notarization einreichen ----------

echo "==> Reiche zur Notarization ein (1-10 Min, manchmal länger)"

# --wait blockiert, bis Apple geantwortet hat. Ohne wäre der Befehl
# sofort fertig und man müsste später per Submission-ID den Status pollen.
xcrun notarytool submit "$DMG_PATH" \
  --keychain-profile "$NOTARY_PROFILE" \
  --wait

echo "✓ Notarization akzeptiert"

# ---------- 5. Notarization-Ticket ans DMG heften ----------

# stapler heftet das von Apple ausgestellte Ticket an die DMG. Ohne den
# Schritt müsste Gatekeeper beim ersten Öffnen online den Status prüfen.
# Mit Stapler funktioniert es auch offline.
echo "==> Stapele Notarization-Ticket"
xcrun stapler staple "$DMG_PATH"

# ---------- 6. Verifizieren ----------

echo "==> Verifizierung"
xcrun stapler validate "$DMG_PATH"

# spctl simuliert, was Gatekeeper beim Öffnen tun würde. Wenn das hier
# durchgeht, geht es auch auf fremden Macs durch.
spctl --assess --type open --context context:primary-signature \
      -v "$APP_BUNDLE"

# ---------- Fertig ----------

echo
echo "==> Fertig"
echo "    DMG:     $DMG_PATH"
echo "    Größe:   $(du -h "$DMG_PATH" | cut -f1)"
echo
echo "Test auf diesem Mac:"
echo "  open \"$DMG_PATH\""
echo
echo "Distribution: das DMG kann jetzt z.B. als GitHub-Release-Asset"
echo "hochgeladen werden. Auf fremden Macs öffnet es ohne Gatekeeper-Warnung."
