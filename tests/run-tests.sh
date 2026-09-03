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
trap cleanup_tests EXIT
trap 'exit 130' INT
trap 'exit 143' TERM

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
TO=gfm
# shellcheck source=../lib/pipeline.sh
source "$PROJECT_ROOT/lib/pipeline.sh"

rtf_to_html() {
  # codereview-ok: Dieser Adapter ist laut AGENTS.md bewusst der jeweilige
  # Plattform-Rand; nur die danach gemeinsame Pipeline lebt in lib/. (2026-08-20)
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

# run_test: Vergleicht Ergebnis und Erwartung bytegenau als Dateien. Shell-
# Command-Substitution ist hier absichtlich verboten, weil sie alle Schluss-LFs
# entfernt und genau die von der Pipeline zugesicherte Dateiendung versteckt.
# Args: 1=Test-Name, 2=actual-Datei, 3=expected-Datei
run_test() {
  local name="$1"
  local actual_file="$2"
  local expected_file="$3"

  TOTAL=$((TOTAL + 1))

  if [ ! -f "$expected_file" ]; then
    echo "✗ $name — expected-Datei fehlt: $expected_file"
    FAILED=$((FAILED + 1))
    return
  fi

  if cmp -s "$expected_file" "$actual_file"; then
    echo "✓ $name"
    PASSED=$((PASSED + 1))
  else
    echo "✗ $name"
    echo "  --- Diff (erwartet vs. tatsächlich) ---"
    diff -u "$expected_file" "$actual_file" | sed 's/^/    /' || true
    FAILED=$((FAILED + 1))
  fi
}

echo "==> md-clip Tests"
echo

# --- Test 1: Claude-Desktop-Code-Block ---
# HTML mit Subgrid-Divs → muss Code-Zeilen mit Newlines + Markdown-Restformat liefern.
actual_file="$TEST_RUNTIME/claude-desktop-codeblock.actual"
convert_html "$TO" < "$FIXTURES/claude-desktop-codeblock.html" > "$actual_file"
run_test "claude-desktop-codeblock (HTML mit Subgrid-Divs)" \
  "$actual_file" \
  "$FIXTURES/claude-desktop-codeblock.expected.md"

# --- Test 2: Einfacher HTML-Artikel ---
# Repräsentativ für Browser-Copy (Safari, Chrome).
actual_file="$TEST_RUNTIME/safari-article.actual"
convert_html "$TO" < "$FIXTURES/safari-article.html" > "$actual_file"
run_test "safari-article (Browser-Copy)" \
  "$actual_file" \
  "$FIXTURES/safari-article.expected.md"

# --- Test 2b: Attribute in Prosa und Code sind Nutzdaten ---
# Die Claude-Vorverarbeitung entfernt style/data-* nur aus echten HTML-Tags;
# gleich geschriebener Text und maskiertes HTML im Code bleiben bytegenau.
actual_file="$TEST_RUNTIME/literal-attributes.actual"
convert_html "$TO" < "$FIXTURES/literal-attributes.html" > "$actual_file"
run_test "literal-attributes (Prosa und Code verlieren keine Attribute)" \
  "$actual_file" \
  "$FIXTURES/literal-attributes.expected.md"

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
actual_file="$TEST_RUNTIME/word-rtf.actual"
convert_rtf "$TO" < "$FIXTURES/word-rtf.rtf" > "$actual_file"
run_test "word-rtf (RTF-Pfad, $PLATFORM)" \
  "$actual_file" \
  "$FIXTURES/word-rtf.expected.md"

# Datenmatrizen aus RTF-HTML dürfen nicht wie Layout-Tabellen geplättet
# werden. Eine einspaltige Tabelle ohne Kopf bleibt dagegen bewusst Layout.
actual_file="$TEST_RUNTIME/data-table.actual"
printf '%s' '<table><tr><th>Name</th><th>Wert</th></tr><tr><td>A</td><td>1</td></tr></table>' \
  | flatten_layout_tables | clean_html | fill_empty_html_links \
  | run_pandoc gfm | tidy_markdown gfm | require_nonempty_markdown > "$actual_file"
run_test "data-table (Zeilen und Spalten bleiben erhalten)" \
  "$actual_file" "$FIXTURES/data-table.expected.md"

layout_table_actual=$(
  printf '%s' '<table><colgroup><col width="100"><tr><td>A</td></tr><tr><td>B</td></tr></table>' \
    | flatten_layout_tables
)
formatted_list_actual=$(
  printf '%s' '<ul><li><p><strong>fett</strong> und mehr</p></li></ul>' \
    | unwrap_list_paragraphs
)
TOTAL=$((TOTAL + 1))
if [ "$layout_table_actual" = '<p>A</p><p>B</p>' ] \
  && [ "$formatted_list_actual" = '<ul><li><strong>fett</strong> und mehr</li></ul>' ]; then
  echo "✓ rtf-html-normalisierung (Layouttabelle und formatierte Liste)"
  PASSED=$((PASSED + 1))
else
  echo "✗ rtf-html-normalisierung"
  printf '  Tabelle: %s\n  Liste: %s\n' "$layout_table_actual" "$formatted_list_actual"
  FAILED=$((FAILED + 1))
fi

# --- Test 4: Links mit leerem Anker-Text ---
# Leere HTML-Anker werden vor pandoc gefüllt. So bleiben auch URLs mit
# Klammern, Titel-Attributen und Escapes vollständig erhalten.
actual_file="$TEST_RUNTIME/empty-link.actual"
convert_html "$TO" < "$FIXTURES/empty-link.html" > "$actual_file"
run_test "empty-link (leerer Anker-Text → URL als Text)" \
  "$actual_file" \
  "$FIXTURES/empty-link.expected.md"

# --- Test 4b: Anker um ein Inline-SVG behält seine Grafik ---
# Kein Fixture, sondern eine gezielte Zusicherung: pandoc bettet ein Inline-SVG
# als `data:`-Bild ein, und dessen Base64 hängt an der pandoc-Version — eine
# Erwartungsdatei könnte macOS 3.9 und Ubuntu 3.1.3 nicht gleichzeitig erfüllen
# (AGENTS: „Ein Fixture darf nichts festschreiben, was von der pandoc-Version
# abhängt"). Geprüft wird deshalb nur das, was versionsunabhängig gelten muss:
# Die Grafik muss als Markdown-Bild mit `data:image/svg+xml` IM Ziellink
# stehen — genau das verlor fill_empty_html_links bis zum Review-Fund
# 2026-08-05.
#
# Die Prüfung ist bewusst POSITIV formuliert. Vorher stand hier nur „Ergebnis
# ist ungleich [https://ziel](https://ziel)"; eine leere Ausgabe oder ein
# `[](https://ziel)` wäre damit als Erfolg durchgegangen, obwohl die Grafik
# komplett fehlt (Review-Fund 2026-08-06).

# svg_link_ok: Steht in der Ausgabe ein Bild mit SVG-Datenquelle, und liegt es
# innerhalb des Ziellinks? Fixe Zeichenketten, kein Muster — die Base64-Bytes
# des Bildes unterscheiden sich je pandoc-Version und dürfen hier nicht zählen.
svg_link_ok() {
  local out="$1"
  printf '%s' "$out" | grep -qF '[![' \
    && printf '%s' "$out" | grep -qF '](data:image/svg+xml' \
    && printf '%s' "$out" | grep -qF ')](https://ziel)'
}

svg_actual=$(printf '%s' \
  '<a href="https://ziel"><svg viewBox="0 0 10 10"><path d="M0 0h10v10H0z"/></svg></a>' \
  | convert_html "$TO")
if svg_link_ok "$svg_actual"; then
  echo "✓ svg-link (Inline-SVG im Anker bleibt erhalten)"
  PASSED=$((PASSED + 1))
else
  echo "✗ svg-link (Anker um Inline-SVG)"
  echo "  Kein SVG-Bild im Ziellink: $svg_actual"
  FAILED=$((FAILED + 1))
fi
TOTAL=$((TOTAL + 1))

# Gegenprobe auf die Prüfung selbst: Drei grafiklose Ausgaben — leer, nackter
# URL-Text, leerer Linktext — müssen alle abgelehnt werden. Ohne diesen Schritt
# könnte die Zusicherung oben unbemerkt wieder verwässern.
svg_negative_ok=1
for svg_bad in '' '[https://ziel](https://ziel)' '[](https://ziel)'; do
  if svg_link_ok "$svg_bad"; then
    svg_negative_ok=0
    echo "  Grafiklose Ausgabe fälschlich akzeptiert: '$svg_bad'"
  fi
done
if [ "$svg_negative_ok" -eq 1 ]; then
  echo "✓ svg-link-negativkontrolle (grafiklose Ausgabe fällt durch)"
  PASSED=$((PASSED + 1))
else
  echo "✗ svg-link-negativkontrolle"
  FAILED=$((FAILED + 1))
fi
TOTAL=$((TOTAL + 1))

# --- Test 5: Google-Classroom-Link-Anhänge ---
# Anhänge sind <a> die Block-Divs (Titel, URL, Thumbnail) umschließen.
# Erwartung: kompakte Liste `- [Titel](href)`, authuser gestrippt,
# Thumbnails weg, kein leerer `[](url)`.
actual_file="$TEST_RUNTIME/google-classroom-links.actual"
convert_html "$TO" < "$FIXTURES/google-classroom-links.html" > "$actual_file"
run_test "google-classroom-links (Anhänge → Titel-Liste)" \
  "$actual_file" \
  "$FIXTURES/google-classroom-links.expected.md"

classroom_query_actual=$(
  printf '%s' '<a href="https://docs.example/edit?authuser=0#heading=h.abc"><div class="mvRF3b">Fragment</div><img src="https://classroom.google.com/webthumbnail?x"></a><a href="https://example.test/p?authuser=0&amp;x=1"><div class="mvRF3b">Query</div><img src="https://classroom.google.com/webthumbnail?x"></a>' \
    | convert_html "$TO"
)
TOTAL=$((TOTAL + 1))
if printf '%s\n' "$classroom_query_actual" | grep -Fq 'https://docs.example/edit#heading=h.abc' \
  && printf '%s\n' "$classroom_query_actual" | grep -Fq 'https://example.test/p?x=1'; then
  echo "✓ classroom-authuser (Fragment und Folgeparameter bleiben erhalten)"
  PASSED=$((PASSED + 1))
else
  echo "✗ classroom-authuser"
  printf '%s\n' "$classroom_query_actual" | sed 's/^/    /'
  FAILED=$((FAILED + 1))
fi

# --- Test 6: Normale geordnete und ungeordnete Listen ---
# Classroom-Vorverarbeitung darf vorhandene <ol>/<ul> nicht umschreiben.
actual_file="$TEST_RUNTIME/ordinary-lists.actual"
convert_html "$TO" < "$FIXTURES/ordinary-lists.html" > "$actual_file"
run_test "ordinary-lists (Listentypen bleiben erhalten)" \
  "$actual_file" \
  "$FIXTURES/ordinary-lists.expected.md"

# --- Test 7: <br><br>-Absätze + Listen ---
# <br><br> wird von pandoc zu Hard-Break-Backslash-Müll (`text\` + lone `\`).
# tidy_markdown muss daraus saubere Absätze + Listen machen, ohne
# Hard-Breaks in echtem Fließtext zu zerstören.
actual_file="$TEST_RUNTIME/br-paragraphs.actual"
convert_html "$TO" < "$FIXTURES/br-paragraphs.html" > "$actual_file"
run_test "br-paragraphs (<br><br> → Absätze ohne Backslash-Müll)" \
  "$actual_file" \
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
hardbreak_actual_file="$TEST_RUNTIME/trailing-hardbreak.actual"
convert_html "$TO" < "$FIXTURES/trailing-hardbreak.html" > "$hardbreak_actual_file"
run_test "trailing-hardbreak (<br> → zwei Leerzeichen, kein Backslash)" \
  "$hardbreak_actual_file" \
  "$FIXTURES/trailing-hardbreak.expected.md"

# Zweite, vom Expected-File unabhängige Absicherung derselben Regel.
TOTAL=$((TOTAL + 1))
if grep -q 'Besuchsadresse:  $' "$hardbreak_actual_file" \
  && ! grep -q '\\$' "$hardbreak_actual_file"; then
  echo "✓ hardbreak-form (zwei Leerzeichen statt Backslash)"
  PASSED=$((PASSED + 1))
else
  echo "✗ hardbreak-form (zwei Leerzeichen statt Backslash)"
  cat -v "$hardbreak_actual_file" | sed 's/^/    /'
  FAILED=$((FAILED + 1))
fi

# --- Test 9: Code-Blöcke bleiben unangetastet ---
# In Code ist ein Backslash am Zeilenende echter Inhalt (Shell-Fortsetzung)
# und `\-` echter Code. tidy_markdown darf dort nichts umschreiben — weder
# im eingerückten noch im eingezäunten Block, und auch die Leerzeilen
# INNERHALB eines eingerückten Blocks müssen erhalten bleiben.
actual_file="$TEST_RUNTIME/code-blocks.actual"
convert_html "$TO" < "$FIXTURES/code-blocks.html" > "$actual_file"
run_test "code-blocks (Backslash in Code bleibt Code)" \
  "$actual_file" \
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
#
# Die Zeile „Code mit Schluss-Backslash" sichert den Sonderfall aus dem
# Review-Fund 2026-08-06: Endet Inline-Code auf einen Backslash, schließt der
# folgende Backtick den Code trotzdem. Vorher galt er als maskiert, der Span
# blieb offen, und aus `` `\#foo\` `` wurde `` `#foo\` `` — verändertes Code.
actual_file="$TEST_RUNTIME/escaped-markers.actual"
convert_html "$TO" < "$FIXTURES/escaped-markers.html" > "$actual_file"
run_test "escaped-markers (überzählige Backslashes weg)" \
  "$actual_file" \
  "$FIXTURES/escaped-markers.expected.md"

# Leeres/unsichtbares HTML ist keine erfolgreiche Konvertierung. Pandocs
# einzelnes Schluss-LF darf nicht als Nutzinhalt durchgehen.
TOTAL=$((TOTAL + 1))
if printf '%s' '<p><br></p>' | convert_html gfm > "$TEST_RUNTIME/empty-rich.actual"; then
  echo "✗ empty-rich (leeres HTML wurde als Erfolg gemeldet)"
  FAILED=$((FAILED + 1))
else
  echo "✓ empty-rich (leeres HTML löst Fallback aus)"
  PASSED=$((PASSED + 1))
fi

# Unsichtbar heißt auch: nur ein geschütztes Leerzeichen. `\S` auf rohen Bytes
# hielt dessen zwei UTF-8-Bytes (0xC2 0xA0) für Inhalt — der Auto-Modus
# unterdrückte dann den vorhandenen Plain-Text-Fallback, und mit --replace
# ersetzte Unsichtbares das Clipboard (Review-Fund 2026-08-21).
for invisible_html in '<p>&nbsp;</p>' '<p>&#8203;</p>' '<p> </p>'; do
  TOTAL=$((TOTAL + 1))
  if printf '%s' "$invisible_html" | convert_html gfm \
      > "$TEST_RUNTIME/invisible-rich.actual" 2>/dev/null; then
    echo "✗ invisible-rich ($invisible_html wurde als Erfolg gemeldet)"
    od -c "$TEST_RUNTIME/invisible-rich.actual" | sed 's/^/    /' | head -3
    FAILED=$((FAILED + 1))
  else
    echo "✓ invisible-rich ($invisible_html löst Fallback aus)"
    PASSED=$((PASSED + 1))
  fi
done

# Gegenprobe: Ein geschütztes Leerzeichen NEBEN echtem Text bleibt Inhalt.
TOTAL=$((TOTAL + 1))
if printf '%s' '<p>A&nbsp;B</p>' | convert_html gfm \
    > "$TEST_RUNTIME/visible-nbsp.actual" 2>/dev/null \
    && grep -q 'A' "$TEST_RUNTIME/visible-nbsp.actual"; then
  echo "✓ visible-nbsp (Text mit geschütztem Leerzeichen bleibt Inhalt)"
  PASSED=$((PASSED + 1))
else
  echo "✗ visible-nbsp (Text mit geschütztem Leerzeichen ging verloren)"
  FAILED=$((FAILED + 1))
fi

# run_pandoc muss das Netzwerk-Tor in jedem Zieldialekt setzen. Eine Attrappe
# zeichnet argv auf; damit prüft der Test die echte Funktionsgrenze statt nur
# nach Text im Skript zu suchen.
mkdir -p "$TEST_RUNTIME/pandoc-stub"
cat > "$TEST_RUNTIME/pandoc-stub/pandoc" <<'SH'
#!/bin/sh
printf '%s\n' "$@" > "$MD_CLIP_PANDOC_ARGS"
exec /bin/cat
SH
chmod +x "$TEST_RUNTIME/pandoc-stub/pandoc"
MD_CLIP_PANDOC_ARGS="$TEST_RUNTIME/pandoc.args" \
  PATH="$TEST_RUNTIME/pandoc-stub:$PATH" run_pandoc gfm < /dev/null > /dev/null
TOTAL=$((TOTAL + 1))
if grep -Fxq -- '--sandbox' "$TEST_RUNTIME/pandoc.args"; then
  echo "✓ pandoc-sandbox (eingebettete Ressourcen bleiben offline)"
  PASSED=$((PASSED + 1))
else
  echo "✗ pandoc-sandbox"
  FAILED=$((FAILED + 1))
fi

# --- Test 10b: römisch nummerierte Liste beim Ziel `markdown` ---
# `md-clip --to markdown` schaltet pandocs Fancy Lists frei; aus
# `<ol type="i" start="4">` wird dort der MEHRSTELLIGE Marker `iv.`. Erkennt
# die Escape-Regel ihn nicht, fällt der Backslash vor der Raute weg und aus dem
# Listentext wird eine Überschrift erster Ebene (Review-Fund 2026-08-06).
#
# Geprüft wird nicht der Text, sondern die STRUKTUR: Das Ergebnis wird erneut
# von pandoc gelesen und darf keinen Header enthalten. Das ist unabhängig davon,
# wie eine pandoc-Version den Marker genau setzt — anders als eine
# Erwartungsdatei, die den Marker festschreiben müsste.
roman_input='<ol type="i" start="4"><li># tief</li></ol>'
roman_actual=$(
  printf '%s' "$roman_input" | convert_html markdown
)
roman_ast=$(printf '%s\n' "$roman_actual" | pandoc -f markdown -t native)

# Gegenprobe: Genau die kaputte Ausgabe muss im AST als Header auftauchen —
# sonst prüfte der Test oben etwas, das gar nicht schiefgehen kann.
roman_broken_ast=$(printf 'iv. # tief\n' | pandoc -f markdown -t native)

TOTAL=$((TOTAL + 1))
if printf '%s' "$roman_ast" | grep -q 'OrderedList' \
  && ! printf '%s' "$roman_ast" | grep -q 'Header' \
  && printf '%s' "$roman_broken_ast" | grep -q 'Header'; then
  echo "✓ roman-list-marker (mehrstelliger Marker schützt die Raute)"
  PASSED=$((PASSED + 1))
else
  echo "✗ roman-list-marker (mehrstelliger Marker schützt die Raute)"
  echo "  Ergebnis: $roman_actual"
  printf '%s\n' "$roman_ast" | sed 's/^/    /'
  FAILED=$((FAILED + 1))
fi

# --- Test 10c: Fortsetzungszeilen von Markdown-Sonderlisten ---
# Der Zieldialekt `markdown` kann neben Dezimal- auch alphabetische, römische
# und Definitionslisten schreiben. tidy_markdown muss deren Inhalts-Einrückung
# als Listen-Container erkennen. Sonst gelten die vier eingerückten Spalten der
# Fortsetzungszeile fälschlich als Code und sichtbare \#-/\|-Escapes bleiben
# stehen. GFM und CommonMark verwenden diese Marker nicht, deshalb prüft dieser
# Fall bewusst den Dialekt, in dem der Fehler auftreten kann.
special_lists_input='<ol type="a"><li><p>eins<br>mitte # raute | pipe</p></li></ol><dl><dt>Begriff</dt><dd><p>eins<br>mitte # raute | pipe</p></dd></dl>'
special_lists_actual=$(
  printf '%s' "$special_lists_input" | convert_html markdown
)
special_lists_ast=$(printf '%s\n' "$special_lists_actual" | pandoc -f markdown -t native)
# Direkte Gegenprobe für denselben Marker an der Hard-Break-Regel: Hinter
# einem echten Umbruch ist `a.` Teil desselben Absatzes und kein belegter
# Listenblock. Der Umbruch muss deshalb als zwei Leerzeichen erhalten bleiben.
special_list_break_actual=$(printf 'Text\\\na.  Punkt\n' | tidy_markdown markdown)

TOTAL=$((TOTAL + 1))
if [ "$(printf '%s\n' "$special_lists_actual" | grep -Fc 'mitte # raute | pipe')" -eq 2 ] \
  && ! printf '%s\n' "$special_lists_actual" | grep -Eq '\\[#|]' \
  && printf '%s' "$special_lists_ast" | grep -q 'OrderedList' \
  && printf '%s' "$special_lists_ast" | grep -q 'DefinitionList' \
  && ! printf '%s' "$special_lists_ast" | grep -q 'CodeBlock' \
  && [ "$special_list_break_actual" = $'Text  \na.  Punkt' ]; then
  echo "✓ markdown-listenfortsetzung (Escapes entfernt, Struktur erhalten)"
  PASSED=$((PASSED + 1))
else
  echo "✗ markdown-listenfortsetzung"
  printf '%s\n' "$special_lists_actual" | sed 's/^/    /'
  FAILED=$((FAILED + 1))
fi

# --- Test 10c2: Mehrpunkt- und Blockquote-Sonderlisten (Review-Fund 2026-08-17) ---
# Drei Fälle, die die frühere „Hard-Break davor ⇒ kein Listenpunkt"-Regel
# fälschlich verwarf:
#   a) eine enge a./b.-Liste, deren erster Punkt auf <br> endet — `b.` ist der
#      echte zweite Punkt und kein Absatztext,
#   b) eine Definitionsliste, deren Term auf <br> endet,
#   c) eine Definitionsliste im Blockquote: pandoc schreibt die Leerzeile des
#      Zitats als `>`, die Textzeilen als `> Text`; der bytegleiche
#      Präfix-Vergleich brach die Term-Suche an dieser Leerzeile ab.
# In allen drei Fällen musste die eingerückte Fortsetzung als Listeninhalt
# gelten — sonst wäre sie Code und behielte sichtbare \#-/\|-Escapes.
multi_item_actual=$(
  printf '%s' '<ol type="a"><li>first<br></li><li>second<br>middle # hash | pipe</li></ol>' \
    | convert_html markdown
)
multi_item_ast=$(printf '%s\n' "$multi_item_actual" | pandoc -f markdown -t native)

break_term_actual=$(
  printf '%s' '<dl><dt>Begriff<br></dt><dd><p>eins<br>mitte # raute | pipe</p></dd></dl>' \
    | convert_html markdown
)
break_term_ast=$(printf '%s\n' "$break_term_actual" | pandoc -f markdown -t native)

quoted_dl_actual=$(
  printf '%s' '<blockquote><dl><dt>Begriff</dt><dd><p>eins<br>mitte # raute | pipe</p></dd></dl></blockquote>' \
    | convert_html markdown
)
quoted_dl_ast=$(printf '%s\n' "$quoted_dl_actual" | pandoc -f markdown -t native)

nested_quoted_dl_actual=$(
  printf '%s' '<blockquote><blockquote><dl><dt>Begriff</dt><dd><p>eins<br>mitte # raute | pipe</p></dd></dl></blockquote></blockquote>' \
    | convert_html markdown
)
nested_quoted_dl_ast=$(printf '%s\n' "$nested_quoted_dl_actual" | pandoc -f markdown -t native)

TOTAL=$((TOTAL + 1))
if printf '%s\n' "$multi_item_actual" | grep -Fq 'middle # hash | pipe' \
  && printf '%s' "$multi_item_ast" | grep -q 'OrderedList' \
  && ! printf '%s' "$multi_item_ast" | grep -q 'CodeBlock' \
  && printf '%s\n' "$break_term_actual" | grep -Fq 'mitte # raute | pipe' \
  && printf '%s' "$break_term_ast" | grep -q 'DefinitionList' \
  && printf '%s\n' "$quoted_dl_actual" | grep -Fq 'mitte # raute | pipe' \
  && printf '%s' "$quoted_dl_ast" | grep -q 'DefinitionList' \
  && ! printf '%s' "$quoted_dl_ast" | grep -q 'CodeBlock' \
  && printf '%s\n' "$nested_quoted_dl_actual" | grep -Fq '> >' \
  && printf '%s\n' "$nested_quoted_dl_actual" | grep -Fq 'mitte # raute | pipe' \
  && [ "$(printf '%s\n' "$nested_quoted_dl_ast" | grep -Fc 'BlockQuote')" -ge 2 ] \
  && printf '%s' "$nested_quoted_dl_ast" | grep -q 'DefinitionList' \
  && ! printf '%s' "$nested_quoted_dl_ast" | grep -q 'CodeBlock'; then
  echo "✓ sonderlisten-mehrpunkt-und-verschachteltes-blockquote (echte Listen bleiben Listen)"
  PASSED=$((PASSED + 1))
else
  echo "✗ sonderlisten-mehrpunkt-und-blockquote"
  printf '%s\n' "$multi_item_actual" | sed 's/^/  a) /'
  printf '%s\n' "$break_term_actual" | sed 's/^/  b) /'
  printf '%s\n' "$quoted_dl_actual" | sed 's/^/  c) /'
  printf '%s\n' "$nested_quoted_dl_actual" | sed 's/^/  d) /'
  FAILED=$((FAILED + 1))
fi

# --- Test 10d: Marker-Grammatik gehört zum Zieldialekt und Blockkontext ---
# Derselbe HTML-Absatz muss in allen drei Zielen einen echten LineBreak behalten:
# `a.` direkt hinter `<br>` ist normaler Absatztext, auch wenn pandoc-Markdown
# alphabetische Listen grundsätzlich kennt. Außerdem darf `: ordinary` vor
# eingerücktem Code keinen falschen Listencontainer öffnen. Die positiven
# Listen-ASTs stellen sicher, dass die engere Erkennung echte Listen weiter
# schützt.
for target_format in gfm markdown commonmark; do
  hardbreak_actual=$(
    printf '%s' '<p>vorne<br>a. Text</p>' | convert_html "$target_format"
  )
  hardbreak_ast=$(printf '%s\n' "$hardbreak_actual" | pandoc -f "$target_format" -t native)

  marker_code_actual=$(
    printf '<p>: ordinary</p><pre><code>\\# keep\\\n\\- keep</code></pre>' | convert_html "$target_format"
  )
  marker_code_ast=$(printf '%s\n' "$marker_code_actual" | pandoc -f "$target_format" -t native)

  positive_list_actual=$(
    printf '%s' '<ul><li><p>eins<br>mitte # raute | pipe</p></li></ul><ol><li>zwei</li></ol>' \
      | convert_html "$target_format"
  )
  positive_list_ast=$(printf '%s\n' "$positive_list_actual" | pandoc -f "$target_format" -t native)

  TOTAL=$((TOTAL + 1))
  year_break_actual=$(
    printf '%s' '<p>Jahr<br>2024. war wichtig<br>3) Variante</p>' \
      | convert_html "$target_format"
  )
  year_break_ast=$(printf '%s\n' "$year_break_actual" | pandoc -f "$target_format" -t native)

  if printf '%s' "$hardbreak_ast" | grep -q 'LineBreak' \
    && [ "$(printf '%s' "$year_break_ast" | grep -c 'LineBreak')" -eq 2 ] \
    && ! printf '%s' "$hardbreak_ast" | grep -q 'SoftBreak' \
    && printf '%s\n' "$marker_code_actual" | grep -Fxq '    \# keep\' \
    && printf '%s\n' "$marker_code_actual" | grep -Fxq '    \- keep' \
    && printf '%s' "$marker_code_ast" | grep -q 'CodeBlock' \
    && printf '%s' "$positive_list_ast" | grep -q 'BulletList' \
    && printf '%s' "$positive_list_ast" | grep -q 'OrderedList' \
    && ! printf '%s' "$positive_list_ast" | grep -q 'CodeBlock'; then
    echo "✓ $target_format-markerkontext (Hard-Break, Code und Listenstruktur)"
    PASSED=$((PASSED + 1))
  else
    echo "✗ $target_format-markerkontext"
    printf '%s\n' "$hardbreak_ast" "$year_break_ast" "$marker_code_actual" "$positive_list_ast" \
      | sed 's/^/    /'
    FAILED=$((FAILED + 1))
  fi
done

# --- Test 10e: `1.`, `1)` und `-` direkt hinter einem Hard-Break ---
# Diese drei Marker unterbrechen in GFM und CommonMark einen laufenden Absatz,
# in pandoc-Markdown aber nicht. Das Zielformat entscheidet deshalb, was
# richtig ist: dort Absatz plus Liste, hier EIN Absatz mit echtem LineBreak.
# Der Fund vom 2026-08-21: Der Umbruch fiel in ALLEN Zielen weg und degradierte
# in pandoc-Markdown zum SoftBreak. Test 10d erreicht den Fall nicht, weil er
# nur `2024.` und `3)` verwendet — Marker, die keinen Absatz unterbrechen.
for target_format in gfm markdown commonmark; do
  TOTAL=$((TOTAL + 1))
  marker_break_ok=1
  marker_break_report=""
  for hard_break_marker in '1.' '1)' '-'; do
    marker_break_actual=$(
      printf '<p>Text<br>%s ordinary</p>' "$hard_break_marker" \
        | convert_html "$target_format"
    )
    marker_break_ast=$(
      printf '%s\n' "$marker_break_actual" | pandoc -f "$target_format" -t native
    )
    marker_break_report="$marker_break_report$hard_break_marker: $marker_break_ast"
    if [ "$target_format" = markdown ]; then
      printf '%s' "$marker_break_ast" | grep -q 'LineBreak' || marker_break_ok=0
      if printf '%s' "$marker_break_ast" | grep -q 'SoftBreak'; then
        marker_break_ok=0
      fi
    else
      printf '%s' "$marker_break_ast" \
        | grep -qE 'BulletList|OrderedList' || marker_break_ok=0
    fi
  done
  if [ "$marker_break_ok" -eq 1 ]; then
    echo "✓ $target_format-hardbreak-vor-listenmarker (Umbruch dialektgerecht)"
    PASSED=$((PASSED + 1))
  else
    echo "✗ $target_format-hardbreak-vor-listenmarker"
    printf '%s\n' "$marker_break_report" | sed 's/^/    /'
    FAILED=$((FAILED + 1))
  fi
done

# --- Test 10f: Hard-Break am Ende eines MEHRZEILIGEN Listenpunktes ---
# Der Umbruch vor dem naechsten Listenpunkt ist pandocs Layout und gehoert weg.
# Test 10e deckt nur die einzeilige Markerzeile ab; die Entscheidung haing bis
# zum Fund vom 2026-08-28 an „die Zeile davor beginnt mit einem Marker".
# Fortsetzungszeilen im offenen Listenpunkt sind das nicht — im Ziel `markdown`
# blieb dort ein sichtbarer Leerraum stehen, der beim erneuten Rendern als
# zusaetzliches `<br />` direkt vor `</li>` wieder auftauchte.
for target_format in gfm markdown commonmark; do
  TOTAL=$((TOTAL + 1))
  multiline_item_actual=$(
    printf '%s' '<ul><li>first<br>continuation<br></li><li>second</li></ul>' \
      | convert_html "$target_format"
  )
  multiline_item_ast=$(
    printf '%s\n' "$multiline_item_actual" | pandoc -f "$target_format" -t native
  )
  # Genau EIN LineBreak: der echte zwischen `first` und `continuation`.
  # Der zweite waere der Layout-Umbruch am Punktende.
  if [ "$(printf '%s' "$multiline_item_ast" | grep -c 'LineBreak')" -eq 1 ] \
    && printf '%s' "$multiline_item_ast" | grep -q 'BulletList' \
    && ! printf '%s\n' "$multiline_item_actual" | grep -q 'continuation  $'; then
    echo "✓ $target_format-mehrzeiliger-listenpunkt (Layout-Umbruch entfernt)"
    PASSED=$((PASSED + 1))
  else
    echo "✗ $target_format-mehrzeiliger-listenpunkt"
    printf '%s\n' "$multiline_item_actual" | sed 's/$/|/;s/^/    /'
    printf '%s\n' "$multiline_item_ast" | sed 's/^/    /'
    FAILED=$((FAILED + 1))
  fi
done

# --- Test 10f2: Tabellen überleben in jedem Zieldialekt (Review-Fund 2026-09-03) ---
# Drei Befunde stecken in diesem einen Fall, alle drei mit Totalverlust oder
# verschobenem Text:
#
#   1. gfm (Default) und commonmark schrieben statt der ganzen Tabelle den Text
#      `[TABLE]`, sobald EINE Zelle einen `<br>` oder zwei Absätze enthielt.
#      Mit --replace stand dieses Wort danach im Clipboard.
#   2. commonmark kennt ohne die Erweiterung `pipe_tables` gar keine
#      Tabellensyntax — dort war JEDE Tabelle `[TABLE]`.
#   3. Das Ziel `markdown` schrieb „simple"-Tabellen, deren Zeilen mit dem
#      Zellinhalt beginnen. tidy_markdown hielt sie für Fließtext und nahm den
#      Backslash vor dem `|` weg; weil die Spalten dort über die
#      Zeichenposition definiert sind, rutschte der Text der Folgespalte um ein
#      Zeichen nach links.
#
# Geprüft wird über den Rückweg nach HTML: Er zeigt Zellgrenzen und Zellinhalt
# zugleich und hängt nicht an der Spaltenbreite, die je nach pandoc-Version
# anders ausfallen kann.
table_source_html='<table><tr><th>Spalte</th><th>Wert</th></tr><tr><td>Pipe | und Raute #</td><td>ok</td></tr><tr><td>Erste Zeile<br>Zweite Zeile</td><td>zwei</td></tr><tr><td><p>Absatz eins</p><p>Absatz zwei</p></td><td>drei</td></tr></table>'
for target_format in gfm markdown commonmark; do
  TOTAL=$((TOTAL + 1))
  # Strenges CommonMark kennt keine Tabellen; zum Zurücklesen braucht der Leser
  # deshalb dieselbe Erweiterung, die pandoc_table_extensions beim Schreiben setzt.
  if [ "$target_format" = commonmark ]; then
    table_reader="commonmark+pipe_tables"
  else
    table_reader="$target_format"
  fi

  table_actual=$(printf '%s' "$table_source_html" | convert_html "$target_format")
  table_roundtrip=$(
    printf '%s\n' "$table_actual" | pandoc -f "$table_reader" -t html | tr -d '\n'
  )

  table_ok=1
  # Keine Zeile darf pandocs Platzhalter für „nicht darstellbar" sein.
  printf '%s\n' "$table_actual" | grep -Fq '[TABLE]' && table_ok=0
  # Die Escapes der Tabellenzeile bleiben stehen, Pipe und Raute kommen
  # ungekürzt in DERSELBEN Zelle wieder an.
  printf '%s' "$table_roundtrip" | grep -Fq '<td>Pipe | und Raute #</td>' || table_ok=0
  printf '%s' "$table_roundtrip" | grep -Fq '<td>ok</td>' || table_ok=0

  if [ "$target_format" = markdown ]; then
    # Gittertabellen können Absätze und Umbrüche in einer Zelle abbilden —
    # dort bleibt der Zellinhalt vollständig erhalten.
    printf '%s' "$table_roundtrip" | grep -Fq '<td>Erste Zeile<br />Zweite Zeile</td>' || table_ok=0
    printf '%s' "$table_roundtrip" | grep -Fq '<td><p>Absatz eins</p><p>Absatz zwei</p></td>' || table_ok=0
  else
    # Eine Pipe-Tabelle hat pro Zelle genau eine Zeile. inline_table_cells
    # macht aus jeder Blockgrenze ein Leerzeichen — der Text bleibt vollständig.
    printf '%s' "$table_roundtrip" | grep -Fq '<td>Erste Zeile Zweite Zeile</td>' || table_ok=0
    printf '%s' "$table_roundtrip" | grep -Fq '<td>Absatz eins Absatz zwei</td>' || table_ok=0
  fi

  # Zweiter Fall, eigens für Befund 3: eine Tabelle aus kurzen, einzeiligen
  # Zellen. Genau dafür schrieb das Ziel `markdown` früher eine „simple"-Tabelle
  # ohne führendes `|`. Die Tabelle oben trifft den Fall nicht — ihre Zellen mit
  # Absatz und Umbruch erzwingen schon eine Gittertabelle.
  simple_table_actual=$(
    printf '%s' '<table><tr><th>A</th><th>B</th></tr><tr><td>x|y</td><td>ok</td></tr></table>' \
      | convert_html "$target_format"
  )
  simple_table_roundtrip=$(
    printf '%s\n' "$simple_table_actual" | pandoc -f "$table_reader" -t html | tr -d '\n'
  )
  printf '%s' "$simple_table_roundtrip" | grep -Fq '<td>x|y</td><td>ok</td>' || table_ok=0

  if [ "$table_ok" -eq 1 ]; then
    echo "✓ $target_format-tabellenzellen (Zellgrenzen und Zellinhalt bleiben)"
    PASSED=$((PASSED + 1))
  else
    echo "✗ $target_format-tabellenzellen"
    printf '%s\n' "$table_actual" | sed 's/^/    /'
    printf '%s\n' "$table_roundtrip" | sed 's/^/    HTML: /'
    printf '%s\n' "$simple_table_actual" | sed 's/^/    kurz: /'
    printf '%s\n' "$simple_table_roundtrip" | sed 's/^/    kurz-HTML: /'
    FAILED=$((FAILED + 1))
  fi
done

# --- Test 10f3: Die Pipeline kommt mit Perl-Bordmitteln aus (Review-Fund 2026-09-03) ---
# Debian und Ubuntu liefern nur `perl-base` als Pflichtpaket aus; Module wie
# Encode stecken erst im vollen `perl`-Paket. `command -v perl` bestand deshalb
# auf einem schlanken System, und trotzdem brach jede Konvertierung mit
# „Can't locate Encode.pm in @INC" ab. Im Ubuntu-24.04-Container belegt.
#
# Erste Probe, funktional: ein absichtlich kaputtes Encode.pm ganz vorn in
# @INC. Wer das Modul wieder anfasst, merkt es hier sofort.
perl_core_root="$TEST_RUNTIME/perl-core"
mkdir -p "$perl_core_root"
cat > "$perl_core_root/Encode.pm" <<'POISON'
package Encode;
die "Encode ist auf einem schlanken Linux nicht installiert";
POISON

TOTAL=$((TOTAL + 1))
perl_core_ok=1
perl_core_report=""
perl_core_actual=$(
  export PERL5LIB="$perl_core_root${PERL5LIB:+:$PERL5LIB}"
  printf '%s' '<p>Text mit &nbsp; und Umlaut ä</p>' | convert_html gfm 2>&1
) || perl_core_ok=0
printf '%s' "$perl_core_actual" | grep -Fq 'Umlaut ä' || perl_core_ok=0
if [ "$perl_core_ok" -eq 0 ]; then
  perl_core_report="ohne Encode: $perl_core_actual"
fi

# Zweite Probe, als Vertrag: In den Perl-Schnipseln der Pipeline und der CLI
# darf ausser strict und warnings kein Modul geladen werden. Das deckt auch
# das nächste Modul ab, für das es hier kein eigenes kaputtes Encode.pm gibt.
perl_module_uses=$(
  grep -nE "^[[:space:]]*(use|require)[[:space:]]+[A-Z]" \
    "$PROJECT_ROOT/lib/pipeline.sh" "$PROJECT_ROOT/bin/md-clip" \
    | grep -vE "(use|require)[[:space:]]+(strict|warnings)\b" || true
)
if [ -n "$perl_module_uses" ]; then
  perl_core_ok=0
  perl_core_report="$perl_core_report
Modul ausserhalb von perl-base geladen:
$perl_module_uses"
fi

if [ "$perl_core_ok" -eq 1 ]; then
  echo "✓ perl-bordmittel (Pipeline laeuft ohne Encode und ohne Zusatzmodule)"
  PASSED=$((PASSED + 1))
else
  echo "✗ perl-bordmittel"
  printf '%s\n' "$perl_core_report" | sed 's/^/    /'
  FAILED=$((FAILED + 1))
fi

# --- Test 10g: unsichtbarer Inhalt gilt als leer ---
# `require_nonempty_markdown` muss Exit 1 liefern, damit der Auto-Pfad auf den
# vorhandenen Plain-Text zurueckfaellt und --replace das Clipboard nicht durch
# Unsichtbares ersetzt. Die frueher handgepflegte Liste kannte nur
# U+200B..U+200D, U+2060 und U+FEFF; Richtungszeichen, unsichtbare Operatoren
# und Variation Selectors rutschten als „sichtbarer Inhalt" durch
# (Review-Fund 2026-08-28).
TOTAL=$((TOTAL + 1))
invisible_ok=1
invisible_report=""
for invisible_entity in '&lrm;' '&rlm;' '&#x2061;' '&#xFE0F;' '&#xAD;' '&nbsp;' '&#x200B;'; do
  if printf '<p>%s</p>' "$invisible_entity" | convert_html gfm >/dev/null 2>&1; then
    invisible_ok=0
    invisible_report="$invisible_report$invisible_entity galt als sichtbar
"
  fi
done
# Gegenprobe: echter Text darf NICHT als leer gelten.
if ! printf '<p>echter Text</p>' | convert_html gfm >/dev/null 2>&1; then
  invisible_ok=0
  invisible_report="${invisible_report}echter Text galt als leer
"
fi
if [ "$invisible_ok" -eq 1 ]; then
  echo "✓ unsichtbarer-inhalt (Richtungszeichen, Operatoren, Variation Selectors)"
  PASSED=$((PASSED + 1))
else
  echo "✗ unsichtbarer-inhalt"
  printf '%s' "$invisible_report" | sed 's/^/    /'
  FAILED=$((FAILED + 1))
fi

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

  # --- Roundtrip 1c: beschaedigter BOM-HTML-Flavor (nur macOS) ---
  # Eine BOM ist eine verbindliche Kodierungsangabe. Passt sie nicht zum Inhalt,
  # muss clipboard-html mit Exit 1 abbrechen, damit der Auto-Pfad den
  # vorhandenen Plain-Text nimmt. Bis zum Fund vom 2026-08-28 lief der Fall bis
  # zum Latin-1-Zweig durch und lieferte Zeichensalat mit Exit 0 — md-clip hielt
  # das fuer brauchbaren Rich Text und ersetzte mit --replace das Clipboard
  # damit. Die Bytes ff fe 00 d8 sind eine UTF-16-LE-BOM plus ein einzelnes
  # High-Surrogate ohne Partner, also ungueltiges UTF-16.
  if [ "$PLATFORM" = "macos" ]; then
    TOTAL=$((TOTAL + 1))
    BROKEN_BOM_HTML="$TEST_RUNTIME/broken-bom.html"
    BROKEN_BOM_PLAIN="$TEST_RUNTIME/broken-bom.txt"
    printf '\377\376\000\330' > "$BROKEN_BOM_HTML"
    printf 'reiner Text' > "$BROKEN_BOM_PLAIN"
    "$LOAD_CLIPBOARD_BIN" \
      public.html "$BROKEN_BOM_HTML" \
      public.utf8-plain-text "$BROKEN_BOM_PLAIN" >/dev/null

    BROKEN_BOM_EXPECTED_FILE="$TEST_RUNTIME/broken-bom.expected"
    BROKEN_BOM_ACTUAL_FILE="$TEST_RUNTIME/broken-bom.actual"
    # Der Plain-Text-Fallback reicht das Clipboard unveraendert durch —
    # ohne das Schluss-LF, das die HTML-Strecke zusichert.
    printf 'reiner Text' > "$BROKEN_BOM_EXPECTED_FILE"
    "$PRODUCT_CLI" --quiet > "$BROKEN_BOM_ACTUAL_FILE" 2>/dev/null || true

    if cmp -s "$BROKEN_BOM_EXPECTED_FILE" "$BROKEN_BOM_ACTUAL_FILE"; then
      echo "✓ broken-bom-html (kaputte BOM faellt auf Plain-Text zurueck)"
      PASSED=$((PASSED + 1))
    else
      echo "✗ broken-bom-html"
      echo "  Erwartete Bytes:"
      xxd "$BROKEN_BOM_EXPECTED_FILE" | sed 's/^/    /'
      echo "  Erhaltene Bytes:"
      xxd "$BROKEN_BOM_ACTUAL_FILE" | sed 's/^/    /'
      FAILED=$((FAILED + 1))
    fi
  fi

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
    UTF16_EXPECTED_FILE="$TEST_RUNTIME/utf16.expected"
    UTF16_ACTUAL_FILE="$TEST_RUNTIME/utf16.actual"
    printf '%s' "$ENCODING_EXPECTED" > "$UTF16_EXPECTED_FILE"
    "$PRODUCT_CLI" --replace --quiet
    clip_get_text > "$UTF16_ACTUAL_FILE"

    if cmp -s "$UTF16_EXPECTED_FILE" "$UTF16_ACTUAL_FILE"; then
      echo "✓ utf16-html-clipboard (Firefox-Fall: UTF-16-HTML korrekt gelesen)"
      PASSED=$((PASSED + 1))
    else
      echo "✗ utf16-html-clipboard"
      echo "  Erwartet:  '$ENCODING_EXPECTED'"
      echo "  Erwartete Bytes:"
      xxd "$UTF16_EXPECTED_FILE" | sed 's/^/    /'
      echo "  Erhaltene Bytes:"
      xxd "$UTF16_ACTUAL_FILE" | sed 's/^/    /'
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
