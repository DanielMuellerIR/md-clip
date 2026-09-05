#!/usr/bin/env bash
# Vom Wrapper-Testrunner im isolierten Testverzeichnis geladen.
TEST_SCRIPT="${BASH_SOURCE[0]}"
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

# Fehlt die eingebettete CLI, muss der Nutzer das erfahren. Die App hat kein
# Fenster; ohne Dialog sähe der Dock-Klick aus, als täte sie nichts.
DIALOG_CAPTURE="$UPDATE_ROOT/capture/dialog"
show_error_dialog() {
  printf '%s\n' "$1" > "$DIALOG_CAPTURE"
}
# Erst abwarten, bis die Updater-Attrappe des vorigen Falls fertig ist. Sie
# laeuft im Hintergrund und schreibt `args` sofort, `done` nach zwei Sekunden.
# Wer hier zu frueh loescht, bekommt ihr `args` NACH dem Loeschen zurueck — die
# Pruefung unten hielte das faelschlich fuer eine neu angestossene Update-Suche
# (in dieser Form einmal rot gelaufen, 2026-09-03).
for _ in $(seq 1 50); do
  [ -f "$UPDATE_ROOT/capture/done" ] && break
  sleep 0.2
done
if [ ! -f "$UPDATE_ROOT/capture/done" ]; then
  echo "✗ Updater-Attrappe des vorigen Falls wurde nicht fertig" >&2
  exit 1
fi
rm -f "$UPDATE_ROOT/capture/args" "$UPDATE_ROOT/capture/done" \
  "$UPDATE_ROOT/capture/cli-args" "$DIALOG_CAPTURE"
BUNDLE_CLI="$UPDATE_ROOT/gibt-es-nicht"
set +e
launcher_main
MISSING_CLI_STATUS=$?
set -e
if [ "$MISSING_CLI_STATUS" -ne 2 ]; then
  echo "✗ Launcher meldet eine fehlende CLI nicht mit Exit 2 (war $MISSING_CLI_STATUS)" >&2
  exit 1
fi
if [ ! -f "$DIALOG_CAPTURE" ]; then
  echo "✗ Launcher zeigt bei fehlender CLI keinen Dialog" >&2
  exit 1
fi
grep -Fq 'md-clip ist unvollständig' "$DIALOG_CAPTURE"
if [ -e "$UPDATE_ROOT/capture/args" ]; then
  echo "✗ Launcher startet bei kaputtem Bundle trotzdem die Update-Suche" >&2
  exit 1
fi
echo "✓ Launcher meldet ein Bundle ohne eingebettete CLI sichtbar"
unset -f show_error_dialog

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

# --- HUD: genau ein nicht leerer Meldungstext. ---
# Der zweite Cocoa-Helfer im Bundle hatte bisher keinen Vertragstest, obwohl
# bin/md-clip ihn bei jedem Erfolg und jedem Fehler aufruft. Geprüft werden nur
# die Ablehnungen: Sie enden mit Exit 64, bevor der Helfer AppKit anfasst.
# Der Erfolgsfall bliebe zwei Sekunden als Fenster stehen und hat in einem
# automatischen Lauf nichts zu suchen.
#
# Anders als der Updater hat das HUD KEINEN modulfreien Testmodus: Es importiert
# AppKit schon in der ersten Zeile. Der Block braucht deshalb macOS und nicht nur
# einen Swift-Compiler — der Ubuntu-Runner der CI hat swiftc, aber kein AppKit,
# und der Lauf scheiterte dort mit „no such module 'AppKit'" (2026-09-03).
if [ "$(uname -s)" = "Darwin" ] && [ -n "$SWIFTC" ]; then
HUD_BINARY="$TEST_ROOT/md-clip-hud-contract-test"
PATH="$MD_CLIP_HOST_PATH" "$SWIFTC" "$PROJECT_ROOT/helpers/md-clip-hud.swift" -o "$HUD_BINARY"

assert_hud_rejected() {
  local label="$1"
  shift
  local stderr="$TEST_ROOT/hud-$label.err"
  local status

  set +e
  "$HUD_BINARY" "$@" >/dev/null 2> "$stderr"
  status=$?
  set -e
  if [ "$status" -ne 64 ]; then
    echo "✗ HUD akzeptiert $label oder meldet falschen Exit $status" >&2
    exit 1
  fi
  grep -Fq 'Aufruf: md-clip-hud <Meldungstext>' "$stderr"
}

assert_hud_rejected fehlenden-text
assert_hud_rejected leeren-text ""
assert_hud_rejected zwei-texte "eins" "zwei"
echo "✓ HUD verlangt genau einen nicht leeren Meldungstext"
else
  echo "⚠ HUD-Vertragstest übersprungen: der Helfer ist AppKit-basiert und damit macOS-only." >&2
fi

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
