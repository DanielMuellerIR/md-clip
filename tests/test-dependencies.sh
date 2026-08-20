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

cat > "$RUNTIME/pandoc" <<'SH'
#!/bin/sh
case "${1:-}" in
  --version) echo 'pandoc 2.9.2.1' ;;
  --list-input-formats) printf 'html\nmarkdown\n' ;;
  *) exit 0 ;;
esac
SH
cat > "$RUNTIME/xclip" <<'SH'
#!/bin/sh
exit 0
SH
export MD_CLIP_TEST_UNAME=Linux
export MD_CLIP_TEST_PANDOC_VERSION=2.9.2.1
export MD_CLIP_TEST_PANDOC_FORMATS='html\nmarkdown\n'
write_install_platform_mocks "$FAKE_BIN"
chmod +x "$RUNTIME/"*

export PATH="$FAKE_BIN:/usr/bin:/bin"
if "$RUNTIME/md-clip" --plain --quiet > "$TEST_ROOT/product.out" 2> "$TEST_ROOT/product.err"; then
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
