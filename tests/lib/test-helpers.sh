#!/usr/bin/env bash
# Gemeinsames, seiteneffektfreies Testgerüst für die vier isolierten
# Shell-Vertragstests. Jeder Aufrufer bekommt ein privates Tempverzeichnis und
# dieselben Plattformattrappen; spezielle Clipboard-Attrappen bleiben im
# jeweiligen Test, weil sie unterschiedliche Zustände modellieren.

init_test_environment() {
  TESTS_DIR="$1"
  PROJECT_ROOT="$(dirname "$TESTS_DIR")"
  TEST_ROOT=$(mktemp -d)
  trap 'rm -rf "$TEST_ROOT"' EXIT
  trap 'exit 130' INT
  trap 'exit 143' TERM
}

copy_install_test_project() {
  local destination="$1"

  mkdir -p "$destination/bin" "$destination/lib" "$destination/helpers"
  cp "$PROJECT_ROOT/install.sh" "$destination/install.sh"
  cp "$PROJECT_ROOT/bin/md-clip" "$destination/bin/md-clip"
  cp "$PROJECT_ROOT/lib/pipeline.sh" "$destination/lib/pipeline.sh"
  cp "$PROJECT_ROOT/helpers/clipboard-html.swift" "$destination/helpers/clipboard-html.swift"
  cp "$PROJECT_ROOT/helpers/clipboard-rtf.swift" "$destination/helpers/clipboard-rtf.swift"
}

write_install_platform_mocks() {
  local destination="$1"

  mkdir -p "$destination"
  cat > "$destination/uname" <<'SH'
#!/bin/sh
printf '%s\n' "${MD_CLIP_TEST_UNAME:-Darwin}"
SH
  cat > "$destination/pandoc" <<'SH'
#!/bin/sh
case "${1:-}" in
  --version) printf 'pandoc %s\n' "${MD_CLIP_TEST_PANDOC_VERSION:-3.9.0.2}" ;;
  --list-input-formats) printf '%b' "${MD_CLIP_TEST_PANDOC_FORMATS:-html\nrtf\n}" ;;
  *) exit 0 ;;
esac
SH
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
