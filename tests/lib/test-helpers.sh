#!/usr/bin/env bash
# Gemeinsames, seiteneffektfreies Testgerüst für die vier isolierten
# Shell-Vertragstests. Jeder Aufrufer bekommt ein privates Tempverzeichnis und
# dieselben Plattformattrappen; spezielle Clipboard-Attrappen bleiben im
# jeweiligen Test, weil sie unterschiedliche Zustände modellieren.

# Meldet, welche Zusicherung gescheitert ist. Ohne das beendet `set -e` den
# Lauf wortlos: Auf dem Bildschirm stehen dann nur die bis dahin bestandenen
# Prüfungen und ein Exit-Code — bei den knapp sechzig stummen grep-Verträgen in
# tests/test-wrapper-safety.sh sieht niemand mehr, WAS regressiert ist. Der
# ERR-Trap unten nennt Datei, Zeile und Wortlaut der Prüfung.
report_failed_check() {
  local status=$?
  local line="$1"

  # Bash führt den ERR-Trap auch bei abgeschaltetem `set -e` aus. Die Tests
  # schalten es aber genau dort ab, wo sie einen Fehlschlag ERWARTEN und selbst
  # auswerten — dort wäre die Meldung falsch. Ohne das `e` in $- also schweigen.
  case "$-" in
    *e*) ;;
    *)   return 0 ;;
  esac

  printf '✗ Zusicherung in %s:%s fehlgeschlagen (Exit %s):\n' \
    "${TEST_SCRIPT##*/}" "$line" "$status" >&2
  sed -n "${line}p" "$TEST_SCRIPT" 2>/dev/null | sed 's/^/    /' >&2
}

init_test_environment() {
  TESTS_DIR="$1"
  PROJECT_ROOT="$(dirname "$TESTS_DIR")"
  TEST_ROOT=$(mktemp -d)
  # BASH_SOURCE[1] ist das aufrufende Testskript — BASH_SOURCE[0] wäre diese
  # Hilfsdatei und damit die falsche Datei für die Zeilenangabe.
  TEST_SCRIPT="${BASH_SOURCE[1]}"
  trap 'rm -rf "$TEST_ROOT"' EXIT
  trap 'exit 130' INT
  trap 'exit 143' TERM
  trap 'report_failed_check "$LINENO"' ERR
}

copy_install_test_project() {
  local destination="$1"

  mkdir -p "$destination/bin" "$destination/lib" "$destination/helpers"
  cp "$PROJECT_ROOT/install.sh" "$destination/install.sh"
  cp "$PROJECT_ROOT/bin/md-clip" "$destination/bin/md-clip"
  cp "$PROJECT_ROOT/lib/pipeline.sh" "$destination/lib/pipeline.sh"
  cp "$PROJECT_ROOT/lib/tidy-markdown.pl" "$destination/lib/tidy-markdown.pl"
  cp "$PROJECT_ROOT/lib/tables.lua" "$destination/lib/tables.lua"
  cp "$PROJECT_ROOT/helpers/clipboard-html.swift" "$destination/helpers/clipboard-html.swift"
  cp "$PROJECT_ROOT/helpers/clipboard-rtf.swift" "$destination/helpers/clipboard-rtf.swift"
}

# Schreibt die pandoc-Attrappe. Sie liegt an ZWEI Orten: im fake-bin und im
# Laufzeitverzeichnis neben `md-clip` — das Produkt stellt sein eigenes
# Verzeichnis vorn in den PATH (bin/md-clip, `export PATH="$SCRIPT_DIR:$PATH"`),
# eine nur im fake-bin gepflegte Attrappe wuerde also nie befragt.
write_pandoc_mock() {
  local destination="$1"

  mkdir -p "$destination"
  # Die Attrappe muss unbekannte Optionen ABLEHNEN — sonst besteht ein zu
  # altes pandoc jede Fähigkeitsprüfung und der Fehler zeigt sich erst beim
  # Nutzer. MD_CLIP_TEST_PANDOC_SANDBOX=0 spielt genau das nach: ein pandoc
  # vor 2.15, das `--sandbox` nicht kennt.
  cat > "$destination/pandoc" <<'SH'
#!/bin/sh
for arg in "$@"; do
  case "$arg" in
    --sandbox)
      if [ "${MD_CLIP_TEST_PANDOC_SANDBOX:-1}" != "1" ]; then
        echo "Unknown option --sandbox." >&2
        exit 2
      fi
      ;;
    --*)
      case "$arg" in
        --version|--list-input-formats|--wrap=*|--from=*|--to=*|--lua-filter=*) ;;
        *) echo "Unknown option $arg." >&2; exit 2 ;;
      esac
      ;;
  esac
done
case "${1:-}" in
  --version) printf 'pandoc %s\n' "${MD_CLIP_TEST_PANDOC_VERSION:-3.9.0.2}" ;;
  --list-input-formats) printf '%b' "${MD_CLIP_TEST_PANDOC_FORMATS:-html\nrtf\n}" ;;
  *) exit 0 ;;
esac
SH
  chmod +x "$destination/pandoc"
}

write_install_platform_mocks() {
  local destination="$1"

  mkdir -p "$destination"
  cat > "$destination/uname" <<'SH'
#!/bin/sh
printf '%s\n' "${MD_CLIP_TEST_UNAME:-Darwin}"
SH
  write_pandoc_mock "$destination"
  cat > "$destination/swiftc" <<'SH'
#!/bin/sh
output=""
while [ "$#" -gt 0 ]; do
  if [ "$1" = "-o" ]; then
    shift
    output="$1"
  fi
  shift
done
printf '#!/bin/sh\nexit 0\n' > "$output"
chmod +x "$output"
SH
  for tool in xclip wl-paste wl-copy; do
    cat > "$destination/$tool" <<'SH'
#!/bin/sh
exit 0
SH
  done
  chmod +x "$destination/"*
}
