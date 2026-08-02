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
# Das geht nur auf macOS — auf Linux gibt es keinen osascript.
if [ "$(uname -s)" = "Darwin" ] && [ -x /usr/bin/osascript ]; then
  LINK_SCRIPT="$TEST_ROOT/link.applescript"
  sed 's/^do shell script commandText with administrator privileges$/return commandText/' \
    "$TEST_ROOT/capture/source" > "$LINK_SCRIPT"
  grep -Fxq 'return commandText' "$LINK_SCRIPT"

  # Führt den erzeugten Befehl mit den übergebenen Pfaden aus.
  run_link() {
    local command_text
    command_text=$(BUNDLE_CLI="$1" SYSTEM_CLI="$2" /usr/bin/osascript "$LINK_SCRIPT")
    /bin/sh -c "$command_text"
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
else
  echo "⊘ Launcher-Linkschritt übersprungen — osascript gibt es nur auf macOS"
fi

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
