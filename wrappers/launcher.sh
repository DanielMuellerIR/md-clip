#!/bin/bash
# md-clip.app-Launcher.
#
# Wird beim Doppelklick auf md-clip.app ausgeführt. Zwei Aufgaben:
#
#   1. Erststart: Falls der Kommandozeilen-Befehl `md-clip` noch nicht
#      in /usr/local/bin/ liegt, einen Dialog zeigen und auf Wunsch
#      einen Symlink ins App-Bundle anlegen.
#
#   2. Den eigentlichen md-clip-Lauf starten: Clipboard-Inhalt nach
#      Markdown konvertieren und wieder ins Clipboard schreiben.
#
# Wichtig: keine Fehler nach außen lassen, die den eigentlichen Lauf
# verhindern. Wenn der Symlink-Schritt aus irgendeinem Grund scheitert,
# soll md-clip trotzdem die Konvertierung durchführen.

# Bundle-Identifier; wird auch als Domain für `defaults` verwendet, um
# die Nutzer-Entscheidung „Nicht mehr fragen" zu speichern.
BUNDLE_ID="io.github.danielmuellerir.md-clip"

# Pfade relativ zum Launcher-Skript bestimmen. Der Launcher liegt unter
# Contents/MacOS/md-clip im Bundle.
MACOS_DIR="$(cd "$(dirname "$0")" && pwd)"
BUNDLE_DIR="$(cd "$MACOS_DIR/../.." && pwd)"
BUNDLE_CLI="$BUNDLE_DIR/Contents/Resources/bin/md-clip"
SYSTEM_CLI="/usr/local/bin/md-clip"

# ---------- Funktionen ----------

# Entscheidet, ob wir den Erststart-Dialog überhaupt anzeigen.
# Rückgabe 0 = ja anzeigen, 1 = nein.
should_offer_cli_install() {
  # Fall A: Symlink existiert — prüfen, wohin er zeigt.
  if [ -L "$SYSTEM_CLI" ]; then
    if [ "$(readlink "$SYSTEM_CLI")" = "$BUNDLE_CLI" ]; then
      # Schon mit DIESEM Bundle verknüpft → nichts zu tun.
      return 1
    fi
    # Symlink zeigt woandershin (z.B. auf eine git-clone-Installation).
    # Nicht ungefragt überschreiben.
    return 1
  fi

  # Fall B: Eine reguläre Datei liegt dort. Der Nutzer hat eine eigene
  # Installation gemacht — nicht anrühren.
  if [ -e "$SYSTEM_CLI" ]; then
    return 1
  fi

  # Fall C: Nichts liegt dort. Hat der Nutzer früher „Nicht mehr fragen"
  # gewählt? Dann gibt `defaults read` „1" zurück.
  local declined
  declined=$(defaults read "$BUNDLE_ID" CliInstallDeclined 2>/dev/null || echo 0)
  if [ "$declined" = "1" ]; then
    return 1
  fi

  # Niemand hat etwas installiert, keine Ablehnung gespeichert: fragen.
  return 0
}

# Erstellt /usr/local/bin/md-clip als Symlink ins Bundle.
# Erfordert Admin-Rechte (mkdir + ln im Systempfad), daher
# `with administrator privileges` für die Passwort-Abfrage.
install_cli() {
  osascript -e "do shell script \"mkdir -p /usr/local/bin && ln -sf '$BUNDLE_CLI' '$SYSTEM_CLI'\" with administrator privileges" \
    >/dev/null 2>&1 || true
}

# Zeigt den Erststart-Dialog und gibt die Wahl des Nutzers auf stdout aus.
# Bei Klick auf „Später" oder ESC kommt eine leere Zeichenkette zurück.
ask_user() {
  # AppleScript-Dialog: drei Buttons, „Ja, einrichten" als Default rechts,
  # „Später" als Cancel-Button (reagiert auch auf ESC).
  # `linefeed` baut echte Zeilenumbrüche im Dialog-Text.
  osascript <<'APPLESCRIPT' 2>/dev/null || true
tell application "System Events"
  activate
  set msg to "Möchtest du zusätzlich den Kommandozeilen-Befehl md-clip einrichten?" & linefeed & linefeed & "Damit lässt sich md-clip auch in Skripten und im Terminal direkt aufrufen. Es wird ein Verweis in /usr/local/bin/ angelegt; macOS fragt dafür einmal nach dem Anmelde-Passwort."
  try
    set theResult to display dialog msg buttons {"Nicht mehr fragen", "Später", "Ja, einrichten"} default button "Ja, einrichten" cancel button "Später" with title "md-clip" with icon note
    return button returned of theResult
  on error
    return ""
  end try
end tell
APPLESCRIPT
}

# ---------- Hauptlogik ----------

# Erststart-Pfad: falls nötig, Dialog zeigen und Wahl umsetzen.
if should_offer_cli_install; then
  answer=$(ask_user)
  case "$answer" in
    "Ja, einrichten")
      install_cli
      ;;
    "Nicht mehr fragen")
      defaults write "$BUNDLE_ID" CliInstallDeclined -bool true
      ;;
    *)
      # „Später" oder ESC → nichts speichern, beim nächsten Start wieder fragen.
      :
      ;;
  esac
fi

# Jetzt der eigentliche md-clip-Lauf. --replace ersetzt das Clipboard,
# --notify zeigt eine macOS-Benachrichtigung bei Erfolg.
"$BUNDLE_CLI" --replace --notify
