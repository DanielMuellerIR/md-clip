#!/usr/bin/env bash
# Ein vorhandenes, aber zu altes pandoc ohne RTF-Reader muss klar scheitern.

set -euo pipefail

TESTS_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
PROJECT_ROOT="$(dirname "$TESTS_DIR")"
TEST_ROOT=$(mktemp -d)
trap 'rm -rf "$TEST_ROOT"' EXIT INT TERM

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
cat > "$FAKE_BIN/uname" <<'SH'
#!/bin/sh
echo Linux
SH
cat > "$FAKE_BIN/pandoc" <<'SH'
#!/bin/sh
case "${1:-}" in
  --version) echo 'pandoc 2.9.2.1' ;;
  --list-input-formats) printf 'html\nmarkdown\n' ;;
  *) exit 0 ;;
esac
SH
cat > "$FAKE_BIN/xclip" <<'SH'
#!/bin/sh
exit 0
SH
cat > "$FAKE_BIN/wl-paste" <<'SH'
#!/bin/sh
exit 0
SH
cat > "$FAKE_BIN/wl-copy" <<'SH'
#!/bin/sh
exit 0
SH
chmod +x "$RUNTIME/"* "$FAKE_BIN/"*

export PATH="$FAKE_BIN:/usr/bin:/bin"
if "$RUNTIME/md-clip" --plain --quiet > "$TEST_ROOT/product.out" 2> "$TEST_ROOT/product.err"; then
  echo "✗ Produkt akzeptiert pandoc ohne RTF-Reader" >&2
  exit 1
fi
grep -Fq 'Pandoc unterstützt das Eingabeformat RTF nicht' "$TEST_ROOT/product.err"
echo "✓ Produkt lehnt pandoc ohne RTF-Reader ab"

PROJECT_COPY="$TEST_ROOT/project"
mkdir -p "$PROJECT_COPY/bin" "$PROJECT_COPY/lib" "$PROJECT_COPY/helpers" "$TEST_ROOT/prefix"
cp "$PROJECT_ROOT/install.sh" "$PROJECT_COPY/install.sh"
cp "$PROJECT_ROOT/bin/md-clip" "$PROJECT_COPY/bin/md-clip"
cp "$PROJECT_ROOT/lib/pipeline.sh" "$PROJECT_COPY/lib/pipeline.sh"
cp "$PROJECT_ROOT/helpers/clipboard-html.swift" "$PROJECT_COPY/helpers/clipboard-html.swift"
cp "$PROJECT_ROOT/helpers/clipboard-rtf.swift" "$PROJECT_COPY/helpers/clipboard-rtf.swift"

if INSTALL_PREFIX="$TEST_ROOT/prefix" "$PROJECT_COPY/install.sh" > "$TEST_ROOT/install.out" 2>&1; then
  echo "✗ Installer akzeptiert pandoc ohne RTF-Reader" >&2
  exit 1
fi
grep -Fq 'unterstützt das Eingabeformat RTF nicht' "$TEST_ROOT/install.out"
echo "✓ Installer lehnt pandoc ohne RTF-Reader ab"
