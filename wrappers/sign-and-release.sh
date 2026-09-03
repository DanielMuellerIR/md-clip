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
#   2. notarytool-Schlüsselbund-Profil eingerichtet (Name frei wählbar, er
#      kommt später aus NOTARY_PROFILE bzw. git config mdClip.notaryProfile):
#      xcrun notarytool store-credentials "<profilname>" \
#        --apple-id "<deine-apple-id>" \
#        --team-id  "9QSWKSR4NQ"
#      (App-spezifisches Passwort INTERAKTIV eingeben, nicht als Argument)

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
PROJECT_ROOT="$(dirname "$SCRIPT_DIR")"
# shellcheck source=notarization.sh
source "$SCRIPT_DIR/notarization.sh"
# shellcheck source=version.sh
source "$SCRIPT_DIR/version.sh"

# ---------- Konstanten ----------

# Die Apple-ID braucht dieses Skript nicht: Die Zugangsdaten liegen vollständig
# im notarytool-Profil im Schlüsselbund. Sie taucht nur noch als Platzhalter im
# Einrichtungs-Hinweis weiter unten auf.

# Team-ID und Identitaet kommen aus wrappers/notarization.sh — derselben Datei,
# aus der auch install-app.sh sie holt. Ueber APPLE_TEAM_ID und
# CODESIGN_IDENTITY bleiben sie ueberschreibbar (CI/anderer Account).
resolve_signing_identity

resolve_notary_profile "$PROJECT_ROOT" || exit $?

# --no-finder-layout überspringt den AppleScript-Schritt: Er öffnet ein echtes
# Finder-Fenster und reißt den Fokus an sich, was headless-Läufe (und Läufe neben
# laufender Arbeit) stört. Das DMG ist dann funktional, aber ohne Layout und
# Hintergrundbild — für ein echtes Release also nicht benutzen.
FINDER_LAYOUT=1
for arg in "$@"; do
  case "$arg" in
    --no-finder-layout) FINDER_LAYOUT=0 ;;
    *) echo "Unbekannte Option: $arg" >&2
       echo "Aufruf: ./release.sh [--no-finder-layout]" >&2; exit 2 ;;
  esac
done

# DMG-Volume-Name = das, was im Finder über dem Fenster steht. Der reale
# Mountpoint ist absichtlich ein privates Build-Verzeichnis; fremde Volumes
# gleichen Namens dürfen niemals angefasst werden.
DMG_VOLNAME="md-clip"

# ---------- Pfade ----------

BUILD_DIR="$PROJECT_ROOT/build"
APP_BUNDLE="$BUILD_DIR/md-clip.app"
BACKGROUND_SRC="$PROJECT_ROOT/assets/dmg-background.png"

# Versions-String aus dem md-clip-Skript ziehen — Single Source of Truth.
# Ohne die Prüfung hiesse das Release-Artefakt bei einer unlesbaren Zeile
# `md-clip-.dmg` und würde genau so veröffentlicht.
APP_VERSION="$(md_clip_version "$PROJECT_ROOT/bin/md-clip" || true)"
if [ -z "$APP_VERSION" ]; then
  echo "FEHLER: VERSION fehlt in bin/md-clip." >&2
  exit 65
fi
DMG_PATH="$BUILD_DIR/md-clip-${APP_VERSION}.dmg"
PENDING_DMG_PATH="$BUILD_DIR/.md-clip-${APP_VERSION}.pending.dmg"
RW_DMG_PATH="$BUILD_DIR/md-clip-${APP_VERSION}-rw.dmg"
# Gesetzt, sobald hdiutil create das Image angelegt hat: nur dann darf die
# Aufraeumroutine es loeschen. Vorher koennte dort noch das Image eines
# frueheren Laufs liegen, das uns nicht gehoert.
RW_DMG_OWNED=""
PENDING_DMG_OWNED=""

echo "==> md-clip Sign-and-Release v${APP_VERSION}"

# ---------- Sanity-Checks ----------

# Existiert die Signing-Identität?
require_signing_identity "$IDENTITY" || exit 1

# Existiert das Notary-Schlüsselbund-Profil?
# Wir testen es mit einem History-Aufruf — funktioniert nur mit gültigem Profil.
#
# Warum mit Wiederholungen: Der Aufruf meldet gelegentlich fälschlich
# „No Keychain password item found", obwohl das Profil da ist (am 2026-07-26
# belegt — Versuch 1 fehlgeschlagen, Versuch 2 sofort OK, dazwischen nichts
# verändert). Ein einzelner Fehlversuch würde hier einen kompletten Release-Lauf
# abbrechen. Ein wirklich fehlendes Profil scheitert dagegen auch nach fünf
# Versuchen; die Aussagekraft geht also nicht verloren.
verify_notary_profile "$NOTARY_PROFILE" "$TEAM_ID" || exit 1

# Hintergrundbild da?
if [ ! -f "$BACKGROUND_SRC" ]; then
  echo "FEHLER: DMG-Hintergrundbild nicht gefunden: $BACKGROUND_SRC" >&2
  echo "        Mit folgendem Befehl regenerieren:" >&2
  echo "        swift assets/generate-dmg-background.swift assets/dmg-background.png" >&2
  exit 1
fi

# ---------- Aufräumen ----------
# Alles, was der Lauf temporär anlegt, hängt an einer dieser Variablen. Der
# Trap steht bewusst VOR dem ersten mktemp: Ein Abbruch beim Notarisieren oder
# beim DMG-Layout darf weder ein großes App-Archiv noch einen eingehängten
# privaten Mount hinterlassen.
NOTARY_APP_ZIP_DIR=""
MOUNT_DIR=""
MOUNT_DEVICE=""
MOUNT_MAY_BE_ATTACHED=""
ATTACH_PLIST=""

# BEGIN RELEASE_CLEANUP
# Aushängen mit Wiederholung: Direkt nach dem Finder-AppleScript hält das
# System das Volume manchmal noch einen Moment fest, und ein einzelner
# Fehlversuch würde das Device hängen lassen.
#
# Bewusst OHNE `-force`: Ein erzwungenes Aushängen kann laufende Schreibvorgänge
# abschneiden. Diese Regel hält tests/test-wrapper-safety.sh fest.
detach_release_mount() {
  local device="$1"
  local attempt
  for attempt in 1 2 3; do
    hdiutil detach "$device" >/dev/null 2>&1 && return 0
    sleep 2
  done
  return 1
}

cleanup_release() {
  cleanup_notary_archive
  if [ -n "$MOUNT_DEVICE" ]; then
    # Die Referenz erst nach erfolgreichem Aushängen löschen. Sonst wäre nach
    # einem gescheiterten Versuch das einzige Handle auf unser Device weg und
    # niemand könnte den Mount noch gezielt lösen.
    if detach_release_mount "$MOUNT_DEVICE"; then
      MOUNT_DEVICE=""
      MOUNT_MAY_BE_ATTACHED=""
    else
      echo "WARNUNG: Eigenes DMG-Device ließ sich nicht aushängen: $MOUNT_DEVICE" >&2
      echo "         Bitte von Hand prüfen: hdiutil info" >&2
    fi
  fi
  if [ -n "$ATTACH_PLIST" ] && [ -f "$ATTACH_PLIST" ]; then
    rm -f "$ATTACH_PLIST"
    ATTACH_PLIST=""
  fi
  if [ -n "$MOUNT_DIR" ] && [ -d "$MOUNT_DIR" ]; then
    if rmdir "$MOUNT_DIR" >/dev/null 2>&1; then
      MOUNT_DIR=""
      # Wenn kein Device ermittelt werden konnte, beweist das erfolgreiche
      # rmdir immerhin, dass an diesem privaten Pfad nichts mehr gemountet ist.
      if [ -z "$MOUNT_DEVICE" ]; then
        MOUNT_MAY_BE_ATTACHED=""
      fi
    elif [ -n "$MOUNT_MAY_BE_ATTACHED" ] && [ -z "$MOUNT_DEVICE" ]; then
      echo "WARNUNG: DMG-Mount konnte keinem Device zugeordnet werden; nichts wird gelöscht." >&2
      echo "         Privater Mountpfad: $MOUNT_DIR" >&2
      echo "         Bitte von Hand prüfen: hdiutil info" >&2
    fi
  fi
  # Das schreibbare Zwischen-Image ist mehrere hundert MB groß und wurde im
  # regulären Weg erst nach der Konvertierung gelöscht — jeder Abbruch davor
  # ließ es im Build-Verzeichnis liegen (Review-Fund 2026-08-05).
  #
  # ERST nach dem Aushängen: Solange oben ein Device hängt, ist die Datei die
  # Unterlage dieses Mounts, und sie wegzuziehen hinterlässt ein kaputtes
  # Volume statt aufzuräumen. Schlug das Detach fehl, steht MOUNT_DEVICE noch —
  # dann bleibt auch das Image liegen, mitsamt der Warnung von oben.
  if [ -n "$RW_DMG_OWNED" ] \
     && [ -z "$MOUNT_DEVICE" ] \
     && [ -z "$MOUNT_MAY_BE_ATTACHED" ]; then
    rm -f "$RW_DMG_PATH"
    RW_DMG_OWNED=""
  fi
  if [ -n "$PENDING_DMG_OWNED" ]; then
    rm -f "$PENDING_DMG_PATH"
    PENDING_DMG_OWNED=""
  fi
}
# END RELEASE_CLEANUP

# Bei Strg-C oder `kill` reicht Aufräumen nicht: Ohne eigenes `exit` liefe das
# Skript hinter dem Trap einfach weiter. Die Codes 130/143 sind die üblichen
# Werte für Abbruch per INT beziehungsweise TERM (128 + Signalnummer).
trap cleanup_release EXIT
trap 'cleanup_release; exit 130' INT
trap 'cleanup_release; exit 143' TERM

# ---------- 1. Bundle bauen (Stufe A) ----------

echo "==> Stufe A: Bundle bauen"
bash "$SCRIPT_DIR/build-app-bundled.sh"

# ---------- 2. Signieren ----------

# Reihenfolge (innen nach außen, inkl. Sparkle-Framework und Updater-Helfer)
# steht zentral in wrappers/sign-bundle.sh — dieselbe Datei benutzt auch
# install-app.sh, damit Installation und Release nicht auseinanderlaufen.
echo "==> Signiere Bundle (wrappers/sign-bundle.sh)"
bash "$SCRIPT_DIR/sign-bundle.sh" "$APP_BUNDLE" "$IDENTITY"
bash "$SCRIPT_DIR/verify-bundle.sh" "$APP_BUNDLE" --signed --team-id "$TEAM_ID"
echo "✓ Bundle signiert"

# ---------- 2b. App notarisieren ----------
# Vor dem DMG, nicht danach: Wer die App aus dem Image herauszieht, hätte sonst
# ein Bundle ohne eigenes Ticket — das Ticket des DMG reist nicht mit. notarytool
# nimmt kein nacktes .app entgegen, deshalb der Umweg über ein ZIP. Das
# angeheftete Ticket landet als Datei im Bundle und wird unten mitkopiert.
echo "==> Notarisiere App-Bundle (Profil $NOTARY_PROFILE)"
notarize_app_bundle "$APP_BUNDLE" "$NOTARY_PROFILE"
echo "✓ App notarisiert und gestapelt"

# ---------- 3. DMG mit Installations-Layout erzeugen ----------

# Strategie: schreibbares DMG bauen, mounten, Inhalte+Hintergrund rein-
# kopieren, Finder-Ansicht per AppleScript einrichten, aushängen, dann
# in komprimiertes Read-only-DMG konvertieren.

echo "==> Erzeuge DMG-Layout"

# Aufräumen von vorigen Läufen.
rm -f "$DMG_PATH" "$PENDING_DMG_PATH" "$RW_DMG_PATH"

# Nur das von DIESEM Lauf eingehängte Device darf die Aufräumroutine lösen.
# `hdiutil attach -plist` liefert den eindeutigen Device-Pfad; ein gleichnamiges
# fremdes Volume unter /Volumes bleibt damit vollständig unberührt. Variablen
# und Aufräumroutine stehen weiter oben, siehe Abschnitt „Aufräumen".

# BEGIN DEVICE_FOR_MOUNTPOINT
device_for_mountpoint() {
  local plist_path="$1"
  local expected_mount="$2"
  local plistbuddy="${3:-/usr/libexec/PlistBuddy}"
  local index=0
  local device=""
  local mountpoint=""

  while device=$("$plistbuddy" -c "Print :system-entities:$index:dev-entry" "$plist_path" 2>/dev/null); do
    mountpoint=$("$plistbuddy" -c "Print :system-entities:$index:mount-point" "$plist_path" 2>/dev/null || true)
    if [ "$mountpoint" = "$expected_mount" ]; then
      printf '%s\n' "$device"
      return 0
    fi
    index=$((index + 1))
  done

  return 1
}
# END DEVICE_FOR_MOUNTPOINT

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
RW_DMG_OWNED=1

# Mounten. -nobrowse verhindert, dass das DMG im Finder als Fenster
# aufspringt während wir noch am Layout arbeiten. Plist und Mountpoint
# gehören ausschließlich diesem Lauf.
# Die Platzhalter müssen ganz am Ende der Vorlage stehen: Darwins `mktemp`
# ersetzt nur dort die X-Kette. Bei `.md-clip-attach.XXXXXX.plist` entstünde
# wörtlich dieser Pfad — zwei Läufe kollidierten, und eine liegengebliebene
# Datei blockierte jeden weiteren.
MOUNT_DIR=$(mktemp -d "$BUILD_DIR/.md-clip-mount.XXXXXX")
ATTACH_PLIST=$(mktemp "$BUILD_DIR/.md-clip-attach.plist.XXXXXX")
MOUNT_MAY_BE_ATTACHED=1
hdiutil attach "$RW_DMG_PATH" \
  -mountpoint "$MOUNT_DIR" \
  -nobrowse -noverify -noautoopen -plist > "$ATTACH_PLIST"
MOUNT_DEVICE=$(device_for_mountpoint "$ATTACH_PLIST" "$MOUNT_DIR") || {
  echo "FEHLER: Device des privaten DMG-Mounts nicht in hdiutil-Plist gefunden." >&2
  exit 1
}

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
if [ "$FINDER_LAYOUT" -eq 1 ]; then
echo "==> Konfiguriere Finder-Ansicht"
MOUNT_DIR="$MOUNT_DIR" osascript <<'APPLESCRIPT'
set mountPath to system attribute "MOUNT_DIR"
tell application "Finder"
  set targetDisk to disk of (POSIX file mountPath as alias)
  tell targetDisk
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
    -- Der Heredoc ist gequotet; Pfade kommen ausschließlich über die
    -- Umgebung und werden nicht als AppleScript-Quelle interpretiert.
    try
      set position of item ".background" of container window to {900, 900}
    end try
    update without registering applications
    close
  end tell
end tell
APPLESCRIPT
else
  echo "==> Finder-Ansicht übersprungen (--no-finder-layout)"
fi

# Kurz warten, bis das Finder-AppleScript die .DS_Store geschrieben hat.
# Ohne das verliert das fertige DMG manchmal das Layout — Race-Condition
# zwischen Finder-Schreibe-Puffer und hdiutil detach.
sync
sleep 2

# Aushängen.
echo "==> Hänge RW-DMG aus"
detach_release_mount "$MOUNT_DEVICE" || {
  echo "FEHLER: Eigenes DMG-Device ließ sich nicht aushängen: $MOUNT_DEVICE" >&2
  exit 1
}
MOUNT_DEVICE=""
MOUNT_MAY_BE_ATTACHED=""
rmdir "$MOUNT_DIR"
MOUNT_DIR=""
rm -f "$ATTACH_PLIST"
ATTACH_PLIST=""

# In komprimiertes Read-only-DMG konvertieren.
echo "==> Konvertiere zu UDZO (komprimiert, read-only)"
PENDING_DMG_OWNED=1
hdiutil convert "$RW_DMG_PATH" \
  -format UDZO \
  -imagekey zlib-level=9 \
  -o "$PENDING_DMG_PATH"

rm -f "$RW_DMG_PATH"
RW_DMG_OWNED=""

# DMG selbst signieren. Sonst hängt Gatekeeper schon beim Download das
# Quarantine-Bit ans DMG, und das DMG selbst meckert beim ersten Öffnen.
codesign --sign "$IDENTITY" \
         --timestamp \
         --force \
         "$PENDING_DMG_PATH"

echo "✓ DMG gebaut: $(du -h "$PENDING_DMG_PATH" | cut -f1)"

# ---------- 4. Bei Apple zur Notarization einreichen ----------

echo "==> Reiche zur Notarization ein (1-10 Min, manchmal länger)"

# --wait blockiert, bis Apple geantwortet hat. Ohne wäre der Befehl
# sofort fertig und man müsste später per Submission-ID den Status pollen.
xcrun notarytool submit "$PENDING_DMG_PATH" \
  --keychain-profile "$NOTARY_PROFILE" \
  --wait

echo "✓ Notarization akzeptiert"

# ---------- 5. Notarization-Ticket ans DMG heften ----------

# stapler heftet das von Apple ausgestellte Ticket an die DMG. Ohne den
# Schritt müsste Gatekeeper beim ersten Öffnen online den Status prüfen.
# Mit Stapler funktioniert es auch offline.
echo "==> Stapele Notarization-Ticket"
xcrun stapler staple "$PENDING_DMG_PATH"

# ---------- 6. Verifizieren ----------

echo "==> Verifizierung"
xcrun stapler validate "$PENDING_DMG_PATH"

# spctl simuliert, was Gatekeeper beim Öffnen tun würde. Wenn das hier
# durchgeht, geht es auch auf fremden Macs durch.
#
# Geprüft wird das DMG, nicht die App: `--type open` ist die Policy fürs
# Öffnen eines Disk-Images, und ausgeliefert wird genau dieses Image. Die App
# selbst wurde weiter oben mit der für sie zuständigen Policy `--type execute`
# bewertet.
spctl --assess --type open --context context:primary-signature \
      -v "$PENDING_DMG_PATH"

# Erst ein vollständig geprüftes Image erhält den veröffentlichten Dateinamen.
# Ein Fehler bei Signatur, Notarisierung oder Gatekeeper-Prüfung lässt damit
# kein scheinbar fertiges Release-Artefakt im Build-Verzeichnis zurück.
mv "$PENDING_DMG_PATH" "$DMG_PATH"
PENDING_DMG_OWNED=""

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
