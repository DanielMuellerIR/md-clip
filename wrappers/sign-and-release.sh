#!/usr/bin/env bash
# wrappers/sign-and-release.sh — Stufe B: signiert das Bundle, packt es
# in ein DMG, schickt es zur Notarization an Apple und heftet das Ticket
# ans DMG. Ergebnis: ein DMG, das auf jedem Mac ohne Gatekeeper-Warnung
# per Doppelklick öffnet.
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

# ---------- Pfade ----------

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
PROJECT_ROOT="$(dirname "$SCRIPT_DIR")"
BUILD_DIR="$PROJECT_ROOT/build"
APP_BUNDLE="$BUILD_DIR/md-clip.app"

# Versions-String aus dem md-clip-Skript ziehen — Single Source of Truth.
APP_VERSION=$(grep '^VERSION=' "$PROJECT_ROOT/bin/md-clip" | head -1 | cut -d'"' -f2)
DMG_PATH="$BUILD_DIR/md-clip-${APP_VERSION}.dmg"

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

# ---------- 3. DMG erzeugen ----------

echo "==> Erzeuge DMG"

# Vorhandenes DMG aus alten Läufen entfernen — hdiutil meckert sonst.
rm -f "$DMG_PATH"

# UDZO = komprimiertes DMG, etwa 30% Platzersparnis vs. unkomprimiert.
# srcfolder = wir packen das .app als alleinigen Inhalt rein.
hdiutil create \
  -volname "md-clip" \
  -srcfolder "$APP_BUNDLE" \
  -ov \
  -format UDZO \
  "$DMG_PATH"

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
