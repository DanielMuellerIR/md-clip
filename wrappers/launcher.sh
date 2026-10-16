#!/bin/bash
# md-clip.app-Launcher.
#
# Wird beim Doppelklick auf md-clip.app ausgeführt. Zwei Aufgaben:
#
#   1. Erststart: Falls der Kommandozeilen-Befehl `md-clip` noch nicht
#      sauber in /usr/local/bin/ liegt, einen Dialog zeigen und auf
#      Wunsch einen Symlink ins App-Bundle anlegen.
#
#   2. Die gewählte Aktion starten: standardmäßig konvertieren, mit --undo
#      zurücknehmen, mit --preview prüfen oder mit --help die Aktionen erklären.
#
# Ein Fehler beim optionalen CLI-Setup darf die eigentliche Aktion
# nicht verhindern. Wenn der Symlink-Schritt aus irgendeinem Grund scheitert,
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

# Liegt das Bundle in einem Programme-Ordner? CLI-Symlink ergibt nur
# dann Sinn, wenn die .app an einem dauerhaften Ort liegt. Sonst zeigt
# der Symlink später ins Leere (z.B. wenn das DMG ausgeworfen wird
# oder die Kopie aus Downloads gelöscht wird).
# Rückgabe 0 = in Programme-Ordner, 1 = woanders.
is_in_applications_folder() {
  case "$BUNDLE_DIR" in
    /Applications/*) return 0 ;;
    "$HOME/Applications/"*) return 0 ;;
    *) return 1 ;;
  esac
}

# Entscheidet, was der Launcher bezüglich CLI-Installation tun soll.
# Echo gibt einen der folgenden Strings aus:
#   "install-ok"   — Bundle läuft aus Programme/, kein CLI sauber
#                    installiert, nichts abgelehnt → Install-Dialog.
#   "move-first"   — Bundle läuft NICHT aus Programme/ (z.B. direkt
#                    aus DMG-Mount, Downloads, Desktop). Immer warnen,
#                    egal in welchem Zustand der CLI-Symlink ist.
#   "none"         — Nichts zu tun (CLI schon korrekt verlinkt,
#                    fremde Installation nicht anrühren, Nutzer
#                    hat abgelehnt).
#
# Reihenfolge ist wichtig: der Programme-Ordner-Check kommt VOR der
# Symlink-Inspektion. Sonst greift bei „App ist schon in /Applications
# installiert, aber Nutzer startet aus Versehen die DMG-Kopie" der
# Symlink-zeigt-woandershin-Zweig und schluckt die Warnung.
decide_cli_action() {
  # Erstes Gate: läuft das Bundle aus einem dauerhaften Ort?
  if ! is_in_applications_folder; then
    echo "move-first"; return
  fi

  # Ab hier: Bundle ist in /Applications (oder ~/Applications).
  # Jetzt CLI-Symlink-Zustand prüfen.

  if [ -L "$SYSTEM_CLI" ]; then
    local target
    target="$(readlink "$SYSTEM_CLI")"

    # Zeigt schon auf DIESES Bundle → alles gut.
    if [ "$target" = "$BUNDLE_CLI" ]; then
      echo "none"; return
    fi

    # Symlink ist tot (Ziel existiert nicht). Den dürfen wir
    # überschreiben — passiert typisch nach Umzug einer früheren
    # Installation oder gelöschtem Worktree.
    if [ ! -e "$SYSTEM_CLI" ]; then
      echo "install-ok"; return
    fi

    # Symlink lebt und zeigt woandershin (z.B. auf eine git-clone-
    # Installation, die der Nutzer pflegt). Nicht anfassen.
    echo "none"; return
  fi

  # Reguläre Datei liegt dort. Eigene Installation des Nutzers — nicht
  # ungefragt überschreiben.
  if [ -e "$SYSTEM_CLI" ]; then
    echo "none"; return
  fi

  # Es liegt nichts in /usr/local/bin/md-clip. Hat der Nutzer „Nicht
  # mehr fragen" gewählt?
  local declined
  declined=$(defaults read "$BUNDLE_ID" CliInstallDeclined 2>/dev/null || echo 0)
  if [ "$declined" = "1" ]; then
    echo "none"; return
  fi

  echo "install-ok"
}

# Zeigt eine Meldung als Systemdialog. md-clip.app ist eine LSUIElement-App:
# kein Fenster, kein Dock-Symbol, und ihr stderr sieht beim Dock-Klick niemand.
# Ohne Dialog bliebe ein Fehler für den Nutzer schlicht unsichtbar.
#
# Der Text kommt als Argument und nicht als Zeichenkette in die AppleScript-
# Quelle: Anführungszeichen bleiben Daten. system attribute dekodiert UTF-8-
# Umgebungswerte auf macOS als MacRoman und beschädigt Umlaute. `|| true`, weil
# eine gescheiterte Meldung nichts schlimmer machen darf als der ursprüngliche Fehler.
show_message_dialog() {
  osascript - "$1" "${2:-error}" <<'APPLESCRIPT' >/dev/null 2>&1 || true
on run arguments
  set dialogText to item 1 of arguments
  set dialogKind to item 2 of arguments
  tell application "System Events"
    activate
    set dialogIcon to caution
    if dialogKind is "info" then set dialogIcon to note
    display dialog dialogText buttons {"OK"} default button "OK" with title "md-clip" with icon dialogIcon
  end tell
end run
APPLESCRIPT
}

show_error_dialog() { show_message_dialog "$1" error; }

show_action_help() {
  show_message_dialog "md-clip: Aktionen

Ohne Argument oder mit --convert: Clipboard nach Markdown konvertieren.
--preview: Markdown vor dem Ersetzen in einem Fenster prüfen.
--undo: Letzte Ersetzung einmalig zurücknehmen.
--help: Diese Hilfe anzeigen.

Undo gilt zehn Minuten und nur bis zum nächsten Kopieren. App-Hotkeys mit open -n starten, damit jeder Aufruf eine eigene Aktion ausführt." info
}

# Erstellt /usr/local/bin/md-clip als Symlink ins Bundle. Die Pfade werden
# als Umgebungsvariablen an AppleScript übergeben und dort mit `quoted form
# of` für die Shell maskiert. Dadurch bleibt auch ein App-Pfad mit Apostroph
# reiner Dateninhalt und kann keinen Shell-Befehl einschleusen.
#
# Der Zustand des Ziels wird im privilegierten Schritt NOCH EINMAL geprüft.
# decide_cli_action hat ihn zwar schon geprüft, aber danach liegt der
# Passwort-Dialog: In diesem Zeitfenster kann dort eine reguläre Datei oder ein
# lebender fremder Symlink entstehen, und dieser Schritt läuft als root.
install_cli() {
  if BUNDLE_CLI="$BUNDLE_CLI" SYSTEM_CLI="$SYSTEM_CLI" osascript <<'APPLESCRIPT' >/dev/null 2>&1; then
set bundleCli to system attribute "BUNDLE_CLI"
set systemCli to system attribute "SYSTEM_CLI"
set target to quoted form of systemCli
-- Der Shell-Befehl in Worten:
--   1. Zielverzeichnis anlegen, falls es fehlt.
--   2. `[ ! -e ... ]` folgt dem Symlink. Existiert das Ziel — reguläre Datei
--      oder lebender fremder Symlink —, bricht die Kette hier ab und lässt es
--      unangetastet.
--   3. Übrig bleiben zwei Fälle: gar nichts, oder ein toter Symlink. Nur den
--      toten Symlink räumen wir weg.
--   4. `ln -s` bewusst OHNE `-f`: Taucht in genau diesem Moment doch noch
--      etwas auf, scheitert der Befehl, statt es mit Root-Rechten zu ersetzen.
set commandText to "/bin/mkdir -p \"$(/usr/bin/dirname " & target & ")\"" & ¬
  " && [ ! -e " & target & " ]" & ¬
  " && { [ ! -L " & target & " ] || /bin/rm " & target & "; }" & ¬
  " && /bin/ln -s " & quoted form of bundleCli & " " & target
do shell script commandText with administrator privileges
APPLESCRIPT
    return 0
  fi

  show_error_dialog "Der Kommandozeilen-Befehl konnte nicht in /usr/local/bin eingerichtet werden. Die Clipboard-Konvertierung läuft trotzdem weiter."
  return 1
}

# Zeigt den Erststart-Dialog (CLI installieren?) und gibt die Wahl des
# Nutzers auf stdout aus. Bei „Später"/ESC kommt eine leere Zeichenkette.
ask_install() {
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

# Zeigt den Hinweis, dass das Bundle erst in den Programme-Ordner
# verschoben werden soll. Mit Button „Im Finder zeigen", der den
# aktuellen Bundle-Ort im Finder öffnet — von dort kann der Nutzer
# es per Drag-and-drop in /Programme bewegen.
ask_move_first() {
  # BUNDLE_DIR wird per Umgebungsvariable an osascript übergeben, weil
  # AppleScript-Strings keine einfache Bash-Variableninterpolation haben.
  BUNDLE_DIR="$BUNDLE_DIR" osascript <<'APPLESCRIPT' 2>/dev/null || true
tell application "System Events"
  activate
  set bundlePath to (system attribute "BUNDLE_DIR")
  set msg to "md-clip läuft gerade nicht aus dem Ordner Programme." & linefeed & linefeed & "Aktueller Ort:" & linefeed & bundlePath & linefeed & linefeed & "Bitte ziehe md-clip in den Ordner Programme und starte es von dort. So bleibt die App auch nach dem Auswerfen des Installations-Fensters erreichbar, und der optionale Kommandozeilen-Befehl kann eingerichtet werden."
  try
    set theResult to display dialog msg buttons {"OK", "Im Finder zeigen"} default button "OK" with title "md-clip" with icon note
    return button returned of theResult
  on error
    return ""
  end try
end tell
APPLESCRIPT
}

# Stößt die stille Update-Suche an (Sparkle, siehe
# helpers/md-clip-updater.swift). Der Helfer drosselt sich selbst auf
# höchstens einen Feed-Abruf je 24 Stunden und beendet sich ohne Fund
# wortlos — nur wenn es ein Update gibt, erscheint ein Dialog.
#
# Entkoppelt gestartet (&, Ausgaben verworfen): Die Update-Suche darf die
# Konvertierung weder verzögern noch — etwa bei fehlendem Netz — scheitern
# lassen. Fehlt der Helfer (z.B. Entwicklungs-Build ohne Sparkle), passiert
# schlicht nichts.
start_update_check() {
  local updater="$MACOS_DIR/md-clip-updater"
  [ -x "$updater" ] || return 0
  "$updater" --background >/dev/null 2>&1 &
}

# ---------- Hauptlogik ----------

launcher_main() {
  local action answer mode=convert diagnostic cli_status
  # Vor Setup-Dialogen und Clipboard-Zugriff entscheiden. LaunchServices kann
  # beim Finder-Start noch eine alte Prozessseriennummer übergeben.
  if [ "$#" -gt 1 ]; then
    show_error_dialog "Nur eine App-Aktion erlaubt: --convert, --preview, --undo oder --help."
    return 2
  fi
  case "${1:-}" in
    ""|--convert) ;;
    --undo) mode=undo ;;
    --preview) mode=preview ;;
    --help|-h) show_action_help; return 0 ;;
    *)
      if ! [[ "$1" =~ ^-psn_[0-9]+_[0-9]+$ ]]; then
        show_error_dialog "Unbekannte App-Aktion. Erlaubt sind --convert, --preview, --undo und --help."
        return 2
      fi ;;
  esac
  if [ ! -x "$BUNDLE_CLI" ]; then
    show_error_dialog "md-clip ist unvollständig: Der eingebettete Befehl fehlt oder ist nicht ausführbar. Bitte die App neu installieren."
    return 2
  fi
  if [ "$mode" = undo ]; then
    if diagnostic=$("$BUNDLE_CLI" --undo --notify 2>&1 >/dev/null); then
      return 0
    else
      cli_status=$?
      if [ "$cli_status" -eq 1 ]; then
        show_error_dialog "Keine gültige Rücknahme verfügbar.

Eine Ersetzung lässt sich zehn Minuten lang, einmalig und nur bis zum nächsten Kopieren zurücknehmen.

$diagnostic"
      else
        show_error_dialog "Die Rücknahme ist fehlgeschlagen.

$diagnostic"
      fi
      return "$cli_status"
    fi
  fi
  if [ "$mode" = preview ]; then
    if diagnostic=$("$BUNDLE_CLI" --replace --preview-window --notify 2>&1 >/dev/null); then
      return 0
    else
      cli_status=$?
      if [ "$cli_status" -ne 4 ]; then show_error_dialog "Die Vorschau konnte nicht abgeschlossen werden.

$diagnostic"; fi
      return "$cli_status"
    fi
  fi
  action="$(decide_cli_action)"

  case "$action" in
    install-ok)
      answer="$(ask_install)"
      case "$answer" in
        "Ja, einrichten")
          install_cli || true
          ;;
        "Nicht mehr fragen")
          defaults write "$BUNDLE_ID" CliInstallDeclined -bool true
          ;;
        *)
          # „Später", ESC, oder Dialog-Fehler → nichts speichern.
          :
          ;;
      esac
      ;;
    move-first)
      answer="$(ask_move_first)"
      if [ "$answer" = "Im Finder zeigen" ]; then
        # Bundle im Finder selektieren, damit der Nutzer es direkt
        # rüberziehen kann.
        open -R "$BUNDLE_DIR" >/dev/null 2>&1 || true
      fi
      ;;
    none|*)
      : # nichts tun
      ;;
  esac

  # Jetzt der eigentliche md-clip-Lauf. --replace ersetzt das Clipboard,
  # --notify zeigt bei Erfolg das HUD.
  "$BUNDLE_CLI" --replace --notify
  local cli_status=$?

  # Update-Suche NACH der Konvertierung: Sie ist Nebensache und läuft im
  # Hintergrund weiter, wenn dieser Launcher sich gleich beendet.
  start_update_check

  return "$cli_status"
}

# Tests dürfen die Funktionen laden, ohne Dialoge oder das Bundle zu starten.
if [ "${MD_CLIP_LAUNCHER_SOURCE_ONLY:-0}" != "1" ]; then
  launcher_main "$@"
fi
