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

# Dupliziert aus bin/md-clip — schreibt die RTF-Kurzform „Backslash am
# Zeilenende" in das Steuerwort \par um, das pandocs RTF-Reader versteht.
# Siehe bin/md-clip für die ausführliche Doku.
rtf_fix_escaped_newlines() {
  perl -0pe 's/(?<!\\)((?:\\\\)*)\\(\r?\n)/$1\\par$2/g'
}

# Dupliziert aus bin/md-clip — RTF nach HTML, plattformabhängig.
# macOS: textutil (Bordmittel). Linux: pandocs RTF-Reader + Spec-Korrektur.
rtf_to_html() {
  if [ "$PLATFORM" = "macos" ]; then
    textutil -convert html -format rtf -stdin -stdout
  else
    rtf_fix_escaped_newlines | pandoc -f rtf -t html
  fi
}

# Dupliziert aus bin/md-clip — entfernt Tabellen-Tags aus textutil-/pandoc-HTML,
# Zellen werden zu Absätzen. Siehe bin/md-clip für die ausführliche Doku.
flatten_layout_tables() {
  perl -0pe '
    s{<colgroup[^>]*>.*?</colgroup>}{}gs;
    s{<col[^/]*/?>}{}g;
    s{</?table[^>]*>}{}gs;
    s{</?t(?:body|head|foot)[^>]*>}{}gs;
    s{</?tr[^>]*>}{}gs;
    s{<t[dh][^>]*>}{<p>}gs;
    s{</t[dh]>}{</p>}gs;
  '
}

# Dupliziert aus bin/md-clip — <li><p>Text</p></li> → <li>Text</li>, damit
# pandocs RTF-Reader keine lose Liste erzeugt. Siehe bin/md-clip für die Doku.
unwrap_list_paragraphs() {
  perl -0pe 's{<li([^>]*)>\s*<p[^>]*>([^<]*)</p>\s*</li>}{<li$1>$2</li>}gs'
}

# Dupliziert aus bin/md-clip — kosmetische Säuberung nach RTF-Konversion.
tidy_rtf_artifacts() {
  perl -0pe '
    s/^\\\s*$//gm;
    s/\n{3,}/\n\n/g;
  '
}

# Dupliziert aus bin/md-clip — der vollständige RTF-Pfad. Bewusst als ganze
# Kette (nicht nur rtf_to_html + pandoc), damit der Test wirklich das prüft,
# was im echten Lauf passiert.
convert_rtf() {
  rtf_to_html \
    | flatten_layout_tables \
    | unwrap_list_paragraphs \
    | clean_html \
    | pandoc "${PANDOC_OPTS[@]}" \
    | tidy_rtf_artifacts \
    | fix_empty_links \
    | tidy_hard_breaks
}

# Dupliziert aus bin/md-clip — füllt leeren Anker-Text `[](url)` mit der
# Ziel-URL, damit der Link in allen Renderern sichtbar bleibt.
fix_empty_links() {
  perl -0pe 's{(?<!!)\[\s*\]\(\s*(\S+?)(\s+[^)]*)?\)}{ "[$1]($1" . (defined $2 ? $2 : "") . ")" }gex'
}

# Dupliziert aus bin/md-clip — entfernt überflüssige Hard-Break-Backslashes
# an Absatz-/Listengrenzen und am Dokument-Ende (auch aus <br><br>).
# Hard-Breaks in Fließtext (z.B. Adressen) bleiben. Siehe bin/md-clip für
# die ausführliche Doku.
tidy_hard_breaks() {
  perl -0pe '
    s/[ \t]*(?:\\|[ ]{2,})\n(?=[ \t]*(?:[-*+] |\d+[.)] ))/\n/g;
    s/^[ \t]*\\?[ \t]*$//gm;
    s/[ \t]*(?:\\|[ ]{2,})\n(?=[ \t]*\n)/\n/g;
    s/\n{3,}/\n\n/g;
    s/[ \t]*(?:\\|[ ]{2,})[ \t]*(\n*)\z/$1/;
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
# Der komplette RTF-Pfad, so wie ihn bin/md-clip fährt.
#
# Hier laufen zwei VERSCHIEDENE RTF-Parser gegen dieselbe Erwartung: macOS
# nutzt textutil (Apples eigener), Linux pandocs RTF-Reader. Dass beide
# dieselbe Datei erfüllen müssen, ist Absicht — dieser Test ist die
# Absicherung dafür, dass dasselbe RTF auf beiden Plattformen dasselbe
# Markdown ergibt. Er ist damit der eigentliche Wächter über
# rtf_fix_escaped_newlines und unwrap_list_paragraphs: Fällt eine der beiden
# Korrekturen weg, wird dieser Test auf Linux rot.
actual=$(cat "$FIXTURES/word-rtf.rtf" | convert_rtf)
run_test "word-rtf (RTF-Pfad, $PLATFORM)" \
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

# --- Test 7: Trailing-Hard-Break am Dokument-Ende ---
# Ein abschließendes <br> beim Copy erzeugt einen Hard-Break-Marker am
# Dokument-Ende. Im `--to markdown`-Dialekt ist dieser Marker ein sichtbarer
# `\` — die häufigste Quelle überzähliger Backslashes. tidy_hard_breaks muss
# NUR den letzten (sinnlosen) Marker entfernen; die echten Hard-Breaks in den
# Zeilen davor (mehrzeilige Adresse) MÜSSEN als `\` erhalten bleiben.
# Bewusst mit `-t markdown` (statt Default gfm), weil nur dieser Dialekt den
# Hard-Break als sichtbaren `\` schreibt — gfm/commonmark nutzen zwei
# (unsichtbare) Leerzeichen, die ein Expected-File nicht stabil abbilden kann.
PANDOC_OPTS_MD=(-f html -t markdown-raw_html --wrap=none)
actual=$(cat "$FIXTURES/trailing-hardbreak.html" \
  | clean_html \
  | pandoc "${PANDOC_OPTS_MD[@]}" \
  | fix_empty_links \
  | tidy_hard_breaks)
run_test "trailing-hardbreak (abschließendes <br> → kein End-Backslash)" \
  "$actual" \
  "$FIXTURES/trailing-hardbreak.expected.md"

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
  if [ "$PLATFORM" = "macos" ]; then
    return 0
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
  CLIPBOARD_BACKUP="$(mktemp)"

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
    # Swift-Helper bauen, falls nicht da.
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

  # EXIT-Trap: unter dem aktiven `set -euo pipefail` reicht ein Nicht-Null-Exit
  # von md-clip (unten) oder ein Ctrl-C, um das Skript sofort abzubrechen. Ohne
  # Trap bliebe dann das Test-HTML im Nutzer-Clipboard liegen und die Temp-
  # Dateien würden leaken. Der Trap restauriert das Clipboard und räumt auf —
  # egal, wie das Skript endet. Die `${...:-}` decken den Fall ab, dass der
  # Abbruch passiert, bevor die Variablen gesetzt wurden (set -u).
  trap 'clip_put_text_file "$CLIPBOARD_BACKUP" 2>/dev/null || true; rm -f "$CLIPBOARD_BACKUP" "${ENCODING_HTML:-}" "${UTF16_HTML:-}"' EXIT

  # --- Roundtrip 1: UTF-8-HTML durch die volle Kette ---
  ENCODING_HTML="$(mktemp).html"
  printf '%s' "$ENCODING_INPUT" > "$ENCODING_HTML"

  clip_put_html "$ENCODING_HTML"

  # Vollständige Kette laufen lassen, --replace schreibt Ergebnis ins Clipboard.
  "$PROJECT_ROOT/bin/md-clip" --replace --quiet

  encoding_actual="$(clip_get_text)"

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

  # --- Roundtrip 2: UTF-16-HTML (Firefox-Fall, nur Linux) ---
  # Firefox legt sein text/html unter Linux als UTF-16 mit BOM aufs Clipboard,
  # Chromium als UTF-8. md-clip muss BEIDE lesen können (siehe to_utf8 in
  # bin/md-clip). Wir erzeugen die UTF-16-Variante hier selbst mit iconv, statt
  # einen echten Firefox zu starten: Es geht um die BYTES auf dem Clipboard,
  # und die sind so exakt reproduzierbar — headless, ohne Browser, in CI.
  # Auf macOS gibt es diesen Fall nicht (NSPasteboard liefert immer UTF-8).
  if [ "$PLATFORM" = "linux" ]; then
    UTF16_HTML="$(mktemp).html"
    printf '%s' "$ENCODING_INPUT" | iconv -f UTF-8 -t UTF-16 > "$UTF16_HTML"

    clip_put_html "$UTF16_HTML"
    utf16_actual="$("$PROJECT_ROOT/bin/md-clip" --quiet)"

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
