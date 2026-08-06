#!/usr/bin/env bash
# Sicherheitsregressionen für Launcher, Release-Mount und Download-Cache.

set -euo pipefail

TESTS_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
PROJECT_ROOT="$(dirname "$TESTS_DIR")"
TEST_ROOT=$(mktemp -d)
trap 'rm -rf "$TEST_ROOT"' EXIT INT TERM

# --- Launcher: Pfade sind Umgebung, niemals AppleScript-Quelltext. ---
mkdir -p "$TEST_ROOT/fake-bin" "$TEST_ROOT/capture"
cat > "$TEST_ROOT/fake-bin/osascript" <<'SH'
#!/bin/sh
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
grep -Fq 'mktemp -d "$BUILD_DIR/.md-clip-mount.XXXXXX"' "$RELEASE_SCRIPT"
grep -Fq -- '-plist > "$ATTACH_PLIST"' "$RELEASE_SCRIPT"
grep -Fq 'detach_release_mount "$MOUNT_DEVICE"' "$RELEASE_SCRIPT"
grep -Fq 'hdiutil detach "$device"' "$RELEASE_SCRIPT"
if grep -Eq 'hdiutil detach "/Volumes|hdiutil detach "\$MOUNT_DIR"|hdiutil detach .*force' "$RELEASE_SCRIPT"; then
  echo "✗ Release-Skript enthält weiterhin namens- oder mountpointbasiertes Force-Detach" >&2
  exit 1
fi
echo "✓ Release-Skript löst ausschließlich das eigene attach-Device"

# --- Release: das schreibbare Zwischen-Image hängt am Cleanup. ---
# Es ist mehrere hundert MB groß und wurde früher erst im Erfolgsweg gelöscht;
# jeder Abbruch davor ließ es liegen (Review-Fund 2026-08-05). Geprüft wird die
# ganze Kette der Zuständigkeit: erst nach `hdiutil create` übernehmen, im
# Cleanup nur bei ausgehängtem Device löschen, nach der regulären Löschung
# wieder abgeben.
grep -Fxq 'RW_DMG_OWNED=1' "$RELEASE_SCRIPT"
grep -Fq 'if [ -n "$RW_DMG_OWNED" ] && [ -z "$MOUNT_DEVICE" ]; then' "$RELEASE_SCRIPT"
# Die Übernahme muss NACH der Erzeugung stehen, sonst räumt der Cleanup ein
# fremdes Image ab, das dort schon lag.
CREATE_LINE=$(grep -n '^hdiutil create' "$RELEASE_SCRIPT" | head -1 | cut -d: -f1)
OWNED_LINE=$(grep -n '^RW_DMG_OWNED=1$' "$RELEASE_SCRIPT" | head -1 | cut -d: -f1)
if [ -z "$CREATE_LINE" ] || [ -z "$OWNED_LINE" ] || [ "$OWNED_LINE" -lt "$CREATE_LINE" ]; then
  echo "✗ Zuständigkeit für das RW-Image wird nicht nach hdiutil create übernommen" >&2
  exit 1
fi
echo "✓ Release-Skript räumt sein schreibbares Zwischen-Image auch bei Abbruch weg"

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
