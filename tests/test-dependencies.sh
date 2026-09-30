#!/usr/bin/env bash
# Ein vorhandenes, aber zu altes pandoc ohne RTF-Reader muss klar scheitern.

set -euo pipefail

TESTS_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=lib/test-helpers.sh
source "$TESTS_DIR/lib/test-helpers.sh"
init_test_environment "$TESTS_DIR"

RUNTIME="$TEST_ROOT/runtime"
FAKE_BIN="$TEST_ROOT/fake-bin"
mkdir -p "$RUNTIME" "$FAKE_BIN"
cp "$PROJECT_ROOT/bin/md-clip" "$RUNTIME/md-clip"
cp "$PROJECT_ROOT/lib/pipeline.sh" "$RUNTIME/pipeline.sh"
cp "$PROJECT_ROOT/lib/tidy-markdown.pl" "$RUNTIME/tidy-markdown.pl"
cp "$PROJECT_ROOT/lib/tables.lua" "$RUNTIME/tables.lua"

cat > "$RUNTIME/xclip" <<'SH'
#!/bin/sh
exit 0
SH
export MD_CLIP_TEST_UNAME=Linux
export MD_CLIP_TEST_PANDOC_VERSION=2.9.2.1
export MD_CLIP_TEST_PANDOC_FORMATS='html\nmarkdown\n'
write_install_platform_mocks "$FAKE_BIN"
# md-clip stellt sein eigenes Verzeichnis vorn in den PATH — die Attrappe
# muss deshalb auch dort liegen, sonst befragt das Produkt eine andere.
write_pandoc_mock "$RUNTIME"
chmod +x "$RUNTIME/"*

export PATH="$FAKE_BIN:/usr/bin:/bin"
if "$RUNTIME/md-clip" --stdin --from rtf --quiet <<< '{\rtf1 text}' > "$TEST_ROOT/product.out" 2> "$TEST_ROOT/product.err"; then
  echo "✗ Produkt akzeptiert pandoc ohne RTF-Reader" >&2
  exit 1
fi
grep -Fq 'Pandoc unterstützt das Eingabeformat RTF nicht' "$TEST_ROOT/product.err"
echo "✓ Produkt lehnt pandoc ohne RTF-Reader ab"

PROJECT_COPY="$TEST_ROOT/project"
copy_install_test_project "$PROJECT_COPY"
mkdir -p "$TEST_ROOT/prefix"

if INSTALL_PREFIX="$TEST_ROOT/prefix" "$PROJECT_COPY/install.sh" > "$TEST_ROOT/install.out" 2>&1; then
  echo "✗ Installer akzeptiert pandoc ohne RTF-Reader" >&2
  exit 1
fi
grep -Fq 'unterstützt das Eingabeformat RTF nicht' "$TEST_ROOT/install.out"
echo "✓ Installer lehnt pandoc ohne RTF-Reader ab"

# --- Zweiter Fall: pandoc MIT RTF-Reader, aber ohne `--sandbox` (< 2.15) ---
# Genau diese Fassung bestand die alte Prüfung und scheiterte erst bei der
# eigentlichen Konvertierung mit „Unknown option --sandbox" (Exit 3).
export MD_CLIP_TEST_PANDOC_VERSION=2.14.2
export MD_CLIP_TEST_PANDOC_FORMATS='html\nrtf\nmarkdown\n'
export MD_CLIP_TEST_PANDOC_SANDBOX=0
write_install_platform_mocks "$FAKE_BIN"
write_pandoc_mock "$RUNTIME"

if "$RUNTIME/md-clip" --stdin --from html --quiet <<< '<p>text</p>' > "$TEST_ROOT/product2.out" 2> "$TEST_ROOT/product2.err"; then
  echo "✗ Produkt akzeptiert pandoc ohne --sandbox" >&2
  exit 1
fi
grep -Fq 'kennt die Option --sandbox nicht' "$TEST_ROOT/product2.err"
echo "✓ Produkt lehnt pandoc ohne --sandbox ab"

PROJECT_COPY2="$TEST_ROOT/project2"
copy_install_test_project "$PROJECT_COPY2"
mkdir -p "$TEST_ROOT/prefix2"

if INSTALL_PREFIX="$TEST_ROOT/prefix2" "$PROJECT_COPY2/install.sh" > "$TEST_ROOT/install2.out" 2>&1; then
  echo "✗ Installer akzeptiert pandoc ohne --sandbox" >&2
  exit 1
fi
grep -Fq 'kennt die Option --sandbox nicht' "$TEST_ROOT/install2.out"
echo "✓ Installer lehnt pandoc ohne --sandbox ab"

# Der vom Aufrufer gewählte Linux-PATH muss auch beim Konverter ankommen.
# Mit einem Bundle-Konverter bleibt die Prüfung auf macOS unabhängig von
# tatsächlich installierten Homebrew-Binaries.
PATH_RUNTIME="$TEST_ROOT/path-runtime"
mkdir -p "$PATH_RUNTIME"
PATH_RUNTIME="$(cd "$PATH_RUNTIME" && pwd -P)"
cp "$RUNTIME/md-clip" "$RUNTIME/pipeline.sh" "$RUNTIME/tidy-markdown.pl" "$RUNTIME/tables.lua" "$PATH_RUNTIME/"
cat > "$PATH_RUNTIME/pandoc" <<'MOCK'
#!/bin/sh
printf '%s\n' "$PATH" > "$MD_CLIP_PATH_CAPTURE"
printf 'pandoc 99.1\n'
MOCK
chmod +x "$PATH_RUNTIME/pandoc"
export MD_CLIP_PATH_CAPTURE="$TEST_ROOT/converter-path"
CALLER_PATH="$FAKE_BIN:/usr/bin:/bin"
for backend in macos x11 wayland; do
  case "$backend" in
    macos)
      export MD_CLIP_TEST_UNAME=Darwin
      export WAYLAND_DISPLAY=""
      expected_path="$PATH_RUNTIME:/opt/homebrew/bin:/usr/local/bin:$CALLER_PATH" ;;
    x11)
      export MD_CLIP_TEST_UNAME=Linux
      export WAYLAND_DISPLAY=""
      expected_path="$PATH_RUNTIME:$CALLER_PATH" ;;
    wayland)
      export MD_CLIP_TEST_UNAME=Linux
      export WAYLAND_DISPLAY=isolated-wayland
      expected_path="$PATH_RUNTIME:$CALLER_PATH" ;;
  esac
  PATH="$CALLER_PATH" "$PATH_RUNTIME/md-clip" --version > "$TEST_ROOT/path-version"
  [ "$(cat "$MD_CLIP_PATH_CAPTURE")" = "$expected_path" ]
  grep -Fq 'pandoc  99.1 (gebundelt)' "$TEST_ROOT/path-version"
  echo "✓ Konverter-PATH und Bundle-Vorrang: $backend"
done

mv "$PATH_RUNTIME/pandoc" "$FAKE_BIN/pandoc"
for backend in x11 wayland; do
  export MD_CLIP_TEST_UNAME=Linux
  if [ "$backend" = wayland ]; then export WAYLAND_DISPLAY=isolated-wayland
  else export WAYLAND_DISPLAY=""; fi
  PATH="$CALLER_PATH" "$PATH_RUNTIME/md-clip" --version > "$TEST_ROOT/path-version"
  [ "$(cat "$MD_CLIP_PATH_CAPTURE")" = "$CALLER_PATH" ]
  grep -Fq 'pandoc  99.1 (System)' "$TEST_ROOT/path-version"
  echo "✓ Linux verwendet pandoc aus dem Aufrufer-PATH: $backend"
done
