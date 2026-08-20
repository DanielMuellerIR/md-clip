#!/usr/bin/env bash
# Sicherheitsregressionen für Launcher, Release, Appcast und Bundle-Prüfung.

set -euo pipefail

TESTS_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=lib/test-helpers.sh
source "$TESTS_DIR/lib/test-helpers.sh"
init_test_environment "$TESTS_DIR"

# Mehrere Prüfungen führen exakt den markierten Funktionsblock aus dem
# Produktionscode mit Attrappen aus. Die Marker müssen eindeutig sein: Bei
# einem fehlenden oder doppelten Marker wäre sonst unbemerkt nur ein Teil des
# tatsächlichen Codes im Test gelandet.
extract_shell_block() {
  local source="$1"
  local marker="$2"
  local destination="$3"
  local strip_workflow_indent="${4:-0}"

  awk \
    -v begin_marker="# BEGIN $marker" \
    -v end_marker="# END $marker" \
    -v strip_indent="$strip_workflow_indent" '
      index($0, begin_marker) { begin_count++; capture=1; next }
      index($0, end_marker) { end_count++; capture=0; next }
      capture {
        if (strip_indent) sub(/^          /, "")
        print
      }
      END {
        if (begin_count != 1 || end_count != 1) exit 65
      }
    ' "$source" > "$destination"
  bash -n "$destination"
}

# --- Launcher: Pfade sind Umgebung, niemals AppleScript-Quelltext. ---
MD_CLIP_HOST_PATH="$PATH"
mkdir -p "$TEST_ROOT/fake-bin" "$TEST_ROOT/capture"
cat > "$TEST_ROOT/fake-bin/osascript" <<'SH'
#!/bin/sh
if [ "${MD_CLIP_OSASCRIPT_FAIL_INSTALL:-0}" = "1" ]; then
  if [ -n "${BUNDLE_CLI:-}" ]; then
    cat > "$MD_CLIP_CAPTURE/source"
    exit 7
  fi
  cat > "$MD_CLIP_CAPTURE/error-source"
  exit 0
fi
printf '%s' "$BUNDLE_CLI" > "$MD_CLIP_CAPTURE/bundle"
printf '%s' "$SYSTEM_CLI" > "$MD_CLIP_CAPTURE/system"
cat > "$MD_CLIP_CAPTURE/source"
SH
chmod +x "$TEST_ROOT/fake-bin/osascript"
export PATH="$TEST_ROOT/fake-bin:/usr/bin:/bin"
export MD_CLIP_CAPTURE="$TEST_ROOT/capture"
export MD_CLIP_LAUNCHER_SOURCE_ONLY=1
# shellcheck source=../wrappers/launcher.sh
source "$PROJECT_ROOT/wrappers/launcher.sh"

BUNDLE_CLI="$TEST_ROOT/O'Neil/$(printf '%s' '$(touch NIE)')/md-clip"
SYSTEM_CLI="$TEST_ROOT/Ziel mit Leerzeichen/md-clip"
install_cli

[ "$(cat "$TEST_ROOT/capture/bundle")" = "$BUNDLE_CLI" ]
[ "$(cat "$TEST_ROOT/capture/system")" = "$SYSTEM_CLI" ]
grep -Fq 'quoted form of bundleCli' "$TEST_ROOT/capture/source"
if grep -Fq "$BUNDLE_CLI" "$TEST_ROOT/capture/source"; then
  echo "✗ Launcher interpoliert Bundle-Pfad in AppleScript-Quelltext" >&2
  exit 1
fi
echo "✓ Launcher übergibt problematische Pfade nur als Daten"

export MD_CLIP_OSASCRIPT_FAIL_INSTALL=1
if install_cli; then
  echo "✗ Launcher meldet eine fehlgeschlagene CLI-Installation als Erfolg" >&2
  exit 1
fi
grep -Fq 'display dialog "Der Kommandozeilen-Befehl konnte nicht' \
  "$TEST_ROOT/capture/error-source"
unset MD_CLIP_OSASCRIPT_FAIL_INSTALL
echo "✓ Launcher zeigt einen Fehler der privilegierten CLI-Installation an"

# --- Launcher: der privilegierte Schritt prüft das Ziel selbst. ---
# decide_cli_action prüft das Ziel VOR dem Passwort-Dialog; in diesem
# Zeitfenster kann dort eine fremde Datei entstehen. Geprüft wird deshalb genau
# der Befehl, den der Launcher an `do shell script` übergibt: Im
# mitgeschnittenen AppleScript wird die Ausführungszeile durch
# `return commandText` ersetzt, dann liefert der echte osascript den Text.
# osascript gibt es nur auf macOS. Die vier Zustandsfälle liefen deshalb früher
# ausschließlich dort — und damit NIE in der Linux-CI, obwohl genau dieser
# Befehl als root läuft (Review-Fund 2026-08-05). Jetzt läuft der funktionale
# Teil überall:
#
#   * Auf macOS liefert der echte osascript den Befehlstext.
#   * Sonst baut ihn `build_link_command` nach.
#
# Damit die Nachbildung nicht still vom AppleScript wegdriftet, wird zuerst der
# Vertrag geprüft: Der Befehlsaufbau im mitgeschnittenen Quelltext MUSS exakt
# der hier festgehaltenen Fassung entsprechen. Wer den Launcher ändert, sieht
# hier rot und muss beide Seiten nachziehen. Auf macOS wird zusätzlich belegt,
# dass Nachbildung und osascript zeichengleich dasselbe liefern.
EXPECTED_COMMAND_STMT='set commandText to "/bin/mkdir -p \"$(/usr/bin/dirname " & target & ")\"" & " && [ ! -e " & target & " ]" & " && { [ ! -L " & target & " ] || /bin/rm " & target & "; }" & " && /bin/ln -s " & quoted form of bundleCli & " " & target'
ACTUAL_COMMAND_STMT=$(
  awk '/^set commandText to /{f=1} /^do shell script /{f=0} f' "$TEST_ROOT/capture/source" \
    | tr '\n' ' ' | sed 's/¬//g' | tr -s ' ' | sed 's/ *$//'
)
if [ "$ACTUAL_COMMAND_STMT" != "$EXPECTED_COMMAND_STMT" ]; then
  echo "✗ Der privilegierte Befehl im Launcher weicht vom geprüften Vertrag ab." >&2
  echo "  Launcher: $ACTUAL_COMMAND_STMT" >&2
  echo "  Erwartet: $EXPECTED_COMMAND_STMT" >&2
  exit 1
fi

# AppleScripts `quoted form of` ist POSIX-Einfachquoting: alles in '…', und ein
# enthaltenes ' wird zu '\''.
sh_quote() {
  printf "'%s'" "$(printf '%s' "$1" | sed "s/'/'\\\\''/g")"
}

build_link_command() {
  local bundle target
  bundle=$(sh_quote "$1")
  target=$(sh_quote "$2")
  printf '%s' "/bin/mkdir -p \"\$(/usr/bin/dirname $target)\" && [ ! -e $target ]"
  printf '%s' " && { [ ! -L $target ] || /bin/rm $target; } && /bin/ln -s $bundle $target"
}

if [ "$(uname -s)" = "Darwin" ] && [ -x /usr/bin/osascript ]; then
  LINK_SCRIPT="$TEST_ROOT/link.applescript"
  sed 's/^do shell script commandText with administrator privileges$/return commandText/' \
    "$TEST_ROOT/capture/source" > "$LINK_SCRIPT"
  grep -Fxq 'return commandText' "$LINK_SCRIPT"

  link_command() {
    BUNDLE_CLI="$1" SYSTEM_CLI="$2" /usr/bin/osascript "$LINK_SCRIPT"
  }

  # Beleg, dass die Nachbildung dem echten AppleScript entspricht — sonst
  # prüfte die Linux-CI etwas anderes als das, was auf dem Mac wirklich läuft.
  probe_real=$(link_command "/tmp/O'Neil/md-clip" "/tmp/Ziel mit Leerzeichen/md-clip")
  probe_built=$(build_link_command "/tmp/O'Neil/md-clip" "/tmp/Ziel mit Leerzeichen/md-clip")
  if [ "$probe_real" != "$probe_built" ]; then
    echo "✗ Nachbildung des Launcher-Befehls weicht von osascript ab" >&2
    echo "  osascript:  $probe_real" >&2
    echo "  nachgebaut: $probe_built" >&2
    exit 1
  fi
  echo "✓ Nachbildung des privilegierten Befehls ist zeichengleich zu osascript"
else
  link_command() {
    build_link_command "$1" "$2"
  }
  echo "✓ Privilegierter Befehl aus dem geprüften Vertrag nachgebaut (kein osascript)"
fi

# Führt den erzeugten Befehl mit den übergebenen Pfaden aus.
run_link() {
  /bin/sh -c "$(link_command "$1" "$2")"
}

LINK_BUNDLE="$TEST_ROOT/bundle/md-clip"
mkdir -p "$(dirname "$LINK_BUNDLE")"
printf 'bundle\n' > "$LINK_BUNDLE"

# Freies Ziel: Symlink wird angelegt.
mkdir -p "$TEST_ROOT/link-frei"
run_link "$LINK_BUNDLE" "$TEST_ROOT/link-frei/md-clip"
[ "$(readlink "$TEST_ROOT/link-frei/md-clip")" = "$LINK_BUNDLE" ]

# Toter Symlink: darf ersetzt werden.
mkdir -p "$TEST_ROOT/link-tot"
ln -s "$TEST_ROOT/link-tot/fehlt" "$TEST_ROOT/link-tot/md-clip"
run_link "$LINK_BUNDLE" "$TEST_ROOT/link-tot/md-clip"
[ "$(readlink "$TEST_ROOT/link-tot/md-clip")" = "$LINK_BUNDLE" ]

# Reguläre Datei: bleibt unangetastet, Befehl scheitert.
mkdir -p "$TEST_ROOT/link-datei"
printf 'fremd\n' > "$TEST_ROOT/link-datei/md-clip"
if run_link "$LINK_BUNDLE" "$TEST_ROOT/link-datei/md-clip" 2>/dev/null; then
  echo "✗ Launcher ersetzt eine fremde Datei im privilegierten Schritt" >&2
  exit 1
fi
grep -Fxq 'fremd' "$TEST_ROOT/link-datei/md-clip"

# Lebender fremder Symlink: bleibt unangetastet, Befehl scheitert.
mkdir -p "$TEST_ROOT/link-fremd"
printf 'fremd\n' > "$TEST_ROOT/link-fremd/anderes"
ln -s "$TEST_ROOT/link-fremd/anderes" "$TEST_ROOT/link-fremd/md-clip"
if run_link "$LINK_BUNDLE" "$TEST_ROOT/link-fremd/md-clip" 2>/dev/null; then
  echo "✗ Launcher ersetzt einen lebenden fremden Symlink" >&2
  exit 1
fi
[ "$(readlink "$TEST_ROOT/link-fremd/md-clip")" = "$TEST_ROOT/link-fremd/anderes" ]

echo "✓ Launcher verlinkt nur auf freies oder totes Ziel, nie mit -f"

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
echo "✓ Installation und Release verwenden dieselbe Notarisierungslogik"

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

# --- Cache: manipulierte Downloads werden verworfen, gültige atomar gesetzt. ---
# shellcheck source=../wrappers/verified-cache.sh
source "$PROJECT_ROOT/wrappers/verified-cache.sh"
GOOD_SOURCE="$TEST_ROOT/good"
BAD_SOURCE="$TEST_ROOT/bad"
DESTINATION="$TEST_ROOT/cache/artifact"
mkdir -p "$(dirname "$DESTINATION")"
printf 'verifiziert\n' > "$GOOD_SOURCE"
printf 'manipuliert\n' > "$BAD_SOURCE"
GOOD_SHA=$(shasum -a 256 "$GOOD_SOURCE" | awk '{print $1}')

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

# --- Launcher: Update-Suche ist entkoppelt und niemals im Weg. ---
# start_update_check stößt den Sparkle-Helfer an (wrappers/launcher.sh).
# Drei Zusicherungen: ohne Helfer passiert nichts, mit Helfer läuft er im
# Hintergrund (--background, Launcher wartet nicht), und die Konvertierung
# kommt immer zuerst — ihr Exit-Status bleibt der des Launchers.
UPDATE_ROOT="$TEST_ROOT/update"
mkdir -p "$UPDATE_ROOT/MacOS" "$UPDATE_ROOT/leer" "$UPDATE_ROOT/capture"
export MD_CLIP_UPDATE_CAPTURE="$UPDATE_ROOT/capture"

# Ohne Updater-Helfer (z.B. Entwicklungs-Build ohne Sparkle): still, Erfolg.
MACOS_DIR="$UPDATE_ROOT/leer"
start_update_check
echo "✓ Launcher bleibt ohne Updater-Helfer still"

# Der Attrappen-Helfer meldet seine Argumente und braucht dann sichtbar Zeit.
# Liegt `done` direkt nach der Rückkehr von start_update_check noch nicht da,
# hat der Launcher nachweislich nicht auf den Helfer gewartet.
cat > "$UPDATE_ROOT/MacOS/md-clip-updater" <<'SH'
#!/bin/sh
printf '%s\n' "$@" > "$MD_CLIP_UPDATE_CAPTURE/args"
sleep 2
printf 'fertig\n' > "$MD_CLIP_UPDATE_CAPTURE/done"
SH
chmod +x "$UPDATE_ROOT/MacOS/md-clip-updater"

MACOS_DIR="$UPDATE_ROOT/MacOS"
start_update_check
if [ -f "$UPDATE_ROOT/capture/done" ]; then
  echo "✗ Launcher wartet auf den Updater-Helfer" >&2
  exit 1
fi
for _ in 1 2 3 4 5 6 7 8 9 10 11 12 13 14 15 16 17 18 19 20 21 22 23 24 25; do
  [ -f "$UPDATE_ROOT/capture/args" ] && break
  sleep 0.2
done
grep -Fxq -- '--background' "$UPDATE_ROOT/capture/args"
echo "✓ Launcher startet den Updater entkoppelt mit --background"

# launcher_main: Konvertierung zuerst, deren Exit-Status bleibt erhalten.
# Die Attrappen-CLI hält fest, ob der Updater zu ihrem Zeitpunkt schon lief
# (dann läge dessen args-Datei bereits vor), und scheitert absichtlich mit 3.
rm -f "$UPDATE_ROOT/capture/args" "$UPDATE_ROOT/capture/done"
cat > "$UPDATE_ROOT/fake-cli" <<'SH'
#!/bin/sh
printf '%s\n' "$@" > "$MD_CLIP_UPDATE_CAPTURE/cli-args"
if [ -e "$MD_CLIP_UPDATE_CAPTURE/args" ]; then
  printf 'updater-lief-schon\n' > "$MD_CLIP_UPDATE_CAPTURE/order"
else
  printf 'cli-zuerst\n' > "$MD_CLIP_UPDATE_CAPTURE/order"
fi
exit 3
SH
chmod +x "$UPDATE_ROOT/fake-cli"

BUNDLE_DIR="$UPDATE_ROOT/nicht-programme"   # nicht in /Applications → move-first-Zweig
BUNDLE_CLI="$UPDATE_ROOT/fake-cli"
set +e
launcher_main
LAUNCHER_STATUS=$?
set -e
[ "$LAUNCHER_STATUS" -eq 3 ] || {
  echo "✗ launcher_main verliert den Exit-Status der CLI (war $LAUNCHER_STATUS)" >&2
  exit 1
}
grep -Fxq -- '--replace' "$UPDATE_ROOT/capture/cli-args"
grep -Fxq 'cli-zuerst' "$UPDATE_ROOT/capture/order"
echo "✓ Launcher konvertiert zuerst und reicht den CLI-Exit-Status durch"

# --- Updater: genau ein eindeutiger Modus. ---
# Der Testmodus schließt AppKit und Sparkle beim Kompilieren aus, führt aber
# denselben Swift-Parser aus wie das Bundle-Programm. Damit sind nicht nur die
# Launcher-Argumente, sondern auch die Ablehnung mehrdeutiger Aufrufe dauerhaft
# repositoryweit geprüft.
UPDATER_MODE_SOURCE="$PROJECT_ROOT/helpers/md-clip-updater.swift"
UPDATER_MODE_BINARY="$TEST_ROOT/md-clip-updater-mode-test"
SWIFTC=$(PATH="$MD_CLIP_HOST_PATH" command -v swiftc || true)
# Der Updater ist ein reiner macOS-Bestandteil (Sparkle, App-Bundle). Auf macOS
# gehört swiftc mit den Xcode-Kommandozeilenwerkzeugen zur Grundausstattung —
# fehlt er dort, ist das ein Fehler. Auf Linux gibt es weder Updater noch
# Swift-Toolchain: dort wird der Block sichtbar übersprungen, statt die in der
# README dokumentierte Testfolge scheitern zu lassen (Review-Fund 2026-08-17).
UPDATER_MODE_SKIPPED=0
if [ -z "$SWIFTC" ]; then
  if [ "$(uname -s)" = "Darwin" ]; then
    echo "✗ Swift-Compiler für den Updater-Modustest fehlt" >&2
    exit 1
  fi
  UPDATER_MODE_SKIPPED=1
  echo "⚠ Updater-Modustest übersprungen: kein swiftc auf $(uname -s)." >&2
  echo "  Der Updater ist macOS-only; sein Argumentvertrag wird dort geprüft." >&2
fi

if [ "$UPDATER_MODE_SKIPPED" -eq 0 ]; then
PATH="$MD_CLIP_HOST_PATH" "$SWIFTC" -D MD_CLIP_UPDATER_MODE_TEST \
  "$UPDATER_MODE_SOURCE" -o "$UPDATER_MODE_BINARY"

[ "$("$UPDATER_MODE_BINARY" --background)" = '--background' ]
[ "$("$UPDATER_MODE_BINARY" --interactive)" = '--interactive' ]

assert_updater_mode_rejected() {
  local label="$1"
  shift
  local stdout="$TEST_ROOT/updater-$label.out"
  local stderr="$TEST_ROOT/updater-$label.err"
  local status

  set +e
  "$UPDATER_MODE_BINARY" "$@" > "$stdout" 2> "$stderr"
  status=$?
  set -e
  if [ "$status" -ne 64 ]; then
    echo "✗ Updater akzeptiert $label oder meldet falschen Exit $status" >&2
    exit 1
  fi
  [ ! -s "$stdout" ]
  grep -Fq 'Aufruf: md-clip-updater --background | --interactive' "$stderr"
}

assert_updater_mode_rejected fehlenden-modus
assert_updater_mode_rejected doppelten-modus --background --background
assert_updater_mode_rejected widersprüchliche-modi --background --interactive
assert_updater_mode_rejected unbekannten-modus --unbekannt
assert_updater_mode_rejected zusätzliches-argument --background --unbekannt
echo "✓ Updater akzeptiert genau einen bekannten Modus"
fi   # Ende des swiftc-Blocks

grep -Fq 'private let maximumDialogLifetime: TimeInterval = 30 * 60' "$UPDATER_MODE_SOURCE"
grep -Fq 'DispatchQueue.main.asyncAfter(' "$UPDATER_MODE_SOURCE"
grep -Fq 'dialogDeadline?.cancel()' "$UPDATER_MODE_SOURCE"
echo "✓ Updater beendet auch einen unbeantworteten Sparkle-Dialog nach 30 Minuten"

# RFC-8032-Testvektor 1 signiert eine leere Datei. Damit prüft derselbe
# CryptoKit-Helfer wie im Appcast-Workflow einen gültigen und einen
# manipulierten Signaturwert, ohne einen privaten Projektschlüssel zu laden.
if [ "$(uname -s)" = "Darwin" ] && [ -n "$SWIFTC" ]; then
  SPARKLE_VERIFIER="$TEST_ROOT/verify-sparkle-signature"
  PATH="$MD_CLIP_HOST_PATH" "$SWIFTC" \
    "$PROJECT_ROOT/helpers/verify-sparkle-signature.swift" \
    -o "$SPARKLE_VERIFIER"
  SPARKLE_PUBLIC_KEY='11qYAYKxCrfVS/7TyWQHOg7hcvPapiMlrwIaaPcHURo='
  SPARKLE_SIGNATURE='5VZDAMNgrHKQhuLMgG6CioSHfx645dl02HPgZSJJAVVfuIIVkKM7rMYeOXAc+bRr0lv18FlbviRlUUFDjnoQCw=='
  SPARKLE_EMPTY_FILE="$TEST_ROOT/sparkle-empty"
  : > "$SPARKLE_EMPTY_FILE"
  "$SPARKLE_VERIFIER" "$SPARKLE_PUBLIC_KEY" "$SPARKLE_SIGNATURE" "$SPARKLE_EMPTY_FILE"
  BAD_SPARKLE_SIGNATURE="4${SPARKLE_SIGNATURE#?}"
  if "$SPARKLE_VERIFIER" "$SPARKLE_PUBLIC_KEY" "$BAD_SPARKLE_SIGNATURE" "$SPARKLE_EMPTY_FILE" \
    >/dev/null 2>&1; then
    echo "✗ Sparkle-Signaturhelfer akzeptiert manipulierte Bytes" >&2
    exit 1
  fi
  echo "✓ Sparkle-Signaturhelfer prüft Ed25519 kryptografisch"
else
  echo "⚠ Sparkle-Signaturtest übersprungen: CryptoKit-Helfer ist macOS-only." >&2
fi

# --- Erfolgsmeldung: HUD-Helfer zuerst, osascript nur als Fallback. ---
# Vertrag in bin/md-clip (Befunde 2026-08-06: osascript-Meldungen laufen
# unter „Skripteditor", und die Erlaubnis-Mechanik des Notification Centers
# verbrennt Bundle-IDs still, sobald eine Anfrage aus einem Automations-
# kontext kam — deshalb ein eigenes Einblend-Fenster ohne Erlaubnis):
# Innerhalb von notify() muss der HUD-Helfer VOR dem osascript-Aufruf
# stehen, ENTKOPPELT starten (&) und direkt zurückkehren, damit weder
# gewartet wird noch etwas in den osascript-Zweig durchfällt.
MD_CLIP_SRC="$PROJECT_ROOT/bin/md-clip"
# `|| true`: Ein Nicht-Treffer soll unten die sprechende Fehlermeldung
# auslösen, nicht das Skript über set -e wortlos beenden.
HUD_CALL_LINE=$(grep -n '"\$hud" "\$1" >/dev/null 2>&1 &' "$MD_CLIP_SRC" | head -1 | cut -d: -f1 || true)
OSASCRIPT_NOTIFY_LINE=$(grep -n "display notification (item 1 of argv)" "$MD_CLIP_SRC" | head -1 | cut -d: -f1 || true)
if [ -z "$HUD_CALL_LINE" ]; then
  echo "✗ notify() startet den HUD-Helfer nicht entkoppelt (md-clip-hud … &)" >&2
  exit 1
fi
if [ -z "$OSASCRIPT_NOTIFY_LINE" ] || [ "$HUD_CALL_LINE" -gt "$OSASCRIPT_NOTIFY_LINE" ]; then
  echo "✗ notify() bevorzugt nicht den HUD-Helfer vor osascript" >&2
  exit 1
fi
NEXT_AFTER_CALL=$(sed -n "$((HUD_CALL_LINE + 1))p" "$MD_CLIP_SRC" | tr -d ' ')
if [ "$NEXT_AFTER_CALL" != "return0" ]; then
  echo "✗ Nach dem HUD-Start fehlt das direkte return — es würde zusätzlich osascript melden" >&2
  exit 1
fi
echo "✓ notify() zeigt das HUD entkoppelt, osascript nur ohne Bundle-Helfer"

# --- Appcast: Tooling und Release-Tag bleiben getrennte Vertrauenszonen. ---
APPCAST_WORKFLOW="$PROJECT_ROOT/.github/workflows/publish-appcast.yml"
APPCAST_REQUEST_WORKFLOW="$PROJECT_ROOT/.github/workflows/request-appcast.yml"
grep -Fq 'workflow_run:' "$APPCAST_WORKFLOW"
grep -Fq "github.ref_name == github.event.repository.default_branch" "$APPCAST_WORKFLOW"
grep -Fq 'release:' "$APPCAST_REQUEST_WORKFLOW"
grep -Fq 'types: [released]' "$APPCAST_REQUEST_WORKFLOW"
grep -Fq 'permissions:' "$APPCAST_REQUEST_WORKFLOW"
grep -Fq 'contents: read' "$APPCAST_REQUEST_WORKFLOW"
if grep -Fq 'types: [published]' "$APPCAST_REQUEST_WORKFLOW" \
   || grep -Fq 'github.event.release.prerelease' "$APPCAST_REQUEST_WORKFLOW"; then
  echo "✗ Release-Dispatcher kann weiterhin bei einem Prerelease erfolgreich laufen" >&2
  exit 1
fi
if grep -Eq 'SPARKLE_PRIVATE_KEY|environment:|pages: write|id-token: write' "$APPCAST_REQUEST_WORKFLOW"; then
  echo "✗ Unprivilegierter Release-Dispatcher besitzt Secret- oder Deployment-Zugriff" >&2
  exit 1
fi
if grep -Fq 'release:' "$APPCAST_WORKFLOW"; then
  echo "✗ Privilegierter Appcast-Workflow wird weiterhin aus dem Release-Tag geladen" >&2
  exit 1
fi
TOOLING_SHA="02d3b1fb48cff7513402f4a721eda0bac525b324"
grep -Fq "ref: $TOOLING_SHA" "$APPCAST_WORKFLOW"
grep -Fq "!= \"$TOOLING_SHA\"" "$APPCAST_WORKFLOW"
if grep -Fq 'TOOLING_REVISION' "$APPCAST_WORKFLOW"; then
  echo "✗ Tooling-SHA bleibt über die Umgebung überschreibbar" >&2
  exit 1
fi
if grep -Fq 'APPCAST_WORK: ${{ runner.temp }}' "$APPCAST_WORKFLOW"; then
  echo "✗ runner.temp steht im jobweiten env und macht den Workflow ungültig" >&2
  exit 1
fi
grep -Fq 'APPCAST_WORK=$RUNNER_TEMP/md-clip-appcast' "$APPCAST_WORKFLOW"
grep -Fq 'path: ${{ runner.temp }}/md-clip-appcast/site' "$APPCAST_WORKFLOW"
if [ "$(grep -Fc -- '-R "$GITHUB_REPOSITORY"' "$APPCAST_WORKFLOW")" -ne 3 ]; then
  echo "✗ Release-Abfragen sind nicht alle explizit an das Repository gebunden" >&2
  exit 1
fi

# Der echte Auswahlblock aus dem Workflow läuft mit einer gh-Attrappe. Nur ein
# strikt validiertes API-Ergebnis darf genau eine Zeile in GITHUB_ENV schreiben;
# manuelle Eingaben sind lediglich eine zu bestätigende Erwartung.
TAG_SELECTOR="$TEST_ROOT/release-tag-selector.sh"
extract_shell_block "$APPCAST_WORKFLOW" RELEASE_TAG_SELECTOR "$TAG_SELECTOR" 1
# shellcheck source=/dev/null
source "$TAG_SELECTOR"

TAG_FAKE_BIN="$TEST_ROOT/tag-fake-bin"
mkdir -p "$TAG_FAKE_BIN"
cat > "$TAG_FAKE_BIN/gh" <<'SH'
#!/bin/sh
printf '%s\n' "$MD_CLIP_FAKE_LATEST_TAG"
SH
chmod +x "$TAG_FAKE_BIN/gh"
PATH="$TAG_FAKE_BIN:$PATH"
export PATH
export GITHUB_REPOSITORY="DanielMuellerIR/md-clip"
export GITHUB_ENV="$TEST_ROOT/github-env"
export MD_CLIP_FAKE_LATEST_TAG="v1.2.2"

: > "$GITHUB_ENV"
GITHUB_EVENT_NAME="workflow_dispatch"
export GITHUB_EVENT_NAME
select_release_tag "v1.2.2"
[ "$(cat "$GITHUB_ENV")" = "RELEASE_TAG=v1.2.2" ]

expect_tag_rejected_without_env() {
  local label="$1"
  local requested_tag="$2"
  : > "$GITHUB_ENV"
  if select_release_tag "$requested_tag" \
    >"$TEST_ROOT/tag-${label}.out" 2>"$TEST_ROOT/tag-${label}.err"; then
    echo "✗ Release-Tag-Auswahl akzeptiert $label" >&2
    exit 1
  fi
  if [ -s "$GITHUB_ENV" ]; then
    echo "✗ Release-Tag-Auswahl schreibt vor der Ablehnung von $label in GITHUB_ENV" >&2
    exit 1
  fi
}

expect_tag_rejected_without_env \
  "Tooling-Newline-Injection" \
  $'v1.2.2\nTOOLING_REVISION=refs/tags/angreifer'
expect_tag_rejected_without_env \
  "Release-Tag-Newline-Injection" \
  $'v1.2.2\nRELEASE_TAG=v9.9.9'
expect_tag_rejected_without_env "ungueltiges Tagformat" "refs/tags/v1.2.2"
expect_tag_rejected_without_env "altes stabiles Tag" "v1.2.1"

GITHUB_EVENT_NAME="workflow_run"
export GITHUB_EVENT_NAME
MD_CLIP_FAKE_LATEST_TAG=$'v1.2.2\nTOOLING_REVISION=refs/tags/angreifer'
export MD_CLIP_FAKE_LATEST_TAG
expect_tag_rejected_without_env "mehrzeiliges API-Tag" ""
MD_CLIP_FAKE_LATEST_TAG="v1.2.2"
export MD_CLIP_FAKE_LATEST_TAG
: > "$GITHUB_ENV"
select_release_tag ""
[ "$(cat "$GITHUB_ENV")" = "RELEASE_TAG=v1.2.2" ]
echo "✓ Release-Tag-Auswahl blockiert Newline-Überschreibungen vor GITHUB_ENV"

workflow_step_line() {
  local name="$1"
  local matches count
  matches=$(grep -nF -- "- name: $name" "$APPCAST_WORKFLOW" || true)
  count=$(printf '%s\n' "$matches" | awk 'NF { count++ } END { print count + 0 }')
  if [ "$count" -ne 1 ]; then
    echo "✗ Appcast-Workflow braucht genau einen Schritt '$name' (gefunden: $count)" >&2
    return 1
  fi
  printf '%s\n' "$matches" | head -1 | cut -d: -f1
}
TOOLING_CHECKOUT_LINE=$(workflow_step_line 'Check out trusted appcast tooling')
RELEASE_CHECKOUT_LINE=$(workflow_step_line 'Check out release data')
SECRET_STEP_LINE=$(workflow_step_line 'Generate and verify signed appcast')
if [ -z "$TOOLING_CHECKOUT_LINE" ] || [ -z "$RELEASE_CHECKOUT_LINE" ] || [ -z "$SECRET_STEP_LINE" ] \
   || [ "$TOOLING_CHECKOUT_LINE" -ge "$RELEASE_CHECKOUT_LINE" ] \
   || [ "$RELEASE_CHECKOUT_LINE" -ge "$SECRET_STEP_LINE" ]; then
  echo "✗ Appcast-Workflow trennt Tooling, Release-Daten und Secret nicht in dieser Reihenfolge" >&2
  exit 1
fi

FETCH_BLOCK=$(sed -n '/- name: Fetch pinned Sparkle tool without secret/,/- name: Generate and verify signed appcast/p' "$APPCAST_WORKFLOW")
grep -Fq 'tooling/wrappers/build-app-bundled.sh' <<<"$FETCH_BLOCK"
grep -Fq 'source tooling/wrappers/verified-cache.sh' <<<"$FETCH_BLOCK"
grep -Fq 'swiftc tooling/helpers/verify-sparkle-signature.swift' <<<"$FETCH_BLOCK"
if grep -Eq 'release-source/(wrappers|\.github)|source release-source' <<<"$FETCH_BLOCK"; then
  echo "✗ Appcast-Tooling stammt weiterhin aus dem Release-Tag" >&2
  exit 1
fi

SIGNING_BLOCK=$(sed -n '/- name: Generate and verify signed appcast/,/- name: Upload Pages artifact/p' "$APPCAST_WORKFLOW")
grep -Fq '"$APPCAST_WORK/sparkle-dist/bin/generate_appcast"' <<<"$SIGNING_BLOCK"
if grep -Fq 'release-source/wrappers' <<<"$SIGNING_BLOCK"; then
  echo "✗ Signierschritt führt ein Werkzeug aus dem Release-Tag aus" >&2
  exit 1
fi
echo "✓ Appcast-Tooling kommt fest gepinnt aus einer vom Release-Tag getrennten Revision"

# Der echte Generator-Runner muss stdout und stderr vollständig abwarten. Eine
# Sparkle-Warnung darf auch dann nicht entkommen, wenn sie verspätet auf stdout
# erscheint und der Generator selbst mit Erfolg endet.
APPCAST_GENERATOR_RUNNER="$TEST_ROOT/appcast-generator-runner.sh"
extract_shell_block "$APPCAST_WORKFLOW" APPCAST_GENERATOR_RUNNER "$APPCAST_GENERATOR_RUNNER" 1
# shellcheck source=/dev/null
source "$APPCAST_GENERATOR_RUNNER"
sparkle_private_key="synthetic-test-key"
cat > "$TEST_ROOT/generator-warning" <<'SH'
#!/bin/sh
cat >/dev/null
sleep 0.1
echo 'does not match key EdDSA'
exit 0
SH
cat > "$TEST_ROOT/generator-ok" <<'SH'
#!/bin/sh
cat >/dev/null
echo 'generated'
SH
chmod +x "$TEST_ROOT/generator-warning" "$TEST_ROOT/generator-ok"
if run_appcast_generator "$TEST_ROOT/generator-warning" >/dev/null 2>&1; then
  echo "✗ Generator-Runner übersieht eine verzögerte Schlüsselwarnung auf stdout" >&2
  exit 1
fi
run_appcast_generator "$TEST_ROOT/generator-ok" >/dev/null 2>&1
echo "✓ Appcast wartet auf stdout und stderr des Generators und prüft beide"

# Die folgende Funktion ist der echte Validator aus dem Workflow. Wir ziehen
# genau diesen Block heraus und testen ihn mit einer xmllint-Attrappe; weder
# GitHub noch ein DMG oder ein Sparkle-Schlüssel werden dabei berührt.
APPCAST_VALIDATOR="$TEST_ROOT/appcast-validator.sh"
extract_shell_block "$APPCAST_WORKFLOW" APPCAST_METADATA_VALIDATOR "$APPCAST_VALIDATOR" 1
# shellcheck source=/dev/null
source "$APPCAST_VALIDATOR"

# Echte Sparkle-Appcasts tragen beide Versionswerte als Kindelemente des
# Items, nicht als Attribute des Enclosures. Der reale xmllint-Lauf verhindert,
# dass die Attrappen unten einen falschen XPath versehentlich grün machen. Auf
# Linux ist xmllint nicht Teil des CI-Images; dort bleibt die exakte
# Strukturprüfung des extrahierten Produktionscodes verbindlich.
grep -Fq 'local version_xpath="${item_xpath}/*[local-name()=\"version\"]"' "$APPCAST_VALIDATOR"
grep -Fq 'local short_version_xpath="${item_xpath}/*[local-name()=\"shortVersionString\"]"' "$APPCAST_VALIDATOR"
if command -v xmllint >/dev/null 2>&1; then
  APPCAST_REAL="$TEST_ROOT/appcast-real.xml"
  cat > "$APPCAST_REAL" <<'XML'
<rss xmlns:sparkle="http://www.andymatuschak.org/xml-namespaces/sparkle" version="2.0">
  <channel>
    <item>
      <sparkle:version>1.2.2</sparkle:version>
      <sparkle:shortVersionString>1.2.2</sparkle:shortVersionString>
      <enclosure url="https://github.com/DanielMuellerIR/md-clip/releases/download/v1.2.2/md-clip-1.2.2.dmg" sparkle:edSignature="synthetic-signature"/>
    </item>
  </channel>
</rss>
XML
  validate_appcast \
    "$APPCAST_REAL" \
    1.2.2 \
    1.2.2 \
    "https://github.com/DanielMuellerIR/md-clip/releases/download/v1.2.2/md-clip-1.2.2.dmg"
else
  echo "⚠ Reale Appcast-XPath-Prüfung übersprungen: xmllint fehlt auf $(uname -s)." >&2
fi

APPCAST_FAKE_BIN="$TEST_ROOT/appcast-fake-bin"
mkdir -p "$APPCAST_FAKE_BIN"
cat > "$APPCAST_FAKE_BIN/xmllint" <<'SH'
#!/bin/sh
if [ "$1" = "--noout" ]; then
  [ "${MD_CLIP_XML_VALID:-1}" = "1" ]
  exit
fi
expression="$2"
case "$expression" in
  'count('*'local-name()="item"'*'local-name()="enclosure"'*) printf '%s' "$MD_CLIP_XML_ENCLOSURES" ;;
  'count('*'local-name()="item"'*) printf '%s' "$MD_CLIP_XML_ITEMS" ;;
  *'local-name()="edSignature"'*) printf '%s' "$MD_CLIP_XML_SIGNATURE" ;;
  *'local-name()="shortVersionString"'*) printf '%s' "$MD_CLIP_XML_SHORT_VERSION" ;;
  *'local-name()="version"'*) printf '%s' "$MD_CLIP_XML_VERSION" ;;
  *'/@url)'*) printf '%s' "$MD_CLIP_XML_URL" ;;
  *) echo "unbekannter XPath: $expression" >&2; exit 64 ;;
esac
SH
chmod +x "$APPCAST_FAKE_BIN/xmllint"
PATH="$APPCAST_FAKE_BIN:$PATH"
export PATH

APPCAST_DUMMY="$TEST_ROOT/appcast.xml"
EXPECTED_APPCAST_URL="https://github.com/DanielMuellerIR/md-clip/releases/download/v1.2.2/md-clip-1.2.2.dmg"
: > "$APPCAST_DUMMY"
export MD_CLIP_XML_VALID=1
export MD_CLIP_XML_ITEMS=1
export MD_CLIP_XML_ENCLOSURES=1
export MD_CLIP_XML_VERSION=1.2.2
export MD_CLIP_XML_SHORT_VERSION=1.2.2
export MD_CLIP_XML_URL="$EXPECTED_APPCAST_URL"
export MD_CLIP_XML_SIGNATURE="synthetic-signature"
validate_appcast "$APPCAST_DUMMY" 1.2.2 1.2.2 "$EXPECTED_APPCAST_URL"

expect_appcast_rejected() {
  local label="$1"
  if validate_appcast "$APPCAST_DUMMY" 1.2.2 1.2.2 "$EXPECTED_APPCAST_URL" \
    >"$TEST_ROOT/appcast-${label}.out" 2>"$TEST_ROOT/appcast-${label}.err"; then
    echo "✗ Appcast-Validator akzeptiert $label" >&2
    exit 1
  fi
}

MD_CLIP_XML_ITEMS=2
expect_appcast_rejected "mehrere Einträge"
MD_CLIP_XML_ITEMS=1
MD_CLIP_XML_ENCLOSURES=2
expect_appcast_rejected "mehrere Enclosures"
MD_CLIP_XML_ENCLOSURES=1
MD_CLIP_XML_VERSION=1.2.1
expect_appcast_rejected "falsche Build-Version"
MD_CLIP_XML_VERSION=1.2.2
MD_CLIP_XML_SHORT_VERSION=1.2.1
expect_appcast_rejected "falsche Kurzversion"
MD_CLIP_XML_SHORT_VERSION=1.2.2
MD_CLIP_XML_URL="https://invalid.example/md-clip-1.2.2.dmg"
expect_appcast_rejected "falsche Enclosure-URL"
MD_CLIP_XML_URL="$EXPECTED_APPCAST_URL"
MD_CLIP_XML_SIGNATURE=""
expect_appcast_rejected "fehlende EdDSA-Signatur"
MD_CLIP_XML_SIGNATURE="synthetic-signature"
echo "✓ Appcast verlangt genau einen passenden, signierten Release-Eintrag"

grep -Fq "does not match key EdDSA" <<<"$SIGNING_BLOCK"
grep -Fq "SPARKLE_PRIVATE_KEY passt nicht zum öffentlichen Schlüssel" <<<"$SIGNING_BLOCK"
grep -Fq -- "-c 'Print :SUPublicEDKey'" <<<"$SIGNING_BLOCK"
grep -Fq '"$APPCAST_WORK/verify-sparkle-signature"' <<<"$SIGNING_BLOCK"
grep -Fq '"$public_key" "$feed_signature" "${dmgs[0]}"' <<<"$SIGNING_BLOCK"
echo "✓ Appcast prüft die Signatur gegen den Schlüssel im Release-Bundle"

# --- Bundle: Apple-Kette, Team-ID und Bundle-ID vor Produktcode. ---
TRUST_HELPER="$PROJECT_ROOT/wrappers/verify-bundle-trust.sh"
VERIFY_BUNDLE="$PROJECT_ROOT/wrappers/verify-bundle.sh"
TRUST_TEST_ROOT="$TEST_ROOT/bundle-trust"
mkdir -p "$TRUST_TEST_ROOT/App.app/Contents" "$TRUST_TEST_ROOT/fake-bin"
: > "$TRUST_TEST_ROOT/App.app/Contents/Info.plist"

cat > "$TRUST_TEST_ROOT/fake-bin/PlistBuddy" <<'SH'
#!/bin/sh
printf '%s\n' "$MD_CLIP_FAKE_BUNDLE_ID"
SH
cat > "$TRUST_TEST_ROOT/fake-bin/codesign" <<'SH'
#!/bin/sh
if [ "$1" = "--verify" ]; then
  printf '%s\n' "$@" > "$MD_CLIP_CODESIGN_CAPTURE"
  test_requirement=""
  while [ "$#" -gt 0 ]; do
    case "$1" in
      --test-requirement|-R)
        shift
        test_requirement="${1:-}"
        ;;
    esac
    shift
  done
  # Ohne den wertenden Schalter muss schon der Positivtest rot werden. Das
  # haette den wirkungslosen alten Aufruf mit --requirements erkannt.
  [ -n "$test_requirement" ] || exit 64
  required_identifier="identifier \"$MD_CLIP_FAKE_SIGNED_BUNDLE_ID\""
  required_team="certificate leaf[subject.OU] = \"$MD_CLIP_FAKE_TEAM_ID\""
  case "$test_requirement" in
    =*"$required_identifier"*"$required_team"*) exit 0 ;;
    *) exit 3 ;;
  esac
fi
printf 'details\n' >> "$MD_CLIP_CODESIGN_DETAIL_CAPTURE"
cat <<EOF
Executable=$1
Identifier=$MD_CLIP_FAKE_SIGNED_BUNDLE_ID
Format=app bundle with Mach-O thin
CodeDirectory v=20500 size=1 flags=0x10000(runtime)
Authority=Developer ID Application: Test ($MD_CLIP_FAKE_TEAM_ID)
TeamIdentifier=$MD_CLIP_FAKE_TEAM_ID
Timestamp=2026-08-10 00:00:00 +0000
EOF
SH
chmod +x "$TRUST_TEST_ROOT/fake-bin/"*

export MD_CLIP_CODESIGN_CAPTURE="$TRUST_TEST_ROOT/codesign-verify.args"
export MD_CLIP_CODESIGN_DETAIL_CAPTURE="$TRUST_TEST_ROOT/codesign-details.calls"
export MD_CLIP_FAKE_BUNDLE_ID="io.github.danielmuellerir.md-clip"
export MD_CLIP_FAKE_SIGNED_BUNDLE_ID="io.github.danielmuellerir.md-clip"
export MD_CLIP_FAKE_TEAM_ID="9QSWKSR4NQ"
# shellcheck source=../wrappers/verify-bundle-trust.sh
source "$TRUST_HELPER"
verify_signed_bundle_trust \
  "$TRUST_TEST_ROOT/App.app" \
  "$TRUST_TEST_ROOT/fake-bin/PlistBuddy" \
  "$TRUST_TEST_ROOT/fake-bin/codesign"
grep -Fxq -- '--test-requirement' "$MD_CLIP_CODESIGN_CAPTURE"
grep -Fxq '=anchor apple generic and identifier "io.github.danielmuellerir.md-clip" and certificate leaf[subject.OU] = "9QSWKSR4NQ" and certificate leaf[field.1.2.840.113635.100.6.1.13] exists and certificate 1[field.1.2.840.113635.100.6.2.6] exists' "$MD_CLIP_CODESIGN_CAPTURE"
if grep -Fxq -- '--requirements' "$MD_CLIP_CODESIGN_CAPTURE"; then
  echo "✗ Bundle-Vertrauen verwendet den wirkungslosen codesign-Schalter --requirements" >&2
  exit 1
fi

# Plist-ID ist korrekt, die simulierte Signatur trägt aber eine fremde ID:
# Die Requirement-Prüfung selbst muss mit Exit 3 abbrechen, bevor `codesign -d`
# als nachträglicher Texttest läuft.
: > "$MD_CLIP_CODESIGN_DETAIL_CAPTURE"
MD_CLIP_FAKE_SIGNED_BUNDLE_ID="invalid.example.fremd-signiert"
if verify_signed_bundle_trust \
  "$TRUST_TEST_ROOT/App.app" \
  "$TRUST_TEST_ROOT/fake-bin/PlistBuddy" \
  "$TRUST_TEST_ROOT/fake-bin/codesign" >/dev/null 2>&1; then
  echo "✗ Bundle-Requirement akzeptiert eine fremde signierte Kennung" >&2
  exit 1
fi
[ ! -s "$MD_CLIP_CODESIGN_DETAIL_CAPTURE" ]
echo "✓ Bundle-Requirement lehnt eine fremde signierte Kennung direkt ab"
MD_CLIP_FAKE_SIGNED_BUNDLE_ID="io.github.danielmuellerir.md-clip"

rm -f "$MD_CLIP_CODESIGN_CAPTURE"
MD_CLIP_FAKE_BUNDLE_ID="invalid.example.fremd"
if verify_signed_bundle_trust \
  "$TRUST_TEST_ROOT/App.app" \
  "$TRUST_TEST_ROOT/fake-bin/PlistBuddy" \
  "$TRUST_TEST_ROOT/fake-bin/codesign" >/dev/null 2>&1; then
  echo "✗ Bundle-Vertrauen akzeptiert eine fremde Bundle-ID" >&2
  exit 1
fi
[ ! -e "$MD_CLIP_CODESIGN_CAPTURE" ]

MD_CLIP_FAKE_BUNDLE_ID="io.github.danielmuellerir.md-clip"
MD_CLIP_FAKE_TEAM_ID="ANDERETEAM"
if verify_signed_bundle_trust \
  "$TRUST_TEST_ROOT/App.app" \
  "$TRUST_TEST_ROOT/fake-bin/PlistBuddy" \
  "$TRUST_TEST_ROOT/fake-bin/codesign" >/dev/null 2>&1; then
  echo "✗ Bundle-Vertrauen akzeptiert eine fremde Team-ID" >&2
  exit 1
fi

# Ein bewusst gesetztes APPLE_TEAM_ID muss bis in denselben Vertrauensanker
# gelangen. Sonst signiert der Release-Weg mit einer ID und prüft heimlich eine
# andere, fest eingebaute ID.
MD_CLIP_FAKE_TEAM_ID="TEAMID1234"
verify_signed_bundle_trust \
  "$TRUST_TEST_ROOT/App.app" \
  "$TRUST_TEST_ROOT/fake-bin/PlistBuddy" \
  "$TRUST_TEST_ROOT/fake-bin/codesign" \
  "TEAMID1234"
grep -Fq 'certificate leaf[subject.OU] = "TEAMID1234"' "$MD_CLIP_CODESIGN_CAPTURE"
grep -Fq -- '--team-id "$TEAM_ID"' "$PROJECT_ROOT/install-app.sh"
grep -Fq -- '--team-id "$TEAM_ID"' "$PROJECT_ROOT/wrappers/sign-and-release.sh"

TRUST_CALL_LINE=$(grep -n 'verify_signed_bundle_trust "\$APP"' "$VERIFY_BUNDLE" | cut -d: -f1)
PRODUCT_EXEC_LINE=$(grep -n 'CLI_OUTPUT="\$("\$BUNDLED_CLI" --version)"' "$VERIFY_BUNDLE" | cut -d: -f1)
if [ -z "$TRUST_CALL_LINE" ] || [ -z "$PRODUCT_EXEC_LINE" ] \
   || [ "$TRUST_CALL_LINE" -ge "$PRODUCT_EXEC_LINE" ]; then
  echo "✗ Bundle-Vertrauen steht nicht vor der Produktausführung" >&2
  exit 1
fi
echo "✓ Bundle wird vor Produktcode an Apple-Kette, Team-ID und Bundle-ID gebunden"

# Auch ein toter XPC-Symlink ist unerlaubter Bundle-Inhalt. `-e` allein folgt
# dem Ziel und würde ihn übersehen; der minimale Bundle-Aufbau muss bereits an
# der Strukturprüfung scheitern, bevor otool oder Produktcode laufen.
XPC_TEST_APP="$TEST_ROOT/dead-xpc/md-clip.app"
mkdir -p \
  "$XPC_TEST_APP/Contents/MacOS" \
  "$XPC_TEST_APP/Contents/Resources/bin" \
  "$XPC_TEST_APP/Contents/Resources/Licenses" \
  "$XPC_TEST_APP/Contents/Frameworks/Sparkle.framework/Versions/B/Updater.app"
: > "$XPC_TEST_APP/Contents/Info.plist"
for executable in \
  "$XPC_TEST_APP/Contents/MacOS/md-clip" \
  "$XPC_TEST_APP/Contents/MacOS/md-clip-updater" \
  "$XPC_TEST_APP/Contents/MacOS/md-clip-hud" \
  "$XPC_TEST_APP/Contents/Resources/bin/md-clip" \
  "$XPC_TEST_APP/Contents/Resources/bin/pipeline.sh" \
  "$XPC_TEST_APP/Contents/Resources/bin/pandoc" \
  "$XPC_TEST_APP/Contents/Resources/bin/clipboard-html" \
  "$XPC_TEST_APP/Contents/Resources/bin/clipboard-rtf" \
  "$XPC_TEST_APP/Contents/Frameworks/Sparkle.framework/Versions/B/Autoupdate"; do
  : > "$executable"
  chmod +x "$executable"
done
for license in pandoc-COPYRIGHT.txt Sparkle-LICENSE.txt README.txt; do
  printf 'Lizenz\n' > "$XPC_TEST_APP/Contents/Resources/Licenses/$license"
done
ln -s "$TEST_ROOT/nicht-vorhanden" \
  "$XPC_TEST_APP/Contents/Frameworks/Sparkle.framework/Versions/B/XPCServices"
if bash "$VERIFY_BUNDLE" "$XPC_TEST_APP" \
  >"$TEST_ROOT/dead-xpc.out" 2>"$TEST_ROOT/dead-xpc.err"; then
  echo "✗ Bundle-Prüfer akzeptiert einen toten XPCServices-Symlink" >&2
  exit 1
fi
grep -Fq 'Sparkles XPC-Dienste sind noch im Bundle' "$TEST_ROOT/dead-xpc.err"

grep -Fq 'verify_distribution_signature "$APP/Contents/Resources/bin/clipboard-html" "HTML-Helfer"' "$VERIFY_BUNDLE"
grep -Fq 'verify_distribution_signature "$APP/Contents/Resources/bin/clipboard-rtf" "RTF-Helfer"' "$VERIFY_BUNDLE"
echo "✓ Bundle-Prüfer erfasst tote XPC-Symlinks und beide Clipboard-Helfer"

# --- Bundle: Info.plist darf keine ältere Kompatibilität versprechen als Code. ---
# Der echte Prüfer liest sowohl LC_BUILD_VERSION/minos als auch die ältere
# LC_VERSION_MIN_MACOSX/version-Form aus vtool. Der isolierte Test führt den
# vollständigen markierten Produktionsblock aus und zeichnet jedes Ziel auf;
# dadurch fällt auch ein künftig aus der Schleife entferntes Binary auf.
APP="$TRUST_TEST_ROOT/compatibility/md-clip.app"
UPDATER="$APP/Contents/MacOS/md-clip-updater"
SPARKLE_FRAMEWORK="$APP/Contents/Frameworks/Sparkle.framework"
MINIMUM_SYSTEM_VERSION=14.0
MD_CLIP_VTOOL_CAPTURE="$TRUST_TEST_ROOT/vtool-targets"
MD_CLIP_FAKE_MINOS=14.0
export MD_CLIP_VTOOL_CAPTURE MD_CLIP_FAKE_MINOS

cat > "$TRUST_TEST_ROOT/fake-bin/vtool" <<'SH'
#!/bin/sh
printf '%s\n' "${2:-}" >> "$MD_CLIP_VTOOL_CAPTURE"
case "${MD_CLIP_FAKE_VTOOL_STYLE:-modern}" in
  modern)
    printf '      cmd LC_BUILD_VERSION\n    minos %s\n' "$MD_CLIP_FAKE_MINOS"
    ;;
  legacy)
    printf '      cmd LC_VERSION_MIN_MACOSX\n  version %s\n' "$MD_CLIP_FAKE_MINOS"
    ;;
  missing)
    printf 'kein Load Command\n'
    ;;
esac
SH
chmod +x "$TRUST_TEST_ROOT/fake-bin/vtool"
PATH="$TRUST_TEST_ROOT/fake-bin:$PATH"
export PATH

COMPATIBILITY_CHECK="$TEST_ROOT/macos-compatibility-check.sh"
extract_shell_block "$VERIFY_BUNDLE" MACOS_COMPATIBILITY_CHECK "$COMPATIBILITY_CHECK"
# shellcheck source=/dev/null
source "$COMPATIBILITY_CHECK"

EXPECTED_VTOOL_TARGETS="$TRUST_TEST_ROOT/expected-vtool-targets"
printf '%s\n' \
  "$UPDATER" \
  "$APP/Contents/MacOS/md-clip-hud" \
  "$APP/Contents/Resources/bin/clipboard-html" \
  "$APP/Contents/Resources/bin/clipboard-rtf" \
  "$APP/Contents/Resources/bin/pandoc" \
  "$SPARKLE_FRAMEWORK/Versions/B/Sparkle" \
  "$SPARKLE_FRAMEWORK/Versions/B/Autoupdate" \
  "$SPARKLE_FRAMEWORK/Versions/B/Updater.app/Contents/MacOS/Updater" \
  > "$EXPECTED_VTOOL_TARGETS"
if ! cmp -s "$EXPECTED_VTOOL_TARGETS" "$MD_CLIP_VTOOL_CAPTURE"; then
  echo "✗ Bundle-Kompatibilitätsprüfung erreicht nicht alle Mach-O-Ziele" >&2
  diff "$EXPECTED_VTOOL_TARGETS" "$MD_CLIP_VTOOL_CAPTURE" >&2 || true
  exit 1
fi

MD_CLIP_FAKE_VTOOL_STYLE=modern MD_CLIP_FAKE_MINOS=14.0 \
  verify_macos_compatibility 14.0 "Test-Binary" "$TRUST_TEST_ROOT/dummy"
MD_CLIP_FAKE_VTOOL_STYLE=legacy MD_CLIP_FAKE_MINOS=10.13 \
  verify_macos_compatibility 14.0 "Test-Binary" "$TRUST_TEST_ROOT/dummy"
if MD_CLIP_FAKE_VTOOL_STYLE=modern MD_CLIP_FAKE_MINOS=14.1 \
  verify_macos_compatibility 14.0 "Test-Binary" "$TRUST_TEST_ROOT/dummy" >/dev/null 2>&1; then
  echo "✗ Bundle-Prüfer akzeptiert ein Binary oberhalb von LSMinimumSystemVersion" >&2
  exit 1
fi
if MD_CLIP_FAKE_VTOOL_STYLE=missing MD_CLIP_FAKE_MINOS=14.0 \
  verify_macos_compatibility 14.0 "Test-Binary" "$TRUST_TEST_ROOT/dummy" >/dev/null 2>&1; then
  echo "✗ Bundle-Prüfer akzeptiert ein Binary ohne lesbare Mindestversion" >&2
  exit 1
fi
echo "✓ Bundle-Kompatibilität deckt Info.plist und alle Mach-O-Ziele"

# --- Lokaler Build: nur die gerade gebaute, bytegleiche CLI ausführen. ---
BUILD_SCRIPT="$PROJECT_ROOT/build.sh"
BUILD_CLI_SMOKE="$TEST_ROOT/build-cli-smoke.sh"
extract_shell_block "$BUILD_SCRIPT" TRUSTED_BUILD_CLI_SMOKE "$BUILD_CLI_SMOKE"
# shellcheck source=/dev/null
source "$BUILD_CLI_SMOKE"

SMOKE_SOURCE="$TEST_ROOT/smoke-source"
SMOKE_BUNDLE="$TEST_ROOT/smoke-bundle"
printf '%s\n' '#!/bin/sh' 'echo "md-clip 1.2.4"' > "$SMOKE_SOURCE"
cp "$SMOKE_SOURCE" "$SMOKE_BUNDLE"
chmod +x "$SMOKE_SOURCE" "$SMOKE_BUNDLE"
verify_trusted_build_cli "$SMOKE_SOURCE" "$SMOKE_BUNDLE" 1.2.4

SMOKE_EXECUTED="$TEST_ROOT/smoke-executed"
export SMOKE_EXECUTED
printf '%s\n' '#!/bin/sh' 'printf ausgeführt > "$SMOKE_EXECUTED"' 'echo "fremd"' > "$SMOKE_BUNDLE"
if verify_trusted_build_cli "$SMOKE_SOURCE" "$SMOKE_BUNDLE" 1.2.4 >/dev/null 2>&1; then
  echo "✗ Build-Smoke-Test führt eine nicht zur Quelle passende CLI aus" >&2
  exit 1
fi
[ ! -e "$SMOKE_EXECUTED" ]

printf '%s\n' '#!/bin/sh' 'if then' > "$SMOKE_SOURCE"
cp "$SMOKE_SOURCE" "$SMOKE_BUNDLE"
chmod +x "$SMOKE_SOURCE" "$SMOKE_BUNDLE"
if verify_trusted_build_cli "$SMOKE_SOURCE" "$SMOKE_BUNDLE" 1.2.4 >/dev/null 2>&1; then
  echo "✗ Build-Smoke-Test akzeptiert einen Syntaxfehler" >&2
  exit 1
fi

printf '%s\n' '#!/bin/sh' 'exit 7' > "$SMOKE_SOURCE"
cp "$SMOKE_SOURCE" "$SMOKE_BUNDLE"
chmod +x "$SMOKE_SOURCE" "$SMOKE_BUNDLE"
if verify_trusted_build_cli "$SMOKE_SOURCE" "$SMOKE_BUNDLE" 1.2.4 >/dev/null 2>&1; then
  echo "✗ Build-Smoke-Test übersieht eine nicht ausführbare CLI" >&2
  exit 1
fi
echo "✓ Lokaler Build bindet die CLI an die Quelle und führt --version aus"
