#!/usr/bin/env bash
# Werkzeugdiagnose und JSON-Ausgabe ohne Clipboard-Zugriff.

rtf_tools_ready() {
  if [ "$PLATFORM" = macos ]; then command -v textutil >/dev/null 2>&1
  else [ "$1" = true ]; fi
}

doctor_platform_issues() {
  if [ "$PLATFORM" = macos ]; then
    command -v textutil >/dev/null 2>&1 || doctor_issue textutil-missing warning 'textutil fehlt; der macOS-RTF-Weg ist nicht verfügbar.' 'Die macOS-Systemwerkzeuge und den PATH prüfen.'
    [ -x "$HTML_HELPER" ] || doctor_issue html-helper-missing warning 'Der macOS-HTML-Lesehelfer fehlt.' 'install.sh ausführen oder die vollständige App verwenden.'
    [ -x "$RTF_HELPER" ] || doctor_issue rtf-helper-missing warning 'Der macOS-RTF-Lesehelfer fehlt.' 'install.sh ausführen oder die vollständige App verwenden.'
  elif [ "$2" = true ] && [ "$1" = false ]; then
    doctor_issue pandoc-no-rtf warning 'Der RTF-Reader von pandoc fehlt.' 'pandoc mit RTF-Unterstützung installieren; HTML und Klartext separat verwenden.'
  fi
}

doctor_json_string() {
  local value="$1" byte escape index
  local LC_ALL=C
  value=${value//\\/\\\\}
  value=${value//\"/\\\"}
  # Doctor muss auch dann gültiges JSON liefern, wenn die untersuchten
  # Interpreter fehlen. UTF-8 bleibt bytegenau erhalten.
  if [[ "$value" == *[[:cntrl:]]* ]]; then
    for ((index = 1; index < 32; index++)); do
      printf -v escape '%03o' "$index"
      printf -v byte '%b' "\\$escape"
      printf -v escape '\\u%04x' "$index"
      value=${value//"$byte"/"$escape"}
    done
  fi
  printf '"%s"' "$value"
}

doctor_state_label() {
  case "$1" in
    true) printf 'ja' ;;
    false) printf 'nein' ;;
    ready) printf 'bereit' ;;
    unavailable) printf 'nicht erreichbar' ;;
    unsupported) printf 'nicht unterstützt' ;;
    *) printf 'nicht geprüft' ;;
  esac
}

doctor_issue() {
  local code="$1" severity="$2" message="$3" next="$4"
  issues+="$issue_sep{\"code\":\"$code\",\"severity\":\"$severity\",\"message\":$(doctor_json_string "$message"),\"next_step\":$(doctor_json_string "$next")}"
  issue_sep=,
  if [ "$JSON" -eq 0 ]; then
    printf '[%s] %s\n  Nächster Schritt: %s\n' "$code" "$message" "$next"
  fi
}

# Doctor prüft ausschließlich Werkzeuge und Sitzungsmetadaten. Es liest keine
# Formate, erzeugt keinen Undo-Daemon und sagt nichts über eine gültige Sicherung.
doctor() {
  local tool available version path sep="" sandbox=false rtf=false lua=false undo=false
  local diagnosis session read_tools=false write_tools=false read_ready=null replace_ready=false
  local native_preview=false native_resource=false native_label="nicht verfügbar"
  local html=false rtf_conversion=false pandoc_runs=false issues="" issue_sep=""
  if native_preview_available; then
    native_resource=true
    clip_undo_command status >/dev/null 2>&1 && native_preview=true
  fi
  if [ "$native_preview" = true ]; then native_label="verfügbar"; fi
  diagnosis=$(clip_diagnose)
  case "$diagnosis" in
    ok) session=ready; undo=true; write_tools=true ;;
    x11-xfixes-missing|wayland-data-control-missing|wayland-seat-unsupported) session=unsupported ;;
    *session-missing|*connect-failed|wayland-runtime-missing|runtime-unsafe) session=unavailable ;;
    *) session=unverified ;;
  esac
  clip_read_tools_ready && read_tools=true
  case "$diagnosis" in
    macos-session-missing|runtime-unsafe|x11-session-missing|x11-connect-failed|x11-xfixes-missing|wayland-runtime-missing|wayland-connect-failed|wayland-data-control-missing|wayland-seat-unsupported)
      write_tools=true ;;
  esac
  pandoc_supports_sandbox && sandbox=true
  pandoc_supports_rtf && rtf=true
  pandoc_supports_table_filter && lua=true
  if command -v perl >/dev/null 2>&1 && [ "$sandbox" = true ] && [ "$lua" = true ]; then html=true; fi
  if [ "$html" = true ] && rtf_tools_ready "$rtf"; then rtf_conversion=true; fi
  if [ "$read_tools" = false ]; then read_ready=false
  elif [ "$session" = ready ]; then read_ready=true
  elif [ "$session" = unavailable ]; then read_ready=false; fi
  replace_ready=$undo
  if [ "$JSON" -eq 1 ]; then
    printf '{"version":"%s","backend":"%s","sandbox":%s,"rtf_reader":%s,"table_filter":%s,"stdin":true,"files":true,"preview":true,"native_preview":%s,"strict":true,"image_modes":["keep","alt","omit"],"table_modes":["reject","text"],"undo":%s,"dependencies":{' "$VERSION" "${CLIP_BACKEND:-macos}" "$sandbox" "$rtf" "$lua" "$native_preview" "$undo"
  else
    printf 'md-clip %s; Backend: %s\n' "$VERSION" "${CLIP_BACKEND:-macos}"
    printf 'stdin/Datei: ja; Vorschau: Terminal; Fenstervorschau: %s; Undo-Helfer: %s\nSandbox: %s; RTF-Reader: %s; Tabellenfilter: %s\n' "$native_label" "$undo" "$sandbox" "$rtf" "$lua"
  fi
  for tool in pandoc perl textutil pbpaste pbcopy xclip wl-paste wl-copy iconv clipboard-html clipboard-rtf python3; do
    available=false; version=""
    case "$tool" in
      clipboard-html) path="$HTML_HELPER" ;;
      clipboard-rtf) path="$RTF_HELPER" ;;
      *) path=$(command -v "$tool" || true) ;;
    esac
    if [ -n "$path" ] && [ -x "$path" ]; then
      available=true
      case "$tool" in
        pandoc) if version=$(pandoc --version 2>/dev/null | head -1); then pandoc_runs=true; fi ;;
        perl) version=$(perl -e 'printf "%vd", $^V' 2>/dev/null || true) ;;
        python3) version=$(python3 --version 2>/dev/null | head -1 || true) ;;
        wl-copy|wl-paste) version=$("$tool" --version 2>/dev/null | head -1 || true) ;;
        xclip) version=$(xclip -version 2>&1 | head -1 || true) ;;
        *) version="Systemwerkzeug (ohne Versionsangabe)" ;;
      esac
    fi
    version=$(printf '%s' "$version" | LC_ALL=C tr -cd '[:print:]')
    version=${version:0:200}
    if [ "$JSON" -eq 1 ]; then
      printf '%s"%s":{"available":%s,"version":%s}' "$sep" "$tool" "$available" "$(doctor_json_string "$version")"
      sep=,
    else
      printf '%s: %s %s\n' "$tool" "$available" "$version"
    fi
  done
  if [ "$JSON" -eq 0 ]; then
    printf 'Fähigkeiten: Plain-Datei/stdin: ja; HTML: %s; RTF: %s\n' "$(doctor_state_label "$html")" "$(doctor_state_label "$rtf_conversion")"
    printf 'Clipboard-Lesewerkzeuge: %s; Schreibwerkzeuge: %s; Sitzung: %s\n' "$(doctor_state_label "$read_tools")" "$(doctor_state_label "$write_tools")" "$(doctor_state_label "$session")"
    printf 'Clipboard lesen: %s; Ersetzen mit Undo: %s\n' "$(doctor_state_label "$read_ready")" "$(doctor_state_label "$replace_ready")"
  fi
  if ! command -v pandoc >/dev/null 2>&1; then
    doctor_issue pandoc-missing error 'pandoc fehlt; Rich-Text-Konvertierung ist nicht verfügbar.' 'pandoc installieren; Klartext-Datei/stdin funktioniert bereits.'
  elif [ "$pandoc_runs" = false ]; then
    doctor_issue pandoc-unusable error 'pandoc lässt sich nicht ausführen.' 'pandoc-Installation und ausführbare Datei prüfen oder neu installieren.'
  else
    [ "$sandbox" = true ] || doctor_issue pandoc-no-sandbox error 'pandoc unterstützt die erforderliche Sandbox nicht.' 'Ein aktuelles pandoc mit --sandbox installieren.'
    [ "$lua" = true ] || doctor_issue table-filter-unavailable error 'Der gemeinsame Tabellenfilter ist nicht ausführbar.' 'Perl und die vollständigen lib-Ressourcen prüfen; anschließend pandoc aktualisieren.'
  fi
  command -v perl >/dev/null 2>&1 || doctor_issue perl-missing error 'Perl fehlt; Rich-Text-Konvertierung ist nicht verfügbar.' 'Perl beziehungsweise perl-base installieren.'
  doctor_platform_issues "$rtf" "$pandoc_runs"
  if [ "$native_resource" = true ] && [ "$native_preview" = false ]; then
    doctor_issue preview-status-unavailable warning 'Die Fenstervorschau kann den Undo-Status nicht prüfen.' 'Helfer/Installation prüfen; eine ältere laufende Sicherung zuerst zurücknehmen oder ablaufen lassen.'
  fi
  [ "$read_tools" = true ] || doctor_issue clipboard-read-tool-missing warning 'Das Lesewerkzeug dieses Clipboard-Backends fehlt.' 'Unter X11 xclip, unter Wayland wl-clipboard installieren; unter macOS pbpaste/PATH prüfen.'
  case "$diagnosis" in
    ok) ;;
    undo-helper-missing) doctor_issue "$diagnosis" error 'Der Undo-Helfer fehlt oder ist nicht ausführbar.' 'install.sh ausführen oder die vollständige App verwenden.' ;;
    python-missing|python-unsupported) doctor_issue "$diagnosis" error 'Linux-Undo benötigt Python 3.8 oder neuer.' 'Einen unterstützten Python-3-Interpreter im PATH bereitstellen.' ;;
    x11-libraries-missing) doctor_issue "$diagnosis" error 'libX11 oder libXfixes fehlt oder lässt sich nicht laden.' 'Die Laufzeitbibliotheken libX11 und libXfixes der Distribution installieren.' ;;
    x11-session-missing) doctor_issue "$diagnosis" warning 'Es ist keine X11-Sitzung angegeben.' 'In der grafischen Sitzung starten; für Datei/stdin ist keine Sitzung nötig.' ;;
    x11-connect-failed) doctor_issue "$diagnosis" warning 'Die angegebene X11-Sitzung ist nicht erreichbar.' 'DISPLAY und die Sitzungsberechtigung im Terminal der grafischen Sitzung prüfen.' ;;
    x11-xfixes-missing) doctor_issue "$diagnosis" warning 'Der X11-Server bietet das für Undo nötige XFixes nicht an.' 'Einen X11-Server mit XFixes verwenden; Datei/stdin bleibt verfügbar.' ;;
    wayland-runtime-missing) doctor_issue "$diagnosis" warning 'Das Wayland-Sitzungsverzeichnis fehlt.' 'Im Terminal der Wayland-Sitzung starten; WAYLAND_DISPLAY und XDG_RUNTIME_DIR prüfen.' ;;
    wayland-connect-failed) doctor_issue "$diagnosis" warning 'Die Wayland-Sitzung ist nicht erreichbar.' 'WAYLAND_DISPLAY und XDG_RUNTIME_DIR in der grafischen Sitzung prüfen.' ;;
    wayland-data-control-missing) doctor_issue "$diagnosis" warning 'Der Compositor bietet kein unterstütztes Data-Control-Protokoll.' 'Einen Compositor mit ext_data_control_manager_v1 oder zwlr_data_control_manager_v1 verwenden; Datei/stdin funktioniert unabhängig davon.' ;;
    wayland-seat-unsupported) doctor_issue "$diagnosis" warning 'Wayland-Undo benötigt genau einen Seat.' 'Eine Sitzung mit genau einem Seat verwenden; Datei/stdin bleibt verfügbar.' ;;
    runtime-unsafe) doctor_issue "$diagnosis" error 'Das Sitzungsverzeichnis ist nicht privat oder nicht zugänglich.' 'XDG_RUNTIME_DIR der eigenen grafischen Sitzung verwenden; Eigentümer und Modus 0700 prüfen.' ;;
    macos-session-missing) doctor_issue "$diagnosis" warning 'Für diesen Benutzer ist keine aktive macOS-Konsolensitzung erkennbar.' 'In der angemeldeten grafischen Sitzung starten; Datei/stdin funktioniert unabhängig davon.' ;;
    local-security-unsupported) doctor_issue "$diagnosis" error 'Sichere lokale Undo-Verbindungen werden nicht unterstützt.' 'Eine unterstützte Linux-/Python-Laufzeit mit SO_PEERCRED und O_NOFOLLOW verwenden.' ;;
    *) doctor_issue undo-helper-failed error 'Der Undo-Helfer liefert keine gültige Diagnose.' 'Helfer und Laufzeit prüfen oder install.sh erneut ausführen.' ;;
  esac
  if [ "$JSON" -eq 1 ]; then
    printf '},"diagnostics_version":1,"session":{"status":"%s","code":"%s"},"clipboard_tools":{"read":%s,"write":%s},"capabilities":{"plain_input":true,"html_conversion":%s,"rtf_conversion":%s,"clipboard_read":%s,"clipboard_replace":%s},"diagnostics":[%s]}\n' "$session" "$diagnosis" "$read_tools" "$write_tools" "$html" "$rtf_conversion" "$read_ready" "$replace_ready" "$issues"
  fi
}
