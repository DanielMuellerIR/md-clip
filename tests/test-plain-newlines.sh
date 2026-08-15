#!/usr/bin/env bash
# Plain-Text muss bytegenau durch stdout und --replace laufen; angrenzende
# CLI-Verträge werden mit denselben drei Plattform-Attrappen geprüft.

set -euo pipefail

TESTS_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
PROJECT_ROOT="$(dirname "$TESTS_DIR")"
TEST_ROOT=$(mktemp -d)
trap 'rm -rf "$TEST_ROOT"' EXIT INT TERM

mkdir -p "$TEST_ROOT/runtime" "$TEST_ROOT/fake-bin"
cp "$PROJECT_ROOT/bin/md-clip" "$TEST_ROOT/runtime/md-clip"
cp "$PROJECT_ROOT/lib/pipeline.sh" "$TEST_ROOT/runtime/pipeline.sh"

# Dependency-Check im Bundle-Layout erfüllen. Für die Plain-Fälle melden die
# Helper keinen Rich-Flavor; der MSO-Fall unten kann ihnen gezielt Dateien
# geben und dadurch denselben Auto-Pfad wie das Produkt prüfen.
cat > "$TEST_ROOT/runtime/clipboard-html" <<'SH'
#!/bin/sh
[ -n "${MD_CLIP_TEST_HTML:-}" ] || exit 1
exec /bin/cat "$MD_CLIP_TEST_HTML"
SH
cat > "$TEST_ROOT/runtime/clipboard-rtf" <<'SH'
#!/bin/sh
[ -n "${MD_CLIP_TEST_RTF:-}" ] || exit 1
exec /bin/cat "$MD_CLIP_TEST_RTF"
SH
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
target=""
while [ "$#" -gt 0 ]; do
  case "$1" in
    -in|-i)   mode=in ;;
    -out|-o)  mode=out ;;
    -target)  shift; target="${1:-}" ;;
  esac
  shift
done
if [ "$mode" = "in" ]; then
  exec /bin/cat > "$MD_CLIP_TEST_OUTPUT"
fi
case "$target" in
  text/html)                exec /bin/cat "$MD_CLIP_TEST_HTML" ;;
  text/rtf|application/rtf) exec /bin/cat "$MD_CLIP_TEST_RTF" ;;
  *)                        exec /bin/cat "$MD_CLIP_TEST_INPUT" ;;
esac
SH
cat > "$TEST_ROOT/fake-bin/wl-paste" <<'SH'
#!/bin/sh
type=""
while [ "$#" -gt 0 ]; do
  if [ "$1" = "--type" ]; then
    shift
    type="${1:-}"
  fi
  shift
done
case "$type" in
  text/html)                exec /bin/cat "$MD_CLIP_TEST_HTML" ;;
  text/rtf|application/rtf) exec /bin/cat "$MD_CLIP_TEST_RTF" ;;
  *)                        exec /bin/cat "$MD_CLIP_TEST_INPUT" ;;
esac
SH
cat > "$TEST_ROOT/fake-bin/wl-copy" <<'SH'
#!/bin/sh
exec /bin/cat > "$MD_CLIP_TEST_OUTPUT"
SH
cat > "$TEST_ROOT/fake-bin/uname" <<'SH'
#!/bin/sh
printf '%s\n' "${MD_CLIP_TEST_UNAME:-$(/usr/bin/uname -s)}"
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

# --quiet gewinnt auch dann, wenn --verbose zusätzlich gesetzt ist. Das ist
# der dokumentierte Vertrag für maschinelle Aufrufer; geprüft werden alle drei
# Plattform-Wege mit denselben Attrappen.
check_quiet_verbose() {
  local name="$1"
  local platform="$2"
  local wayland="$3"
  local stderr_file="$TEST_ROOT/${name}.stderr"

  MD_CLIP_TEST_UNAME="$platform" WAYLAND_DISPLAY="$wayland" \
    "$TEST_ROOT/runtime/md-clip" --plain --quiet --verbose \
    > /dev/null 2> "$stderr_file"
  [ ! -s "$stderr_file" ]
  printf '✓ quiet-verbose-%s\n' "$name"
}

export MD_CLIP_TEST_INPUT="$TEST_ROOT/none.input"
if [ "$(/usr/bin/uname -s)" = "Darwin" ]; then
  # Der Mac kann zusätzlich beide Linux-Ränder mit C.UTF-8 und Attrappen
  # fahren. Umgekehrt besitzt ein schlankes Linux-System die von macOS
  # verlangte Locale en_US.UTF-8 nicht und würde schon beim Export warnen.
  check_quiet_verbose macos Darwin ""
fi
check_quiet_verbose x11 Linux ""
check_quiet_verbose wayland Linux wayland-test

# Nach `--` bleiben es Positionsargumente. md-clip akzeptiert keine und muss
# deshalb mit dem dokumentierten Argumentfehler abbrechen, statt sie zu
# ignorieren und das Clipboard zu verarbeiten.
set +e
MD_CLIP_TEST_UNAME=Linux WAYLAND_DISPLAY="" \
  "$TEST_ROOT/runtime/md-clip" --quiet -- unerwartet \
  > "$TEST_ROOT/positional.stdout" 2> "$TEST_ROOT/positional.stderr"
positional_status=$?
set -e
[ "$positional_status" -eq 2 ]
grep -Fq 'Unerwartetes Argument: unerwartet' "$TEST_ROOT/positional.stderr"
printf '✓ positionsargument-nach-doppelstrich (Exit 2)\n'

# Word-Fallback: Zehn mso-Marker in EINER HTML-Zeile müssen reichen, um bei
# vorhandenem RTF den saubereren Flavor zu wählen. Der alte grep-c-Zähler sah
# hier nur eine Trefferzeile. Jeder Plattformweg liest dieselben beiden
# Testdateien über seine eigene Attrappe.
printf '%s' '<p>HTML path</p><!-- mso-a mso-b mso-c mso-d mso-e mso-f mso-g mso-h mso-i mso-j -->' \
  > "$TEST_ROOT/mso.html"
printf '%s' '{\rtf1\ansi RTF path}' > "$TEST_ROOT/mso.rtf"
export MD_CLIP_TEST_HTML="$TEST_ROOT/mso.html"
export MD_CLIP_TEST_RTF="$TEST_ROOT/mso.rtf"

check_mso_fallback() {
  local name="$1"
  local platform="$2"
  local wayland="$3"
  local actual

  actual=$(MD_CLIP_TEST_UNAME="$platform" WAYLAND_DISPLAY="$wayland" \
    "$TEST_ROOT/runtime/md-clip" --quiet)
  [ "$actual" = 'RTF path' ]
  printf '✓ mso-rtf-fallback-%s\n' "$name"
}

if [ "$(/usr/bin/uname -s)" = "Darwin" ]; then
  check_mso_fallback macos Darwin ""
fi
check_mso_fallback x11 Linux ""
check_mso_fallback wayland Linux wayland-test
