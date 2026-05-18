#!/usr/bin/env bash
# tests/run-tests.sh — Vergleicht den Output der md-clip-Pipeline gegen
# die Expected-Files in tests/fixtures/.
#
# Strategie: md-clip selbst liest das Clipboard und kann hier nicht getestet
# werden ohne pbcopy/pbpaste-Mocking. Stattdessen testen wir die internen
# Pipelines (preprocess + clean + pandoc bzw. textutil + clean + pandoc)
# direkt mit den Fixture-Dateien als stdin.
#
# Wenn ein Test fehlschlägt, zeigen wir das Diff zur erwarteten Ausgabe.

set -euo pipefail

# Projekt-Root: das Verzeichnis ÜBER tests/.
TESTS_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
PROJECT_ROOT="$(dirname "$TESTS_DIR")"
FIXTURES="$TESTS_DIR/fixtures"

cd "$PROJECT_ROOT"

# Wir laden die Funktionen aus bin/md-clip, indem wir das Skript sourcen —
# aber das würde die Hauptlogik mit ausführen. Sauberer: die Funktionen
# hier dupliziert ablegen. Wenn sich die Funktionen in bin/md-clip ändern,
# muss diese Datei mitgepflegt werden. Trade-off bewusst akzeptiert.

PANDOC_OPTS=(-f html -t gfm-raw_html --wrap=none)

preprocess_claude_desktop() {
  perl -0pe 's{<div\s+data-line="[^"]*"[^>]*>(.*?)</div>}{$1\n}gs' \
    | perl -0pe '
        s{(<pre[^>]*>.*?</pre>)}{
          my $block = $1;
          $block =~ s{</?div[^>]*>}{}g;
          $block;
        }gse' \
    | perl -0pe 's/\s+style="[^"]*"//g' \
    | perl -0pe 's/\s+data-[a-z-]+="[^"]*"//g'
}

clean_html() {
  sed -E 's/<span[^>]*>([^<]*)<\/span>/\1/g' \
    | sed -E 's/<span[^>]*>([^<]*)<\/span>/\1/g'
}

# Zähler für Statistik am Ende.
TOTAL=0
PASSED=0
FAILED=0

# run_test: Vergleicht $actual mit dem Inhalt der erwarteten Datei.
# Args: 1=Test-Name, 2=actual-Output (mehrzeilig), 3=expected-Datei
run_test() {
  local name="$1"
  local actual="$2"
  local expected_file="$3"

  TOTAL=$((TOTAL + 1))

  if [ ! -f "$expected_file" ]; then
    echo "✗ $name — expected-Datei fehlt: $expected_file"
    FAILED=$((FAILED + 1))
    return
  fi

  local expected
  expected=$(cat "$expected_file")

  # Trailing-Newlines normalisieren: actual hat keinen Trailing-Newline,
  # expected-Files haben oft einen. Wir vergleichen ohne.
  if [ "$actual" = "$expected" ] || [ "${actual}" = "${expected%$'\n'}" ]; then
    echo "✓ $name"
    PASSED=$((PASSED + 1))
  else
    echo "✗ $name"
    echo "  --- Diff (erwartet vs. tatsächlich) ---"
    diff <(printf '%s' "$expected") <(printf '%s' "$actual") | sed 's/^/    /' || true
    FAILED=$((FAILED + 1))
  fi
}

echo "==> md-clip Tests"
echo

# --- Test 1: Claude-Desktop-Code-Block ---
# HTML mit Subgrid-Divs → muss Code-Zeilen mit Newlines + Markdown-Restformat liefern.
actual=$(cat "$FIXTURES/claude-desktop-codeblock.html" \
  | preprocess_claude_desktop \
  | clean_html \
  | pandoc "${PANDOC_OPTS[@]}")
run_test "claude-desktop-codeblock (HTML mit Subgrid-Divs)" \
  "$actual" \
  "$FIXTURES/claude-desktop-codeblock.expected.md"

# --- Test 2: Einfacher HTML-Artikel ---
# Repräsentativ für Browser-Copy (Safari, Chrome).
actual=$(cat "$FIXTURES/safari-article.html" \
  | preprocess_claude_desktop \
  | clean_html \
  | pandoc "${PANDOC_OPTS[@]}")
run_test "safari-article (Browser-Copy)" \
  "$actual" \
  "$FIXTURES/safari-article.expected.md"

# --- Test 3: RTF aus Word/Pages/TextEdit ---
# Über textutil zu HTML, dann normaler Pfad.
actual=$(cat "$FIXTURES/word-rtf.rtf" \
  | textutil -convert html -format rtf -stdin -stdout \
  | clean_html \
  | pandoc "${PANDOC_OPTS[@]}")
run_test "word-rtf (RTF via textutil)" \
  "$actual" \
  "$FIXTURES/word-rtf.expected.md"

# --- Zusammenfassung ---
echo
echo "==> $PASSED/$TOTAL Tests bestanden"

# Exit-Code: 0 bei allen grün, 1 sobald einer rot.
[ "$FAILED" -eq 0 ]
