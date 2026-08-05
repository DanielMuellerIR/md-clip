#!/usr/bin/env bash
# tests/run-tests.sh — Vergleicht den Output der md-clip-Pipeline gegen
# die Expected-Files in tests/fixtures/.
#
# Strategie: md-clip selbst liest das Clipboard und kann hier nicht getestet
# werden ohne Clipboard-Mocking. Stattdessen testen wir die internen
# Pipelines (preprocess + clean + pandoc bzw. RTF + clean + pandoc)
# direkt mit den Fixture-Dateien als stdin.
#
# Läuft auf macOS UND Linux. Die Fixture-Tests brauchen nur pandoc + perl und
# sind damit überall gleich; die Clipboard-Roundtrip-Tests am Ende brauchen ein
# echtes Clipboard und überspringen sich selbst, wo keines da ist (z.B. in
# einem Container ohne X-Server — dort hilft `xvfb-run ./tests/run-tests.sh`).
#
# Wenn ein Test fehlschlägt, zeigen wir das Diff zur erwarteten Ausgabe.

set -euo pipefail

# Projekt-Root: das Verzeichnis ÜBER tests/.
TESTS_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
PROJECT_ROOT="$(dirname "$TESTS_DIR")"
FIXTURES="$TESTS_DIR/fixtures"

cd "$PROJECT_ROOT"

# Ein Bundle-ähnliches Laufzeitlayout nur aus getrackten Quellen. Dadurch
# beweisen die Produkt-Roundtrips, dass ein sauberer Checkout keine bereits
# kompilierten, ignorierten Helper aus dem Arbeitsverzeichnis benötigt.
TEST_RUNTIME=$(mktemp -d)
mkdir -p "$TEST_RUNTIME/bin"
cp "$PROJECT_ROOT/bin/md-clip" "$TEST_RUNTIME/bin/md-clip"
cp "$PROJECT_ROOT/lib/pipeline.sh" "$TEST_RUNTIME/bin/pipeline.sh"
PRODUCT_CLI="$TEST_RUNTIME/bin/md-clip"
CLIPBOARD_BACKUP=""
ENCODING_HTML=""
UTF16_HTML=""

cleanup_tests() {
  if [ -n "$CLIPBOARD_BACKUP" ] && [ -f "$CLIPBOARD_BACKUP" ] && declare -F clip_put_text_file >/dev/null 2>&1; then
    clip_put_text_file "$CLIPBOARD_BACKUP" 2>/dev/null || true
  fi
  rm -rf "$TEST_RUNTIME"
}
trap cleanup_tests EXIT INT TERM

# ---------- Plattform-Weiche ----------
# Spiegelt bin/md-clip. Siehe dort für die ausführliche Begründung jeder Zeile.

case "$(uname -s)" in
  Darwin) PLATFORM="macos" ;;
  Linux)  PLATFORM="linux" ;;
  *) echo "Nicht unterstützte Plattform: $(uname -s)" >&2; exit 2 ;;
esac

if [ "$PLATFORM" = "linux" ] && [ -n "${WAYLAND_DISPLAY:-}" ]; then
  CLIP_BACKEND="wayland"
else
  CLIP_BACKEND="x11"
fi

# Gleiche Locale wie bin/md-clip: en_US.UTF-8 gibt es auf Linux oft nicht,
# C.UTF-8 dagegen immer. Ohne UTF-8-Locale zerlegt perl hier die Umlaute in
# den Fixtures — der Test würde über ein Problem stolpern, das es im echten
# Lauf gar nicht gibt.
if [ "$PLATFORM" = "macos" ]; then
  export LC_ALL=en_US.UTF-8 LANG=en_US.UTF-8
else
  export LC_ALL=C.UTF-8 LANG=C.UTF-8
fi

# Die produktive Pipeline wird direkt geladen; nur der plattformspezifische
# RTF-Adapter bleibt im Test-Runner.
PANDOC_OPTS=(-f html -t gfm-raw_html --wrap=none)
# shellcheck source=../lib/pipeline.sh
source "$PROJECT_ROOT/lib/pipeline.sh"

rtf_to_html() {
  if [ "$PLATFORM" = "macos" ]; then
    textutil -convert html -format rtf -stdin -stdout
  else
    rtf_fix_escaped_newlines | pandoc -f rtf -t html
  fi
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
  # Beide Seiten sind gequotet; in [ ] gibt es dadurch weder Word-Splitting
  # noch Globbing.
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
actual=$(convert_html < "$FIXTURES/claude-desktop-codeblock.html")
run_test "claude-desktop-codeblock (HTML mit Subgrid-Divs)" \
  "$actual" \
  "$FIXTURES/claude-desktop-codeblock.expected.md"

# --- Test 2: Einfacher HTML-Artikel ---
# Repräsentativ für Browser-Copy (Safari, Chrome).
actual=$(convert_html < "$FIXTURES/safari-article.html")
run_test "safari-article (Browser-Copy)" \
  "$actual" \
  "$FIXTURES/safari-article.expected.md"

# --- Test 3: RTF aus Word/Pages/TextEdit ---
# Der komplette RTF-Pfad, so wie ihn bin/md-clip fährt.
#
# Hier laufen zwei VERSCHIEDENE RTF-Parser gegen dieselbe Erwartung: macOS
# nutzt textutil (Apples eigener), Linux pandocs RTF-Reader. Dass beide
# dieselbe Datei erfüllen müssen, ist Absicht — dieser Test ist die
# Absicherung dafür, dass dasselbe RTF auf beiden Plattformen dasselbe
# Markdown ergibt. Er ist damit der eigentliche Wächter über
# rtf_fix_escaped_newlines und unwrap_list_paragraphs: Fällt eine der beiden
# Korrekturen weg, wird dieser Test auf Linux rot.
actual=$(convert_rtf < "$FIXTURES/word-rtf.rtf")
run_test "word-rtf (RTF-Pfad, $PLATFORM)" \
  "$actual" \
  "$FIXTURES/word-rtf.expected.md"

# --- Test 4: Links mit leerem Anker-Text ---
# Leere HTML-Anker werden vor pandoc gefüllt. So bleiben auch URLs mit
# Klammern, Titel-Attributen und Escapes vollständig erhalten.
actual=$(convert_html < "$FIXTURES/empty-link.html")
run_test "empty-link (leerer Anker-Text → URL als Text)" \
  "$actual" \
  "$FIXTURES/empty-link.expected.md"

# --- Test 4b: Anker um ein Inline-SVG behält seine Grafik ---
# Kein Fixture, sondern eine gezielte Zusicherung: pandoc bettet ein Inline-SVG
# als `data:`-Bild ein, und dessen Base64 hängt an der pandoc-Version — eine
# Erwartungsdatei könnte macOS 3.9 und Ubuntu 3.1.3 nicht gleichzeitig erfüllen
# (AGENTS: „Ein Fixture darf nichts festschreiben, was von der pandoc-Version
# abhängt"). Geprüft wird deshalb nur das, was versionsunabhängig gelten muss:
# Die Grafik darf nicht durch den nackten URL-Text ersetzt werden — genau das
# tat fill_empty_html_links bis zum Review-Fund 2026-08-05.
svg_actual=$(printf '%s' \
  '<a href="https://ziel"><svg viewBox="0 0 10 10"><path d="M0 0h10v10H0z"/></svg></a>' \
  | convert_html)
if [ "$svg_actual" = '[https://ziel](https://ziel)' ]; then
  echo "✗ svg-link (Anker um Inline-SVG)"
  echo "  Die Grafik wurde durch den URL-Text ersetzt: $svg_actual"
  FAILED=$((FAILED + 1))
else
  echo "✓ svg-link (Inline-SVG im Anker bleibt erhalten)"
  PASSED=$((PASSED + 1))
fi
TOTAL=$((TOTAL + 1))

# --- Test 5: Google-Classroom-Link-Anhänge ---
# Anhänge sind <a> die Block-Divs (Titel, URL, Thumbnail) umschließen.
# Erwartung: kompakte Liste `- [Titel](href)`, authuser gestrippt,
# Thumbnails weg, kein leerer `[](url)`.
actual=$(convert_html < "$FIXTURES/google-classroom-links.html")
run_test "google-classroom-links (Anhänge → Titel-Liste)" \
  "$actual" \
  "$FIXTURES/google-classroom-links.expected.md"

# --- Test 6: Normale geordnete und ungeordnete Listen ---
# Classroom-Vorverarbeitung darf vorhandene <ol>/<ul> nicht umschreiben.
actual=$(convert_html < "$FIXTURES/ordinary-lists.html")
run_test "ordinary-lists (Listentypen bleiben erhalten)" \
  "$actual" \
  "$FIXTURES/ordinary-lists.expected.md"

# --- Test 7: <br><br>-Absätze + Listen ---
# <br><br> wird von pandoc zu Hard-Break-Backslash-Müll (`text\` + lone `\`).
# tidy_markdown muss daraus saubere Absätze + Listen machen, ohne
# Hard-Breaks in echtem Fließtext zu zerstören.
actual=$(convert_html < "$FIXTURES/br-paragraphs.html")
run_test "br-paragraphs (<br><br> → Absätze ohne Backslash-Müll)" \
  "$actual" \
  "$FIXTURES/br-paragraphs.expected.md"

# --- Test 8: Hard-Breaks als zwei Leerzeichen, letzter Marker weg ---
# Ein abschließendes <br> beim Copy erzeugt einen Hard-Break-Marker am
# Dokument-Ende. pandoc schreibt jeden Hard-Break als sichtbaren `\` — in
# JEDEM Dialekt, gfm eingeschlossen. tidy_markdown muss daraus machen:
#   - letzter, sinnloser Marker: ganz weg,
#   - echte Hard-Breaks davor (mehrzeilige Adresse): zwei Leerzeichen.
#
# ACHTUNG: Die beiden Leerzeichen am Zeilenende im Expected-File sind der
# eigentliche Prüfgegenstand. Ein Editor, der Trailing-Whitespace beim
# Speichern entfernt, macht diesen Test unbrauchbar — deshalb prüft der
# Test danach zusätzlich per printf-Vergleich, dass sie wirklich da sind.
actual=$(convert_html < "$FIXTURES/trailing-hardbreak.html")
run_test "trailing-hardbreak (<br> → zwei Leerzeichen, kein Backslash)" \
  "$actual" \
  "$FIXTURES/trailing-hardbreak.expected.md"

# Zweite, vom Expected-File unabhängige Absicherung derselben Regel.
TOTAL=$((TOTAL + 1))
if printf '%s' "$actual" | grep -q 'Besuchsadresse:  $' \
  && ! printf '%s' "$actual" | grep -q '\\$'; then
  echo "✓ hardbreak-form (zwei Leerzeichen statt Backslash)"
  PASSED=$((PASSED + 1))
else
  echo "✗ hardbreak-form (zwei Leerzeichen statt Backslash)"
  printf '%s' "$actual" | cat -v | sed 's/^/    /'
  FAILED=$((FAILED + 1))
fi

# --- Test 9: Code-Blöcke bleiben unangetastet ---
# In Code ist ein Backslash am Zeilenende echter Inhalt (Shell-Fortsetzung)
# und `\-` echter Code. tidy_markdown darf dort nichts umschreiben — weder
# im eingerückten noch im eingezäunten Block, und auch die Leerzeilen
# INNERHALB eines eingerückten Blocks müssen erhalten bleiben.
actual=$(convert_html < "$FIXTURES/code-blocks.html")
run_test "code-blocks (Backslash in Code bleibt Code)" \
  "$actual" \
  "$FIXTURES/code-blocks.expected.md"

# --- Test 10: überzählige Escapes ---
# pandoc escaped einen getippten Gedankenstrich am Zeilenanfang zu `\-` und
# eine getippte Trennlinie zu `\_\_\_`. Ein Absatz, der nur aus einem fett
# gesetzten Bullet besteht, war ebenfalls ein getippter Listenpunkt.
#
# Dazu Pipe und Raute: beide escaped pandoc überall, Markdown-Zeichen sind sie
# aber nur an einer Stelle — `|` in einer Tabellenzeile, `#` am Zeilenanfang.
# Der Test pinnt beide Seiten: im Fließtext fällt der Backslash weg, in der
# Tabellenzeile und vor der Zeilenanfangs-Raute bleibt er stehen.
actual=$(convert_html < "$FIXTURES/escaped-markers.html")
run_test "escaped-markers (überzählige Backslashes weg)" \
  "$actual" \
  "$FIXTURES/escaped-markers.expected.md"

echo
echo "==> Clipboard-Roundtrip-Tests"
#
# Diese Tests sind die wichtigsten, weil sie die einzige Stelle sind, an der
# wir die EFFEKTIVE Nutzer-Erfahrung prüfen — nicht nur die Bytes auf
# stdout, sondern was eine andere App tatsächlich beim Einfügen sieht.
# Sie brauchen ein echtes Clipboard und laufen daher nicht überall.

# clipboard_available: Kann hier überhaupt ein Clipboard-Test laufen?
# macOS: immer. Linux: nur mit Display-Server UND passendem Werkzeug —
# in einem nackten Container/CI-Runner fehlt beides, dort hilft `xvfb-run`.
clipboard_available() {
  if [ "${MD_CLIP_SKIP_CLIPBOARD:-0}" = "1" ]; then
    return 1
  fi
  if [ "$PLATFORM" = "macos" ]; then
    command -v swiftc >/dev/null 2>&1 \
      && command -v pbcopy >/dev/null 2>&1 \
      && command -v pbpaste >/dev/null 2>&1
    return
  fi
  if [ "$CLIP_BACKEND" = "wayland" ]; then
    command -v wl-copy >/dev/null 2>&1 && command -v wl-paste >/dev/null 2>&1
  else
    [ -n "${DISPLAY:-}" ] && command -v xclip >/dev/null 2>&1
  fi
}

# Test-Eingabe: drei Kategorien Nicht-ASCII auf einmal — Latin-1-Umlaute
# (ä, ö, ü, ß), 2-Byte-Sonderzeichen (—) und 3-Byte-BMP-Symbole (☤).
# Wer EINE dieser Kategorien verliert, fällt durch.
ENCODING_INPUT='<p>Café über Größen — ☤</p>'
ENCODING_EXPECTED='Café über Größen — ☤'

if ! clipboard_available; then
  # Bewusst KEIN stiller Skip: Ein übersprungener Test, den niemand sieht,
  # ist schlimmer als gar keiner — er suggeriert Abdeckung, die es nicht gibt.
  echo "⊘ Clipboard-Roundtrip übersprungen — kein erreichbares Clipboard"
  if [ "$PLATFORM" = "linux" ]; then
    echo "  (Linux ohne Display-Server/Clipboard-Tool. Mit Clipboard testen:"
    echo "   sudo apt install xclip xvfb && xvfb-run ./tests/run-tests.sh)"
  fi
  SKIPPED=1
else
  SKIPPED=0

  # Bestehenden Clipboard-Inhalt als Plain-Text sichern, damit wir am
  # Ende restaurieren können. Rich-Flavors gehen verloren — bei einem
  # Test-Lauf akzeptabel.
  CLIPBOARD_BACKUP="$TEST_RUNTIME/clipboard-backup"

  # clip_put_html / clip_get_text: die Gegenstücke zu dem, was bin/md-clip
  # tut — bewusst über die PLATTFORM-EIGENEN Werkzeuge, damit der Test die
  # echte Schnittstelle benutzt und nicht md-clips eigene Funktionen (die
  # würden einen Fehler auf beiden Seiten gleichzeitig machen und ihn damit
  # aufheben — siehe docs/ENCODING.md).
  #
  # Auf macOS lesen wir über NSPasteboard.string in Swift — das ist die
  # echte API, die jede Paste-Konsumenten-App verwendet. Ein Roundtrip über
  # pbcopy+pbpaste (beide in derselben falschen Locale) würde den
  # Encoding-Bug verstecken, weil sich die Fehler aufheben.
  if [ "$PLATFORM" = "macos" ]; then
    # Alle Test- und Produkt-Helper ausschließlich im privaten Temp-Layout
    # bauen; der Checkout bleibt sauber und reproduzierbar.
    LOAD_CLIPBOARD_BIN="$TEST_RUNTIME/load-clipboard"
    LOAD_CLIPBOARD_SRC="$TESTS_DIR/load-clipboard.swift"
    swiftc "$LOAD_CLIPBOARD_SRC" -o "$LOAD_CLIPBOARD_BIN"
    CLIPBOARD_STRING_BIN="$TEST_RUNTIME/clipboard-string"
    CLIPBOARD_STRING_SRC="$TESTS_DIR/clipboard-string.swift"
    swiftc "$CLIPBOARD_STRING_SRC" -o "$CLIPBOARD_STRING_BIN"
    swiftc "$PROJECT_ROOT/helpers/clipboard-html.swift" -o "$TEST_RUNTIME/bin/clipboard-html"
    swiftc "$PROJECT_ROOT/helpers/clipboard-rtf.swift" -o "$TEST_RUNTIME/bin/clipboard-rtf"

    clip_put_html() { "$LOAD_CLIPBOARD_BIN" public.html "$1" >/dev/null; }
    clip_get_text() { "$CLIPBOARD_STRING_BIN"; }
    clip_put_text_file() { pbcopy < "$1"; }
    pbpaste > "$CLIPBOARD_BACKUP" 2>/dev/null || true
  elif [ "$CLIP_BACKEND" = "wayland" ]; then
    clip_put_html() { wl-copy --type text/html < "$1"; }
    clip_get_text() { wl-paste --no-newline; }
    clip_put_text_file() { wl-copy < "$1"; }
    wl-paste --no-newline > "$CLIPBOARD_BACKUP" 2>/dev/null || true
  else
    # Die `>/dev/null 2>&1` beim Schreiben sind NICHT kosmetisch: xclip forkt
    # sich in den Hintergrund und hält die X11-Auswahl, bis ein anderes
    # Programm sie übernimmt. Dieser Hintergrund-Prozess erbt stdout — und
    # hält damit das Schreibende der Pipe offen. Wer `./tests/run-tests.sh | tail`
    # aufruft (oder einen CI-Job, der die Ausgabe einsammelt), wartet sonst
    # ewig auf ein EOF, das nie kommt, obwohl die Tests längst durch sind.
    # Beim LESEN darf stdout natürlich nicht umgeleitet werden — das ist ja
    # das Ergebnis.
    clip_put_html() { xclip -selection clipboard -target text/html -in "$1" >/dev/null 2>&1; }
    clip_get_text() { xclip -selection clipboard -out 2>/dev/null; }
    clip_put_text_file() { xclip -selection clipboard -in "$1" >/dev/null 2>&1; }
    xclip -selection clipboard -out > "$CLIPBOARD_BACKUP" 2>/dev/null || true
  fi

  # --- Roundtrip 1: UTF-8-HTML durch die volle Kette ---
  ENCODING_HTML="$TEST_RUNTIME/encoding.html"
  printf '%s' "$ENCODING_INPUT" > "$ENCODING_HTML"

  clip_put_html "$ENCODING_HTML"

  # Vollständige Kette laufen lassen, --replace schreibt Ergebnis ins Clipboard.
  "$PRODUCT_CLI" --replace --quiet

  # Vergleich über DATEIEN statt über Shell-Variablen: `$(...)` schluckt jedes
  # abschließende Newline und würde damit genau den Fehler verstecken, den
  # dieser Test finden soll — ein überzähliges LF, das beim Einfügen als
  # zusätzliche leere Zeile auftaucht. `cmp` prüft Byte für Byte.
  ENCODING_EXPECTED_FILE="$TEST_RUNTIME/encoding.expected"
  ENCODING_ACTUAL_FILE="$TEST_RUNTIME/encoding.actual"
  printf '%s' "$ENCODING_EXPECTED" > "$ENCODING_EXPECTED_FILE"
  clip_get_text > "$ENCODING_ACTUAL_FILE"

  if cmp -s "$ENCODING_EXPECTED_FILE" "$ENCODING_ACTUAL_FILE"; then
    echo "✓ encoding-roundtrip (UTF-8 durchs Clipboard, bytegenau)"
    PASSED=$((PASSED + 1))
  else
    echo "✗ encoding-roundtrip"
    echo "  Erwartet:  '$ENCODING_EXPECTED'"
    echo "  Erhalten:  '$(cat "$ENCODING_ACTUAL_FILE")'"
    echo "  Erwartete Bytes:"
    xxd "$ENCODING_EXPECTED_FILE" | sed 's/^/    /'
    echo "  Erhaltene Bytes:"
    xxd "$ENCODING_ACTUAL_FILE" | sed 's/^/    /'
    FAILED=$((FAILED + 1))
  fi
  TOTAL=$((TOTAL + 1))

  # --- Roundtrip 1b: echter Schluss-Leerabsatz überlebt das Clipboard ---
  # Der Roundtrip oben hat genau einen nichtleeren Absatz und kann deshalb nicht
  # sehen, wie viele Schluss-LFs entfernt werden. Endet das Dokument aber auf
  # einen leeren Absatz, liefert die Kette ZWEI: eines ist Pandocs Dateiende,
  # das andere der Absatz. Das frühere `s/\n+\z//` nahm beide und verschluckte
  # damit den Absatz (Review-Fund 2026-08-05).
  TRAILING_HTML="$TEST_RUNTIME/trailing.html"
  printf '%s' '<p>a</p><p><br></p>' > "$TRAILING_HTML"
  clip_put_html "$TRAILING_HTML"
  "$PRODUCT_CLI" --replace --quiet

  TRAILING_EXPECTED_FILE="$TEST_RUNTIME/trailing.expected"
  TRAILING_ACTUAL_FILE="$TEST_RUNTIME/trailing.actual"
  printf 'a\n' > "$TRAILING_EXPECTED_FILE"
  clip_get_text > "$TRAILING_ACTUAL_FILE"

  if cmp -s "$TRAILING_EXPECTED_FILE" "$TRAILING_ACTUAL_FILE"; then
    echo "✓ trailing-empty-paragraph (genau ein Schluss-LF entfernt)"
    PASSED=$((PASSED + 1))
  else
    echo "✗ trailing-empty-paragraph"
    echo "  Erwartete Bytes:"
    xxd "$TRAILING_EXPECTED_FILE" | sed 's/^/    /'
    echo "  Erhaltene Bytes:"
    xxd "$TRAILING_ACTUAL_FILE" | sed 's/^/    /'
    FAILED=$((FAILED + 1))
  fi
  TOTAL=$((TOTAL + 1))

  # --- Roundtrip 2: UTF-16-HTML (Firefox-Fall, nur Linux) ---
  # Firefox legt sein text/html unter Linux als UTF-16 mit BOM aufs Clipboard,
  # Chromium als UTF-8. md-clip muss BEIDE lesen können (siehe to_utf8 in
  # bin/md-clip). Wir erzeugen die UTF-16-Variante hier selbst mit iconv, statt
  # einen echten Firefox zu starten: Es geht um die BYTES auf dem Clipboard,
  # und die sind so exakt reproduzierbar — headless, ohne Browser, in CI.
  # Auf macOS gibt es diesen Fall nicht (NSPasteboard liefert immer UTF-8).
  if [ "$PLATFORM" = "linux" ]; then
    UTF16_HTML="$TEST_RUNTIME/utf16.html"
    printf '%s' "$ENCODING_INPUT" | iconv -f UTF-8 -t UTF-16 > "$UTF16_HTML"

    clip_put_html "$UTF16_HTML"
    utf16_actual="$("$PRODUCT_CLI" --quiet)"

    if [ "$utf16_actual" = "$ENCODING_EXPECTED" ]; then
      echo "✓ utf16-html-clipboard (Firefox-Fall: UTF-16-HTML korrekt gelesen)"
      PASSED=$((PASSED + 1))
    else
      echo "✗ utf16-html-clipboard"
      echo "  Erwartet:  '$ENCODING_EXPECTED'"
      echo "  Erhalten:  '$utf16_actual'"
      FAILED=$((FAILED + 1))
    fi
    TOTAL=$((TOTAL + 1))
  fi

  # Original-Clipboard wiederherstellen + Temp-Dateien aufräumen erledigt der
  # EXIT-Trap (siehe oben) — auch bei vorzeitigem Abbruch.
fi

# --- Zusammenfassung ---
echo
echo "==> $PASSED/$TOTAL Tests bestanden"
if [ "$SKIPPED" -eq 1 ]; then
  echo "    (Clipboard-Roundtrip übersprungen — siehe Hinweis oben)"
fi

# Exit-Code: 0 bei allen grün, 1 sobald einer rot.
# Ein Skip ist KEIN Fehler: Fixture-Tests im Container sollen grün sein können,
# sonst wäre der Container-Lauf wertlos. Sichtbar bleibt der Skip trotzdem.
[ "$FAILED" -eq 0 ]
