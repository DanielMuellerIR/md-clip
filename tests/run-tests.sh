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

# Dupliziert aus bin/md-clip — füllt leeren Anker-Text `[](url)` mit der
# Ziel-URL, damit der Link in allen Renderern sichtbar bleibt.
fix_empty_links() {
  perl -0pe 's{(?<!!)\[\s*\]\(\s*(\S+?)(\s+[^)]*)?\)}{ "[$1]($1" . (defined $2 ? $2 : "") . ")" }gex'
}

# Dupliziert aus bin/md-clip — entfernt überflüssige Hard-Break-Backslashes
# an Absatz-/Listengrenzen (auch aus <br><br>). Hard-Breaks in Fließtext
# (z.B. Adressen) bleiben. Siehe bin/md-clip für die ausführliche Doku.
tidy_hard_breaks() {
  perl -0pe '
    s/[ \t]*(?:\\|[ ]{2,})\n(?=[ \t]*(?:[-*+] |\d+[.)] ))/\n/g;
    s/^[ \t]*\\?[ \t]*$//gm;
    s/[ \t]*(?:\\|[ ]{2,})\n(?=[ \t]*\n)/\n/g;
    s/\n{3,}/\n\n/g;
  '
}

# Dupliziert aus bin/md-clip — fasst Google-Classroom-Link-Anhänge zu
# `<li><a href>Titel</a></li>` zusammen, strippt authuser-Tracking und
# Thumbnails. Siehe bin/md-clip für die ausführliche Doku.
preprocess_google_classroom() {
  perl -0777 -pe '
    s{<a\b([^>]*)\bhref="([^"]*)"([^>]*)>(.*?)</a>}{
      my ($pre, $href, $post, $inner) = ($1, $2, $3, $4);
      if ($inner =~ m{classroom\.google\.com/webthumbnail}) {
        my $title = ($inner =~ m{class="[^"]*\bmvRF3b\b[^"]*">(.*?)</div>}s) ? $1 : "";
        $title =~ s/<[^>]+>//g;
        $title =~ s/^\s+|\s+$//g;
        $href =~ s/[?&]authuser=[^&]*//;
        $href =~ s/[?&]$//;
        $title ne "" ? "<li><a href=\"$href\">$title</a></li>"
                     : "<a href=\"$href\"></a>";
      } else {
        $&;
      }
    }gse;
    s{<img[^>]*classroom\.google\.com/webthumbnail[^>]*>}{}gs;
    1 while s{<div\b[^>]*>\s*</div>}{}gs;
    1 while s{</li>(?:\s*</?div[^>]*>\s*)+<li>}{</li><li>}gs;
    s{(?:<li>.*?</li>\s*)+}{my $r = $&; $r =~ s/>\s+</></g; "<ul>$r</ul>"}gse;
  '
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

# --- Test 4: Links mit leerem Anker-Text ---
# <a href="…"></a> → pandoc liefert `[](url)`. fix_empty_links muss den
# leeren []-Teil mit der URL füllen, Titel erhalten, echte Links unberührt.
actual=$(cat "$FIXTURES/empty-link.html" \
  | preprocess_claude_desktop \
  | clean_html \
  | pandoc "${PANDOC_OPTS[@]}" \
  | fix_empty_links \
  | tidy_hard_breaks)
run_test "empty-link (leerer Anker-Text → URL als Text)" \
  "$actual" \
  "$FIXTURES/empty-link.expected.md"

# --- Test 5: Google-Classroom-Link-Anhänge ---
# Anhänge sind <a> die Block-Divs (Titel, URL, Thumbnail) umschließen.
# Erwartung: kompakte Liste `- [Titel](href)`, authuser gestrippt,
# Thumbnails weg, kein leerer `[](url)`.
actual=$(cat "$FIXTURES/google-classroom-links.html" \
  | preprocess_claude_desktop \
  | preprocess_google_classroom \
  | clean_html \
  | pandoc "${PANDOC_OPTS[@]}" \
  | fix_empty_links \
  | tidy_hard_breaks)
run_test "google-classroom-links (Anhänge → Titel-Liste)" \
  "$actual" \
  "$FIXTURES/google-classroom-links.expected.md"

# --- Test 6: <br><br>-Absätze + Listen ---
# <br><br> wird von pandoc zu Hard-Break-Backslash-Müll (`text\` + lone `\`).
# tidy_hard_breaks muss daraus saubere Absätze + Listen machen, ohne
# Hard-Breaks in echtem Fließtext zu zerstören.
actual=$(cat "$FIXTURES/br-paragraphs.html" \
  | preprocess_claude_desktop \
  | clean_html \
  | pandoc "${PANDOC_OPTS[@]}" \
  | fix_empty_links \
  | tidy_hard_breaks)
run_test "br-paragraphs (<br><br> → Absätze ohne Backslash-Müll)" \
  "$actual" \
  "$FIXTURES/br-paragraphs.expected.md"

echo
echo "==> Encoding-Roundtrip-Test"
#
# Dieser Test ist der wichtigste, weil er die einzige Stelle ist, an der
# wir die EFFEKTIVE Nutzer-Erfahrung prüfen — nicht nur die Bytes auf
# stdout, sondern was eine andere App tatsächlich beim Einfügen sieht.
# Hintergrund: pbcopy/pbpaste interpretieren Bytes je nach LC_ALL
# unterschiedlich. Ein Roundtrip-Test, der pbcopy zum Schreiben UND
# pbpaste zum Lesen verwendet (beide in der gleichen falschen Locale),
# kann den Encoding-Bug verstecken, weil sich die Fehler aufheben.
# Daher lesen wir hier über NSPasteboard.string in Swift — das ist die
# echte API, die jede Paste-Konsumenten-App verwendet.
#
# Siehe docs/ENCODING.md für die ausführliche Geschichte.

# Helper bauen, falls nicht da.
LOAD_CLIPBOARD_BIN="$TESTS_DIR/load-clipboard"
LOAD_CLIPBOARD_SRC="$TESTS_DIR/load-clipboard.swift"
if [ ! -x "$LOAD_CLIPBOARD_BIN" ] || [ "$LOAD_CLIPBOARD_SRC" -nt "$LOAD_CLIPBOARD_BIN" ]; then
  swiftc "$LOAD_CLIPBOARD_SRC" -o "$LOAD_CLIPBOARD_BIN"
fi

CLIPBOARD_STRING_BIN="$TESTS_DIR/clipboard-string"
CLIPBOARD_STRING_SRC="$TESTS_DIR/clipboard-string.swift"
if [ ! -x "$CLIPBOARD_STRING_BIN" ] || [ "$CLIPBOARD_STRING_SRC" -nt "$CLIPBOARD_STRING_BIN" ]; then
  swiftc "$CLIPBOARD_STRING_SRC" -o "$CLIPBOARD_STRING_BIN"
fi

# Bestehenden Clipboard-Inhalt als Plain-Text sichern, damit wir am
# Ende restaurieren können. Rich-Flavors gehen verloren — bei einem
# Test-Lauf akzeptabel.
CLIPBOARD_BACKUP="$(mktemp)"
pbpaste > "$CLIPBOARD_BACKUP" 2>/dev/null || true

# Test-Eingabe: drei Kategorien Nicht-ASCII auf einmal — Latin-1-Umlaute
# (ä, ö, ü, ß), 2-Byte-Sonderzeichen (—) und 3-Byte-BMP-Symbole (☤).
# Wer EINE dieser Kategorien verliert, fällt durch.
ENCODING_INPUT='<p>Café über Größen — ☤</p>'
ENCODING_EXPECTED='Café über Größen — ☤'

ENCODING_HTML="$(mktemp).html"
printf '%s' "$ENCODING_INPUT" > "$ENCODING_HTML"

# HTML aufs Clipboard laden (kein --replace nötig — wir setzen direkt).
"$LOAD_CLIPBOARD_BIN" public.html "$ENCODING_HTML" >/dev/null

# Vollständige Kette laufen lassen, --replace schreibt ergebnis ins Clipboard.
"$PROJECT_ROOT/bin/md-clip" --replace --quiet

# Clipboard-Inhalt so lesen, wie eine echte App ihn sieht.
encoding_actual="$("$CLIPBOARD_STRING_BIN")"

if [ "$encoding_actual" = "$ENCODING_EXPECTED" ]; then
  echo "✓ encoding-roundtrip (UTF-8 durchs Clipboard heil geblieben)"
  PASSED=$((PASSED + 1))
else
  echo "✗ encoding-roundtrip"
  echo "  Erwartet:  '$ENCODING_EXPECTED'"
  echo "  Erhalten:  '$encoding_actual'"
  echo "  Erwartete Bytes:"
  printf '%s' "$ENCODING_EXPECTED" | xxd | sed 's/^/    /'
  echo "  Erhaltene Bytes:"
  printf '%s' "$encoding_actual" | xxd | sed 's/^/    /'
  FAILED=$((FAILED + 1))
fi
TOTAL=$((TOTAL + 1))

# Original-Clipboard wiederherstellen.
cat "$CLIPBOARD_BACKUP" | pbcopy
rm -f "$CLIPBOARD_BACKUP" "$ENCODING_HTML"

# --- Zusammenfassung ---
echo
echo "==> $PASSED/$TOTAL Tests bestanden"

# Exit-Code: 0 bei allen grün, 1 sobald einer rot.
[ "$FAILED" -eq 0 ]
