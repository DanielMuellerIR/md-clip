#!/usr/bin/env bash
# Lese- und Schreibadapter, Rich-Text-Import und Benachrichtigung.

# Einige Clipboard-Anbieter liefern HTML als UTF-16. Die BOM bestimmt
# das Encoding. Bash-Variablen würden vor der Prüfung NUL-Bytes verlieren.
to_utf8() {
  local file="$1"
  local bom

  bom="$(head -c 3 "$file" | od -An -tx1 | tr -d ' \n')"

  case "$bom" in
    fffe*|feff*)
      # UTF-16, Little- oder Big-Endian. Wir übergeben iconv bewusst
      # „UTF-16" OHNE LE/BE-Suffix: In dieser Form wertet iconv die BOM
      # selbst aus, erkennt die Byte-Reihenfolge daran und entfernt sie
      # aus der Ausgabe. Mit „UTF-16LE" müssten wir die Reihenfolge selbst
      # bestimmen und die BOM bliebe als unsichtbares Zeichen im Text stehen.
      iconv -f UTF-16 -t UTF-8 < "$file"
      ;;
    efbbbf*)
      # UTF-8 mit BOM. Der Inhalt stimmt schon, nur die drei BOM-Bytes
      # müssen weg — sonst landen sie als unsichtbarer Fleck am Anfang des
      # Markdowns. `tail -c +4` gibt alles ab dem 4. Byte aus.
      tail -c +4 "$file"
      ;;
    *)
      # Kein BOM → schon reines UTF-8, unverändert durchreichen.
      cat "$file"
      ;;
  esac
}

# linux_clip_read: Liest den ersten verfügbaren der übergebenen MIME-Typen
# vom Clipboard und gibt ihn als UTF-8 auf stdout aus.
# Exit 0 = etwas gefunden, Exit 1 = keiner der Typen liegt an.
#
# Mehrere Typen, weil sich die Programme nicht einig sind: RTF liegt je nach
# Quelle als text/rtf oder als application/rtf an.
linux_clip_read() {
  local mime tmp
  tmp="$(mktemp)"

  for mime in "$@"; do
    # `|| continue`: Fehlt der Typ auf dem Clipboard, melden xclip und
    # wl-paste einen Fehler — das ist hier kein Problem, sondern die
    # normale Antwort „hab ich nicht", also nächsten Typ probieren.
    if [ "$CLIP_BACKEND" = "wayland" ]; then
      wl-paste --no-newline --type "$mime" > "$tmp" 2>/dev/null || continue
    else
      xclip -selection clipboard -target "$mime" -out > "$tmp" 2>/dev/null || continue
    fi

    # Eine leere Datei kann entstehen, weil
    # manche xclip-Versionen bei fehlendem Typ trotzdem Exit 0 melden und
    # einfach nichts ausgeben.
    if [ -s "$tmp" ]; then
      # Das `|| { … }` ist die Aufräum-Garantie: Ohne den Zweig würde ein
      # Fehler in to_utf8 (z.B. kaputtes UTF-16) die Temp-Datei liegen lassen.
      to_utf8 "$tmp" || { rm -f "$tmp"; return 1; }
      rm -f "$tmp"
      return 0
    fi
  done

  rm -f "$tmp"
  return 1
}

# clip_read_html: HTML-Flavor vom Clipboard holen.
# Exit 0 + HTML auf stdout, wenn vorhanden; sonst Exit 1 ohne Ausgabe.
clip_read_html() {
  if [ "$PLATFORM" = "macos" ]; then
    "$HTML_HELPER" 2>/dev/null
  else
    linux_clip_read text/html
  fi
}

# clip_read_rtf: RTF-Flavor vom Clipboard holen.
#
# Auf macOS nutzen wir den Swift-Helper statt `pbpaste -Prefer rtf`, weil
# pbpaste auf Plain Text ausweicht, sobald zusätzlich zum RTF auch RTFD auf
# dem Clipboard liegt (typisch für TextEdit-Inhalte mit Bildern). Der Helper
# greift direkt auf den .rtf-Flavor in NSPasteboard zu — zuverlässig.
clip_read_rtf() {
  if [ "$PLATFORM" = "macos" ]; then
    "$RTF_HELPER" 2>/dev/null
  else
    linux_clip_read text/rtf application/rtf
  fi
}

# clip_read_text: Plain-Text vom Clipboard holen.
clip_read_text() {
  if [ "$PLATFORM" = "macos" ]; then
    pbpaste
  elif [ "$CLIP_BACKEND" = "wayland" ]; then
    # --no-newline: wl-paste hängt sonst ein Newline an, das im Original
    # nicht stand. pbpaste tut das nicht — so verhalten sich beide gleich.
    wl-paste --no-newline 2>/dev/null
  else
    xclip -selection clipboard -out 2>/dev/null
  fi
}

# Die Helfer halten die vollständige Formatsicherung nur im Arbeitsspeicher.
# Die Ersetzung bleibt an dieselbe Clipboard-Generation wie die Sicherung gebunden.
undo_helper_path() {
  local name
  if [ "$PLATFORM" = macos ]; then name=clipboard-undo; else name=clipboard-undo-linux.py; fi
  if [ -x "$SCRIPT_DIR/$name" ]; then
    printf '%s\n' "$SCRIPT_DIR/$name"
  else
    printf '%s\n' "$PROJECT_ROOT/helpers/$name"
  fi
}

clip_undo_command() {
  local helper
  helper=$(undo_helper_path)
  [ -x "$helper" ] || { err "Undo-Helfer fehlt (install.sh ausführen)."; return 2; }
  "$helper" "$@"
}

native_preview_helper_path() {
  [ "$PLATFORM" = macos ] || return 2
  if [ -n "$BUNDLE_MACOS_DIR" ] && [ -x "$BUNDLE_MACOS_DIR/md-clip-preview" ]; then
    printf '%s\n' "$BUNDLE_MACOS_DIR/md-clip-preview"
  else printf '%s\n' "$PROJECT_ROOT/helpers/md-clip-preview"; fi
}

native_preview_available() {
  local helper
  helper=$(native_preview_helper_path) || return 1
  [ -x "$helper" ]
}

clip_read_tools_ready() {
  case "$PLATFORM:$CLIP_BACKEND" in
    macos:*) command -v pbpaste ;;
    linux:x11) command -v xclip ;;
    linux:wayland) command -v wl-paste ;;
  esac >/dev/null 2>&1
}

# Feste Kennung statt ungefilterter Helferfehler; Diagnose liest keine Nutzdaten.
clip_diagnose() {
  local helper diagnosis
  helper=$(undo_helper_path)
  [ -x "$helper" ] || { printf 'undo-helper-missing'; return; }
  if [ "$PLATFORM" = linux ] && ! command -v python3 >/dev/null 2>&1; then
    printf 'python-missing'; return
  fi
  diagnosis=$("$helper" diagnose 2>/dev/null) || { printf 'undo-helper-failed'; return; }
  case "$diagnosis" in
    ok|macos-session-missing|python-unsupported|local-security-unsupported|runtime-unsafe|x11-session-missing|x11-connect-failed|x11-libraries-missing|x11-xfixes-missing|wayland-runtime-missing|wayland-connect-failed|wayland-data-control-missing|wayland-seat-unsupported)
      printf '%s' "$diagnosis" ;;
    *) printf 'undo-helper-failed' ;;
  esac
}

clip_prepare_replace() { clip_undo_command prepare; }
clip_cancel_replace() { clip_undo_command cancel "$1"; }
clip_restore() { clip_undo_command undo; }

# clip_write_text ersetzt alle Rich-Flavors durch Text. Der Helfer prüft direkt
# davor den ursprünglichen Eigentümer und bindet Undo an seinen Schreibvorgang.
clip_write_text() {
  clip_undo_command replace "$UNDO_TOKEN"
}

# rtf_fix_escaped_newlines liegt in lib/pipeline.sh und wird dort von
# Produkt und Tests gemeinsam verwendet.

# rtf_to_html: RTF von stdin nach HTML auf stdout.
#
# macOS: textutil (Bordmittel, nutzt Apples eigenen RTF-Parser).
# Linux: pandocs RTF-Reader (seit pandoc 2.19), plus die Spec-Korrektur oben.
#
# Beide Wege liefern für tests/fixtures/word-rtf.rtf identisches Markdown —
# das pinnt der word-rtf-Test auf beiden Plattformen gegen dieselbe Erwartung.
rtf_to_html() {
  if [ "$PLATFORM" = "macos" ]; then
    # textutil setzt die \par-Kurzform von sich aus korrekt um — hier ist
    # rtf_fix_escaped_newlines nicht nötig und bleibt bewusst weg, damit der
    # macOS-Pfad exakt der bisherige bleibt.
    textutil -convert html -format rtf -stdin -stdout
  else
    rtf_fix_escaped_newlines | pandoc -f rtf -t html
  fi
}

# Nur Werkzeuge des tatsächlich ausgeführten Weges prüfen. Rückgabe statt
# exit: auto darf einen nicht verfügbaren Rich-Weg überspringen.
check_dependencies() {
  local kind="$1" tool
  local required=()
  if [ "$kind" = write ]; then
    clip_undo_command available || return 2
    return 0
  fi
  case "$kind" in
    html|rtf) required=(pandoc perl) ;;
  esac
  if [ "$kind" = rtf ] && [ "$PLATFORM" = macos ]; then required+=(textutil); fi
  if [ "$kind" = read ]; then
    case "$PLATFORM:$CLIP_BACKEND:$kind" in
      macos:*:read)
        case "$FROM" in
          html) [ -x "$HTML_HELPER" ] || { err "HTML-Helper fehlt (install.sh ausführen)."; return 2; } ;;
          rtf) [ -x "$RTF_HELPER" ] || { err "RTF-Helper fehlt (install.sh ausführen)."; return 2; } ;;
          plain) required=(pbpaste) ;;
          auto) ;; # Fehlende einzelne Flavor-Werkzeuge überspringen.
        esac ;;
      linux:wayland:read) required=(wl-paste) ;;
      linux:x11:read) required=(xclip) ;;
    esac
  fi
  for tool in ${required[@]+"${required[@]}"}; do
    command -v "$tool" >/dev/null 2>&1 || {
      err "Fehlende Dependency: $tool"; return 2;
    }
  done
  case "$kind" in
    html|rtf)
      if ! pandoc_supports_sandbox; then
        err "Das installierte pandoc kennt die Option --sandbox nicht. Bitte pandoc >= 2.15 installieren."
        return 2
      fi ;;
  esac
  if [ "$kind" = rtf ] && [ "$PLATFORM" = linux ] && ! pandoc_supports_rtf; then
    err "Pandoc unterstützt das Eingabeformat RTF nicht. Bitte pandoc >= 2.15 installieren."
    return 2
  fi
}

# notify: Desktop-Notification anzeigen, wenn --notify gesetzt ist.
# Auf macOS via osascript (Bordmittel), auf Linux via notify-send (libnotify).
notify() {
  if [ "$NOTIFY" -eq 0 ] || [ "$QUIET" -eq 1 ]; then
    return 0
  fi

  if [ "$PLATFORM" = "macos" ]; then
    # Bundle-Layout: Die Erfolgsmeldung zeigt der HUD-Helfer als kurzes
    # Einblend-Fenster der App — ohne Erlaubnis-Mechanik des Notification
    # Centers, die für md-clips Aufrufwege (Dock, Hotkey, Skript) nicht
    # tragfähig ist (Begründung in helpers/md-clip-hud.swift). Entkoppelt
    # gestartet: Das Ein-/Ausblenden dauert gut zwei Sekunden, und darauf
    # soll weder die CLI noch der Launcher warten. Der osascript-Weg unten
    # bleibt der Fallback der git-Installation ohne App-Bundle.
    local hud
    hud="$BUNDLE_MACOS_DIR/md-clip-hud"
    if [ -n "$BUNDLE_MACOS_DIR" ] && [ -x "$hud" ]; then
      "$hud" "$1" >/dev/null 2>&1 &
      return 0
    fi
    # Anführungszeichen und Backslashes im Meldungstext würden den AppleScript-
    # Parser durcheinander bringen, wenn wir sie roh in den String interpolieren.
    # Lösung: osascript als argv-Aufruf (-e mit getrennten Argumenten) — dann
    # wird der Text als AppleScript-Literal übergeben, nicht als String-Konkatenation.
    # Das umgeht die Injection vollständig, weil kein String-Building mehr nötig ist.
    osascript \
      -e 'on run argv' \
      -e 'display notification (item 1 of argv) with title "md-clip"' \
      -e 'end run' \
      -- "$1" || true
  else
    # notify-send nimmt Titel und Text als zwei normale Argumente — kein
    # String-Building, also auch hier keine Injection möglich. Das `--`
    # trennt Optionen von Argumenten, damit eine Meldung, die mit „-"
    # beginnt, nicht als Flag missverstanden wird.
    #
    # `|| true`, weil notify-send einen laufenden Notification-Daemon über
    # D-Bus braucht: Über SSH, in einem Container oder in einer reinen
    # Terminal-Sitzung gibt es keinen — die fehlende Notification darf den
    # eigentlichen Job (Markdown konvertieren) niemals scheitern lassen.
    notify-send -- "md-clip" "$1" || true
  fi
}

# is_mso_html: Prüft, ob ein HTML-Blob aus Microsoft Word stammt.
# Word legt seine eigene HTML-Variante aufs Clipboard, voller Office-XML-
# Namespaces und mso-*-CSS — strukturell so verbogen, dass Pandoc damit
# komplett überfordert ist (Output: rohes HTML statt Markdown). Wenn wir
# diese Variante erkennen, ist der RTF-Pfad fast immer das bessere
# Ergebnis. Heuristik:
#   1. Office-Namespace im <html>-Tag (sehr zuverlässig), ODER
#   2. mindestens 10 `mso-`-Marker im Body (Fallback für variantenreiche
#      Office-Versionen).
# Argument: $1 = erfasste HTML-Datei.
# Rückgabe: 0 wenn MSO, 1 wenn normales HTML.
is_mso_html() {
  command -v perl >/dev/null 2>&1 || return 1
  # NUL nur für die Heuristik entfernen. Auch minifiziertes HTML kann zehn
  # Marker auf derselben Zeile enthalten.
  perl -0777 -e '
    my $html = <STDIN>;
    exit 1 unless defined $html;
    $html =~ tr/\0//d;
    exit 0 if $html =~ /microsoft-com:office|name=Generator content="Microsoft/;
    for (1 .. 10) { exit 1 unless $html =~ /mso-/g; }
  ' < "$1"
}
