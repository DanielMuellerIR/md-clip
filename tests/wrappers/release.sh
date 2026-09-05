#!/usr/bin/env bash
# Vom Wrapper-Testrunner im isolierten Testverzeichnis geladen.
TEST_SCRIPT="${BASH_SOURCE[0]}"
# --- Release: nur privater Mountpoint und von attach gemeldetes Device. ---
RELEASE_SCRIPT="$PROJECT_ROOT/wrappers/sign-and-release.sh"
NOTARY_HELPER="$PROJECT_ROOT/wrappers/notarization.sh"
# shellcheck source=../wrappers/notarization.sh
source "$NOTARY_HELPER"
grep -Fq 'mktemp -d "$BUILD_DIR/.md-clip-mount.XXXXXX"' "$RELEASE_SCRIPT"
grep -Fq -- '-plist > "$ATTACH_PLIST"' "$RELEASE_SCRIPT"
grep -Fq 'detach_release_mount "$MOUNT_DEVICE"' "$RELEASE_SCRIPT"
grep -Fq 'hdiutil detach "$device"' "$RELEASE_SCRIPT"
if grep -Eq 'hdiutil detach "/Volumes|hdiutil detach "\$MOUNT_DIR"|hdiutil detach .*force' "$RELEASE_SCRIPT"; then
  echo "✗ Release-Skript enthält weiterhin namens- oder mountpointbasiertes Force-Detach" >&2
  exit 1
fi
echo "✓ Release-Skript löst ausschließlich das eigene attach-Device"

# Die Zuordnung selbst läuft gegen den echten Funktionsblock. Der erste
# Plist-Eintrag ist absichtlich nur ein Präfixtreffer; ausschließlich der
# zweite, exakt passende Mountpoint darf sein Device liefern.
DEVICE_SELECTOR="$TEST_ROOT/device-for-mountpoint.sh"
extract_shell_block "$RELEASE_SCRIPT" DEVICE_FOR_MOUNTPOINT "$DEVICE_SELECTOR"
# shellcheck source=/dev/null
source "$DEVICE_SELECTOR"
cat > "$TEST_ROOT/fake-bin/PlistBuddy-device" <<'SH'
#!/bin/sh
case "$2" in
  *:0:dev-entry) printf '/dev/disk-prefix\n' ;;
  *:0:mount-point) printf '/private/md-clip-mount-other\n' ;;
  *:1:dev-entry) printf '/dev/disk-exact\n' ;;
  *:1:mount-point) printf '/private/md-clip-mount\n' ;;
  *) exit 1 ;;
esac
SH
chmod +x "$TEST_ROOT/fake-bin/PlistBuddy-device"
SELECTED_DEVICE=$(device_for_mountpoint \
  "$TEST_ROOT/attach.plist" \
  /private/md-clip-mount \
  "$TEST_ROOT/fake-bin/PlistBuddy-device")
[ "$SELECTED_DEVICE" = /dev/disk-exact ]
echo "✓ Release ordnet nur den exakt passenden Mountpoint seinem Device zu"

# --- Release: das schreibbare Zwischen-Image hängt am Cleanup. ---
# Es ist mehrere hundert MB groß und wurde früher erst im Erfolgsweg gelöscht;
# jeder Abbruch davor ließ es liegen (Review-Fund 2026-08-05). Geprüft wird die
# ganze Kette der Zuständigkeit: erst nach `hdiutil create` übernehmen, im
# Cleanup nur bei ausgehängtem Device löschen, nach der regulären Löschung
# wieder abgeben.
grep -Fxq 'RW_DMG_OWNED=1' "$RELEASE_SCRIPT"
grep -Fq 'if [ -n "$RW_DMG_OWNED" ] \' "$RELEASE_SCRIPT"
grep -Fq '&& [ -z "$MOUNT_MAY_BE_ATTACHED" ]; then' "$RELEASE_SCRIPT"
# Die Übernahme muss NACH der Erzeugung stehen, sonst räumt der Cleanup ein
# fremdes Image ab, das dort schon lag.
CREATE_LINE=$(grep -n '^hdiutil create' "$RELEASE_SCRIPT" | head -1 | cut -d: -f1)
OWNED_LINE=$(grep -n '^RW_DMG_OWNED=1$' "$RELEASE_SCRIPT" | head -1 | cut -d: -f1)
if [ -z "$CREATE_LINE" ] || [ -z "$OWNED_LINE" ] || [ "$OWNED_LINE" -lt "$CREATE_LINE" ]; then
  echo "✗ Zuständigkeit für das RW-Image wird nicht nach hdiutil create übernommen" >&2
  exit 1
fi
echo "✓ Release-Skript räumt sein schreibbares Zwischen-Image auch bei Abbruch weg"

# Schlägt nach einem erfolgreichen attach nur die Plist-Auswertung fehl, ist
# das Device unbekannt, der private Mount kann aber noch aktiv sein. In diesem
# Zustand dürfen weder seine Image-Unterlage noch der Pfad vergessen werden.
RELEASE_CLEANUP_BLOCK="$TEST_ROOT/release-cleanup.sh"
extract_shell_block "$RELEASE_SCRIPT" RELEASE_CLEANUP "$RELEASE_CLEANUP_BLOCK"
# shellcheck source=/dev/null
source "$RELEASE_CLEANUP_BLOCK"

RELEASE_CLEANUP_ROOT="$TEST_ROOT/release-cleanup-state"
MOUNT_DIR="$RELEASE_CLEANUP_ROOT/mount"
RW_DMG_PATH="$RELEASE_CLEANUP_ROOT/intermediate.dmg"
PENDING_DMG_PATH="$RELEASE_CLEANUP_ROOT/pending.dmg"
mkdir -p "$MOUNT_DIR"
printf 'simulierter aktiver Mount\n' > "$MOUNT_DIR/inhalt"
printf 'image\n' > "$RW_DMG_PATH"
printf 'noch nicht geprüft\n' > "$PENDING_DMG_PATH"
NOTARY_APP_ZIP_DIR=""
ATTACH_PLIST=""
MOUNT_DEVICE=""
MOUNT_MAY_BE_ATTACHED=1
RW_DMG_OWNED=1
PENDING_DMG_OWNED=1

cleanup_release 2> "$RELEASE_CLEANUP_ROOT/unknown-device.err"
[ -f "$RW_DMG_PATH" ]
[ ! -e "$PENDING_DMG_PATH" ]
[ -n "$MOUNT_DIR" ]
[ -n "$MOUNT_MAY_BE_ATTACHED" ]
grep -Fq 'DMG-Mount konnte keinem Device zugeordnet werden' \
  "$RELEASE_CLEANUP_ROOT/unknown-device.err"

# Ist der Pfad danach nachweislich leer und rmdir gelingt, darf der Cleanup
# den unklaren Zustand auflösen und das eigene Zwischen-Image entfernen.
rm -f "$MOUNT_DIR/inhalt"
cleanup_release
[ ! -e "$RW_DMG_PATH" ]
[ -z "$MOUNT_DIR" ]
[ -z "$MOUNT_MAY_BE_ATTACHED" ]
[ -z "$RW_DMG_OWNED" ]
[ -z "$PENDING_DMG_OWNED" ]
echo "✓ Release-Cleanup bewahrt ein Image bei unbekanntem Mountzustand"

# Der öffentliche Release-Name darf erst nach allen Prüfungen entstehen.
PENDING_CONVERT_LINE=$(grep -n -- '-o "$PENDING_DMG_PATH"' "$RELEASE_SCRIPT" | cut -d: -f1)
GATEKEEPER_LINE=$(grep -n 'spctl --assess --type open' "$RELEASE_SCRIPT" | cut -d: -f1)
PUBLISH_LINE=$(grep -n '^mv "$PENDING_DMG_PATH" "$DMG_PATH"$' "$RELEASE_SCRIPT" | cut -d: -f1)
if [ -z "$PENDING_CONVERT_LINE" ] || [ -z "$GATEKEEPER_LINE" ] || [ -z "$PUBLISH_LINE" ] \
   || [ "$PENDING_CONVERT_LINE" -ge "$GATEKEEPER_LINE" ] \
   || [ "$GATEKEEPER_LINE" -ge "$PUBLISH_LINE" ]; then
  echo "✗ Release veröffentlicht das DMG vor Abschluss aller Prüfungen" >&2
  exit 1
fi
grep -Fq 'rm -f "$PENDING_DMG_PATH"' "$RELEASE_CLEANUP_BLOCK"
echo "✓ Release veröffentlicht nur ein vollständig geprüftes DMG"

# Nur der belegte sporadische Keychain-Fehler wird wiederholt. Andere Fehler
# bleiben im Log sichtbar und brechen sofort ab.
NOTARY_CHECK="$TEST_ROOT/notary-profile-check.sh"
extract_shell_block "$NOTARY_HELPER" NOTARY_PROFILE_CHECK "$NOTARY_CHECK"
# shellcheck source=/dev/null
source "$NOTARY_CHECK"
cat > "$TEST_ROOT/fake-bin/xcrun" <<'SH'
#!/bin/sh
count_file="$MD_CLIP_NOTARY_COUNT"
count=$(cat "$count_file" 2>/dev/null || printf 0)
count=$((count + 1))
printf '%s\n' "$count" > "$count_file"
case "${MD_CLIP_NOTARY_MODE:-fatal}" in
  transient)
    if [ "$count" -lt 3 ]; then
      echo 'No Keychain password item found' >&2
      exit 1
    fi
    ;;
  fatal)
    echo 'The network connection was lost' >&2
    exit 1
    ;;
esac
SH
cat > "$TEST_ROOT/fake-bin/sleep" <<'SH'
#!/bin/sh
exit 0
SH
chmod +x "$TEST_ROOT/fake-bin/xcrun" "$TEST_ROOT/fake-bin/sleep"
export MD_CLIP_NOTARY_COUNT="$TEST_ROOT/notary-count"
if MD_CLIP_NOTARY_MODE=fatal notary_profile_works \
  testprofil \
  >"$TEST_ROOT/notary-fatal.out" 2>"$TEST_ROOT/notary-fatal.err"; then
  echo "✗ Notary-Profilcheck ignoriert einen Netzwerkfehler" >&2
  exit 1
fi
[ "$(cat "$MD_CLIP_NOTARY_COUNT")" = 1 ]
grep -Fq 'network connection was lost' "$TEST_ROOT/notary-fatal.err"
rm -f "$MD_CLIP_NOTARY_COUNT"
MD_CLIP_NOTARY_MODE=transient notary_profile_works testprofil
[ "$(cat "$MD_CLIP_NOTARY_COUNT")" = 3 ]
rm -f "$TEST_ROOT/fake-bin/xcrun" "$TEST_ROOT/fake-bin/sleep"
hash -r
echo "✓ Notary-Profilcheck wiederholt nur den belegten Keychain-Fehler"
grep -Fq 'source wrappers/notarization.sh' "$PROJECT_ROOT/install-app.sh"
grep -Fq 'source "$SCRIPT_DIR/notarization.sh"' "$RELEASE_SCRIPT"
grep -Fq 'notarize_app_bundle "$APP" "$NOTARY_PROFILE"' "$PROJECT_ROOT/install-app.sh"
grep -Fq 'notarize_app_bundle "$APP_BUNDLE" "$NOTARY_PROFILE"' "$RELEASE_SCRIPT"

# Auch die Developer-ID-Vorgabe darf nur einmal im Repo stehen: Zwei eigene
# Fassungen würden bedeuten, dass Installation und Release dasselbe Bundle
# irgendwann mit verschiedenen Zertifikaten signieren.
for signing_script in "$PROJECT_ROOT/install-app.sh" "$RELEASE_SCRIPT"; do
  if ! grep -Fq 'resolve_signing_identity' "$signing_script"; then
    echo "✗ $signing_script holt die Developer-ID nicht aus notarization.sh" >&2
    exit 1
  fi
  # Kommentarzeilen weg: Die Begründung im Skript darf die Namen nennen.
  if grep -v '^[[:space:]]*#' "$signing_script" \
    | grep -Eq 'TEAM_ID="\$\{APPLE_TEAM_ID|IDENTITY="\$\{CODESIGN_IDENTITY'; then
    echo "✗ $signing_script hat eine eigene Developer-ID-Vorgabe" >&2
    exit 1
  fi
done
# Die Vorgabe selbst bleibt über die Umgebung überschreibbar.
(
  APPLE_TEAM_ID=ABCDE12345 CODESIGN_IDENTITY="" resolve_signing_identity
  [ "$TEAM_ID" = "ABCDE12345" ]
  [ "$IDENTITY" = "Developer ID Application: Daniel Mueller (ABCDE12345)" ]
  CODESIGN_IDENTITY="Eigene Identitaet" resolve_signing_identity
  [ "$IDENTITY" = "Eigene Identitaet" ]
)
echo "✓ Installation und Release verwenden dieselbe Notarisierungs- und Signaturvorgabe"

# --- Release: die Plist-Vorlage muss wirklich eindeutige Pfade liefern. ---
# Darwins mktemp ersetzt die X-Kette nur am ENDE der Vorlage. Stünde noch ein
# Suffix dahinter, entstünde wörtlich dieser Pfad — der zweite Aufruf scheiterte.
grep -Fq 'mktemp "$BUILD_DIR/.md-clip-attach.plist.XXXXXX"' "$RELEASE_SCRIPT"
mkdir -p "$TEST_ROOT/mktemp-probe"
PLIST_ONE=$(mktemp "$TEST_ROOT/mktemp-probe/.md-clip-attach.plist.XXXXXX")
PLIST_TWO=$(mktemp "$TEST_ROOT/mktemp-probe/.md-clip-attach.plist.XXXXXX")
if [ "$PLIST_ONE" = "$PLIST_TWO" ]; then
  echo "✗ Plist-Vorlage liefert keinen eindeutigen Pfad" >&2
  exit 1
fi
echo "✓ Release-Skript bekommt fuer jede Plist einen eindeutigen Pfad"

# Pfad des privilegierten Workflows. Steht hier, weil ihn schon der
# Versionsvertrag unten braucht — weiter unten benutzen ihn die
# Appcast-Prüfungen weiter.
APPCAST_WORKFLOW="$PROJECT_ROOT/.github/workflows/publish-appcast.yml"

# --- Version: eine Grammatik für alle sechs Leser. ---
# bin/md-clip trägt die Produktversion; gelesen wird sie in build.sh,
# build-app-bundled.sh, verify-bundle.sh, install-app.sh, sign-and-release.sh
# und im Appcast-Workflow. Vorher standen dort drei Schreibweisen nebeneinander
# — die im Workflow ohne `head`, die also bei zwei VERSION-Zeilen etwas anderes
# gelesen hätte als der Build (Querschnitts-Fund 2026-09-03).
# shellcheck source=../wrappers/version.sh
source "$PROJECT_ROOT/wrappers/version.sh"

VERSION_PROBE="$TEST_ROOT/version-probe"
printf 'VERSION="1.2.3"\n' > "$VERSION_PROBE"
[ "$(md_clip_version "$VERSION_PROBE")" = "1.2.3" ]

# Nur die erste Zeile zählt — genauso, wie der Build sie liest.
printf 'VERSION="1.2.3"\nVERSION="9.9.9"\n' > "$VERSION_PROBE"
[ "$(md_clip_version "$VERSION_PROBE")" = "1.2.3" ]

# Nur am Zeilenanfang: In Kommentaren und Meldungen steht das Wort auch.
printf '# VERSION="9.9.9" steht hier nur im Text\nVERSION="1.2.3"\n' > "$VERSION_PROBE"
[ "$(md_clip_version "$VERSION_PROBE")" = "1.2.3" ]

assert_version_unreadable() {
  local label="$1"
  local content="$2"

  printf '%b' "$content" > "$VERSION_PROBE"
  set +e
  version_probe_output="$(md_clip_version "$VERSION_PROBE")"
  version_probe_status=$?
  set -e
  if [ "$version_probe_status" -eq 0 ] || [ -n "$version_probe_output" ]; then
    echo "✗ md_clip_version meldet $label als lesbare Version" >&2
    exit 1
  fi
}

assert_version_unreadable "eine Datei ohne VERSION-Zeile" 'nur Text\n'
assert_version_unreadable "einen leeren Wert" 'VERSION=""\n'

# Die fünf Shell-Einstiegspunkte benutzen die Funktion und haben keine eigene
# Grammatik mehr.
for version_reader in "$PROJECT_ROOT/build.sh" "$PROJECT_ROOT/install-app.sh" \
  "$PROJECT_ROOT/wrappers/build-app-bundled.sh" "$PROJECT_ROOT/wrappers/verify-bundle.sh" \
  "$PROJECT_ROOT/wrappers/sign-and-release.sh"; do
  if ! grep -Fq 'md_clip_version' "$version_reader"; then
    echo "✗ $version_reader liest die Version nicht über md_clip_version" >&2
    exit 1
  fi
  if grep -v '^[[:space:]]*#' "$version_reader" \
    | grep -Eq "(awk -F.\"..|grep )'\\^VERSION="; then
    echo "✗ $version_reader hat eine eigene Versions-Grammatik" >&2
    exit 1
  fi
done

# Der Appcast-Workflow kann die Funktion NICHT sourcen: Sie käme aus der fest
# gepinnten Tooling-Revision, und ein Pin ist älter als jede neu dort angelegte
# Datei. Genau das ließ den Lauf am 2026-09-03 mit „No such file or directory"
# scheitern. Er schreibt die Grammatik deshalb aus — zeichengleich zur Funktion,
# damit beide Seiten nicht auseinanderlaufen.
WORKFLOW_VERSION_READ="awk -F'\"' '/^VERSION=/{print \$2; exit}' release-source/bin/md-clip"
if [ "$(grep -Fc -- "$WORKFLOW_VERSION_READ" "$APPCAST_WORKFLOW")" -ne 2 ]; then
  echo "✗ Der Appcast-Workflow liest die Version nicht zweimal mit der Grammatik von md_clip_version" >&2
  exit 1
fi
grep -Fq "awk -F'\"' '/^VERSION=/{print \$2; exit}'" "$PROJECT_ROOT/wrappers/version.sh"

# Und er darf nur Tooling-Dateien sourcen, die es an der gepinnten Revision
# schon gibt. Eine neue Datei dort verlangt zuerst einen geprüften neuen Pin.
ALLOWED_TOOLING_SOURCE="source tooling/wrappers/verified-cache.sh"
# Nur echte Aufrufe am Zeilenanfang zaehlen; die Begruendung im Workflow nennt
# den gescheiterten Aufruf beim Namen und ist selbst kein Aufruf.
UNEXPECTED_SOURCE=$(grep -nE '^[[:space:]]*source tooling/' "$APPCAST_WORKFLOW" \
  | grep -Fv "$ALLOWED_TOOLING_SOURCE" || true)
if [ -n "$UNEXPECTED_SOURCE" ]; then
  echo "✗ Der Appcast-Workflow sourct Tooling, das die gepinnte Revision nicht sicher enthält:" >&2
  printf '%s\n' "$UNEXPECTED_SOURCE" >&2
  exit 1
fi
echo "✓ Alle sechs Leser der Produktversion benutzen dieselbe Grammatik"

# --- Cache: manipulierte Downloads werden verworfen, gültige atomar gesetzt. ---
# shellcheck source=../wrappers/verified-cache.sh
source "$PROJECT_ROOT/wrappers/verified-cache.sh"
GOOD_SOURCE="$TEST_ROOT/good"
BAD_SOURCE="$TEST_ROOT/bad"
DESTINATION="$TEST_ROOT/cache/artifact"
mkdir -p "$(dirname "$DESTINATION")"
printf 'verifiziert\n' > "$GOOD_SOURCE"
printf 'manipuliert\n' > "$BAD_SOURCE"
# Dieselbe Hilfsfunktion wie das Produkt: sonst prüfte der Test mit einem
# Werkzeug, das auf dem laufenden System gar nicht installiert sein muss.
GOOD_SHA=$(sha256_of "$GOOD_SOURCE")

cat > "$TEST_ROOT/fake-bin/curl" <<'SH'
#!/bin/sh
output=""
while [ "$#" -gt 0 ]; do
  if [ "$1" = "--output" ]; then
    shift
    output="$1"
  fi
  shift
done
cp "$MD_CLIP_FAKE_DOWNLOAD" "$output"
SH
chmod +x "$TEST_ROOT/fake-bin/curl"

printf 'alter Cache\n' > "$DESTINATION"
export MD_CLIP_FAKE_DOWNLOAD="$BAD_SOURCE"
if download_verified 'https://invalid.example/artifact' "$GOOD_SHA" "$DESTINATION" 2>/dev/null; then
  echo "✗ Cache akzeptiert falsche SHA-256" >&2
  exit 1
fi
grep -Fxq 'alter Cache' "$DESTINATION"

export MD_CLIP_FAKE_DOWNLOAD="$GOOD_SOURCE"
download_verified 'https://invalid.example/artifact' "$GOOD_SHA" "$DESTINATION"
cmp "$GOOD_SOURCE" "$DESTINATION"
echo "✓ Download-Cache prüft SHA-256 vor dem atomaren Ersetzen"
