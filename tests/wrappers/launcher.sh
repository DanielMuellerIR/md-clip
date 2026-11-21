#!/usr/bin/env bash
# Vom Wrapper-Testrunner im isolierten Testverzeichnis geladen.
TEST_SCRIPT="${BASH_SOURCE[0]}"
# --- Launcher: Pfade sind Argumente, niemals AppleScript-Quelltext. ---
MD_CLIP_HOST_PATH="$PATH"
mkdir -p "$TEST_ROOT/fake-bin" "$TEST_ROOT/capture"
cat > "$TEST_ROOT/fake-bin/osascript" <<'SH'
#!/bin/sh
script=$(cat)
case "$script" in
  *'with administrator privileges'*)
    [ "$1" = - ] && [ "$#" -eq 3 ] || exit 90
    printf '%s' "$2" > "$MD_CLIP_CAPTURE/bundle"
    printf '%s' "$3" > "$MD_CLIP_CAPTURE/system"
    printf '%s\n' "$script" > "$MD_CLIP_CAPTURE/source"
    if [ "${MD_CLIP_OSASCRIPT_FAIL_INSTALL:-0}" = 1 ]; then exit 7; fi ;;
  *'set bundlePath to item 1 of arguments'*)
    [ "$1" = - ] && [ "$#" -eq 2 ] || exit 90
    printf '%s' "$2" > "$MD_CLIP_CAPTURE/move-path"
    printf '%s\n' "$script" > "$MD_CLIP_CAPTURE/move-source" ;;
  *)
    [ "$1" = - ] && [ "$#" -eq 3 ] || exit 90
    printf '%s' "$2" > "$MD_CLIP_CAPTURE/error-text"
    printf '%s\n' "$script" > "$MD_CLIP_CAPTURE/error-source" ;;
esac
SH
chmod +x "$TEST_ROOT/fake-bin/osascript"
export PATH="$TEST_ROOT/fake-bin:/usr/bin:/bin"
export MD_CLIP_CAPTURE="$TEST_ROOT/capture"
export MD_CLIP_LAUNCHER_SOURCE_ONLY=1
# shellcheck source=../wrappers/launcher.sh
source "$PROJECT_ROOT/wrappers/launcher.sh"

BUNDLE_CLI="$TEST_ROOT/Müller's/$(printf '%s' '$(touch NIE)')/md-clip"
SYSTEM_CLI="$TEST_ROOT/Ziel mit Leerzeichen und Ö/md-clip"
install_cli

[ "$(cat "$TEST_ROOT/capture/bundle")" = "$BUNDLE_CLI" ]
[ "$(cat "$TEST_ROOT/capture/system")" = "$SYSTEM_CLI" ]
grep -Fq 'quoted form of bundleCli' "$TEST_ROOT/capture/source"
if grep -Fq "$BUNDLE_CLI" "$TEST_ROOT/capture/source"; then
  echo "✗ Launcher interpoliert Bundle-Pfad in AppleScript-Quelltext" >&2
  exit 1
fi
BUNDLE_DIR="$TEST_ROOT/Müller's App.app"
ask_move_first
[ "$(cat "$TEST_ROOT/capture/move-path")" = "$BUNDLE_DIR" ]
! grep -Fq "$BUNDLE_DIR" "$TEST_ROOT/capture/move-source"
echo "✓ Launcher übergibt problematische Pfade nur als Daten"

export MD_CLIP_OSASCRIPT_FAIL_INSTALL=1
if install_cli; then
  echo "✗ Launcher meldet eine fehlgeschlagene CLI-Installation als Erfolg" >&2
  exit 1
fi
grep -Fq 'Der Kommandozeilen-Befehl konnte nicht' "$TEST_ROOT/capture/error-text"
# Wie beim privilegierten Befehl gilt auch hier: Der Text darf nur als Daten
# ankommen. Stünde er im AppleScript-Quelltext, könnte ein Anführungszeichen
# darin den Parser verlassen.
grep -Fq 'set dialogText to item 1 of arguments' "$TEST_ROOT/capture/error-source"
if grep -Fq 'Der Kommandozeilen-Befehl konnte nicht' "$TEST_ROOT/capture/error-source"; then
  echo "✗ Launcher interpoliert den Meldungstext in AppleScript-Quelltext" >&2
  exit 1
fi
unset MD_CLIP_OSASCRIPT_FAIL_INSTALL
echo "✓ Launcher zeigt einen Fehler der privilegierten CLI-Installation an"

# --- Launcher: der privilegierte Schritt prüft das Ziel selbst. ---
# Der Zielzustand kann sich während des Passwortdialogs ändern. Auf macOS
# führt der echte AppleScript-Parser die Quoting-Regeln aus. Auf Linux
# prüft dieselbe Zustandsmatrix eine Nachbildung des Shell-Befehls.
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
    /usr/bin/osascript - "$1" "$2" < "$LINK_SCRIPT"
  }

  # Beleg, dass die Nachbildung dem echten AppleScript entspricht — sonst
  # prüfte die Linux-CI etwas anderes als das, was auf dem Mac wirklich läuft.
  probe_real=$(link_command "/tmp/Müller's/md-clip" "/tmp/Ziel mit Leerzeichen und Ö/md-clip")
  probe_built=$(build_link_command "/tmp/Müller's/md-clip" "/tmp/Ziel mit Leerzeichen und Ö/md-clip")
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
