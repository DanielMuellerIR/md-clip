#!/usr/bin/env bash
# Plain-Text muss bytegenau durch stdout und --replace laufen.

set -euo pipefail

TESTS_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
PROJECT_ROOT="$(dirname "$TESTS_DIR")"
TEST_ROOT=$(mktemp -d)
trap 'rm -rf "$TEST_ROOT"' EXIT INT TERM

mkdir -p "$TEST_ROOT/runtime" "$TEST_ROOT/fake-bin"
cp "$PROJECT_ROOT/bin/md-clip" "$TEST_ROOT/runtime/md-clip"
cp "$PROJECT_ROOT/lib/pipeline.sh" "$TEST_ROOT/runtime/pipeline.sh"

# Dependency-Check im Bundle-Layout erfüllen; Plain greift nie auf diese
# Helper zu, aber ein sauberer Bundle-Start verlangt ihre Existenz.
printf '#!/bin/sh\nexit 1\n' > "$TEST_ROOT/runtime/clipboard-html"
printf '#!/bin/sh\nexit 1\n' > "$TEST_ROOT/runtime/clipboard-rtf"
chmod +x "$TEST_ROOT/runtime/"*

# Clipboard-Attrappen für ALLE drei Plattform-Wege. Welchen md-clip nimmt,
# entscheidet es selbst über `uname -s` und WAYLAND_DISPLAY — der Test schreibt
# ihm das bewusst nicht vor, sondern prüft den Weg, der hier wirklich läuft.
# Ohne die Linux-Attrappen wäre die Bytegenauigkeits-Garantie dort unbewiesen.
cat > "$TEST_ROOT/fake-bin/pbpaste" <<'SH'
#!/bin/sh
exec /bin/cat "$MD_CLIP_TEST_INPUT"
SH
cat > "$TEST_ROOT/fake-bin/pbcopy" <<'SH'
#!/bin/sh
exec /bin/cat > "$MD_CLIP_TEST_OUTPUT"
SH
# xclip macht Lesen und Schreiben im selben Befehl; -out/-o liest, -in/-i schreibt.
cat > "$TEST_ROOT/fake-bin/xclip" <<'SH'
#!/bin/sh
mode=out
for arg in "$@"; do
  case "$arg" in
    -in|-i)   mode=in ;;
    -out|-o)  mode=out ;;
  esac
done
if [ "$mode" = "in" ]; then
  exec /bin/cat > "$MD_CLIP_TEST_OUTPUT"
fi
exec /bin/cat "$MD_CLIP_TEST_INPUT"
SH
cat > "$TEST_ROOT/fake-bin/wl-paste" <<'SH'
#!/bin/sh
exec /bin/cat "$MD_CLIP_TEST_INPUT"
SH
cat > "$TEST_ROOT/fake-bin/wl-copy" <<'SH'
#!/bin/sh
exec /bin/cat > "$MD_CLIP_TEST_OUTPUT"
SH
chmod +x "$TEST_ROOT/fake-bin/"*

export PATH="$TEST_ROOT/fake-bin:$PATH"

check_case() {
  local name="$1"
  local input="$2"
  local stdout_file="$TEST_ROOT/${name}.stdout"
  local clipboard_file="$TEST_ROOT/${name}.clipboard"

  export MD_CLIP_TEST_INPUT="$input"
  export MD_CLIP_TEST_OUTPUT="$clipboard_file"

  "$TEST_ROOT/runtime/md-clip" --plain --quiet > "$stdout_file"
  cmp "$input" "$stdout_file"

  "$TEST_ROOT/runtime/md-clip" --plain --replace --quiet
  cmp "$input" "$clipboard_file"
  printf '✓ plain-%s\n' "$name"
}

printf 'ohne Newline' > "$TEST_ROOT/none.input"
printf 'ein Newline\n' > "$TEST_ROOT/one.input"
printf 'mehrere Newlines\n\n\n' > "$TEST_ROOT/many.input"
printf '\n\n' > "$TEST_ROOT/only-newlines.input"
: > "$TEST_ROOT/empty.input"

check_case none "$TEST_ROOT/none.input"
check_case one "$TEST_ROOT/one.input"
check_case many "$TEST_ROOT/many.input"
check_case only-newlines "$TEST_ROOT/only-newlines.input"

export MD_CLIP_TEST_INPUT="$TEST_ROOT/empty.input"
export MD_CLIP_TEST_OUTPUT="$TEST_ROOT/empty.clipboard"
if "$TEST_ROOT/runtime/md-clip" --plain --quiet > "$TEST_ROOT/empty.stdout" 2>/dev/null; then
  echo "✗ plain-empty: leeres Clipboard wurde akzeptiert" >&2
  exit 1
fi
printf '✓ plain-empty (Exit 1)\n'
