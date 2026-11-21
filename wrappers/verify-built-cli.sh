#!/usr/bin/env bash
# Rauchprobe für die gerade gebaute CLI.

verify_trusted_build_cli() {
  local source_cli="$1"
  local bundled_cli="$2"
  local expected_version="$3"
  local version_output actual_version

  # Ein lokaler Build ist noch nicht signiert. Deshalb darf der allgemeine
  # Bundle-Pruefer das darin enthaltene Skript nicht blind ausfuehren. Hier
  # kennen wir dagegen Quelle und Ziel desselben Build-Laufs und binden beide
  # erst bytegenau aneinander, bevor wir den eingebetteten Befehl starten.
  if ! cmp -s "$source_cli" "$bundled_cli"; then
    echo "FEHLER: Eingebettete CLI stimmt nicht mit bin/md-clip ueberein." >&2
    return 65
  fi
  if ! bash -n "$bundled_cli"; then
    echo "FEHLER: Eingebettete CLI hat einen Syntaxfehler." >&2
    return 65
  fi
  if ! version_output="$("$bundled_cli" --version)"; then
    echo "FEHLER: Eingebettete CLI laesst sich nicht ausfuehren." >&2
    return 65
  fi
  actual_version="${version_output%%$'\n'*}"
  if [ "$actual_version" != "md-clip $expected_version" ]; then
    echo "FEHLER: Eingebettete CLI meldet '$actual_version' statt 'md-clip $expected_version'." >&2
    return 65
  fi
}
