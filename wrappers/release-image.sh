#!/usr/bin/env bash
# Zuordnung und Aufräumen des temporären Release-Images.

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
  # Das Zwischen-Image erst entfernen, wenn kein Device mehr davon liest.
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

apply_finder_layout() {
  osascript - "$1" <<'APPLESCRIPT'
on run arguments
set mountPath to item 1 of arguments
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
    try
      set position of item ".background" of container window to {900, 900}
    end try
    update without registering applications
    close
  end tell
end tell
end run
APPLESCRIPT
}
