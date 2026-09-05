#!/usr/bin/env bash
# Gemeinsame, seiteneffektfreie Konvertierungs-Pipeline für Produkt und Tests.
# Aufrufer übergeben das Zielformat als Argument an convert_html/convert_rtf und
# stellen die plattformspezifische Funktion rtf_to_html bereit. Beim Sourcen wird
# weder Clipboard noch Dateisystem berührt.
#
# Das Zielformat wird bewusst NUR EINMAL übergeben: pandoc-Optionen und die
# Grammatik der Nachbearbeitung (tidy_markdown) leiten sich beide daraus ab.
# Vorher waren das zwei unabhängige Zustände — `PANDOC_OPTS` und `TO` —, die
# auseinanderlaufen konnten: pandoc schrieb dann etwa eine alphabetische
# markdown-Liste, während tidy_markdown sie als GFM aufräumte und deren
# Schutz-Backslashes stehen ließ (Review-Fund 2026-08-17).

case "${BASH_SOURCE[0]}" in
  */*) _MD_CLIP_LIB_DIR="${BASH_SOURCE[0]%/*}" ;;
  *) _MD_CLIP_LIB_DIR=. ;;
esac
case "$_MD_CLIP_LIB_DIR" in
  /*) ;;
  *) _MD_CLIP_LIB_DIR="$PWD/$_MD_CLIP_LIB_DIR" ;;
esac

preprocess_claude_desktop() {
  perl -0pe 's{<div\s+data-line="[^"]*"[^>]*>(.*?)</div>}{$1\n}gs;

        s{(<pre[^>]*>.*?</pre>)}{
          my $block = $1;
          $block =~ s{</?div[^>]*>}{}g;
          $block;
        }gse;
        # Claude-Desktop-Attribute nur aus echten HTML-Tags entfernen. Eine
        # globale Ersetzung traf bisher auch Fließtext und maskiertes HTML in
        # Code-Beispielen. pre-/code-INHALTE bleiben deshalb roh; deren
        # öffnende Tags werden weiter bereinigt, weil etwa ein style-Attribut
        # am <pre> pandocs Sprachklasse am <code> verdeckt.
        s{(<[^>]+>)}{
          my $tag = $1;
          $tag =~ s/\s+(?:style|data-[a-z-]+)="[^"]*"//gi;
          $tag;
        }gise
      '
}

preprocess_google_classroom() {
  perl -0777 -pe '
    s{<a\b([^>]*)\bhref="([^"]*)"([^>]*)>(.*?)</a>}{
      my ($pre, $href, $post, $inner) = ($1, $2, $3, $4);
      if ($inner =~ m{classroom\.google\.com/webthumbnail}) {
        my $title = ($inner =~ m{class="[^"]*\bmvRF3b\b[^"]*">(.*?)</div>}s) ? $1 : "";
        $title =~ s/<[^>]+>//g;
        $title =~ s/^\s+|\s+$//g;
        # Den Google-Kontowähler entfernen, ohne Fragment oder folgende
        # Query-Parameter zu verlieren. Bei `?authuser=0&x=1` muss das `?`
        # für den verbleibenden Parameter stehen bleiben.
        $href =~ s{&amp;}{&}gi;
        $href =~ s{([?&])authuser=[^&#]*&}{$1}g;
        $href =~ s{[?&]authuser=[^&#]*}{}g;
        $href =~ s{\?&}{?}g;
        $href =~ s{[?&](?=#|$)}{}g;
        $title ne ""
          ? "<li data-md-clip-classroom=\"1\"><a href=\"$href\">$title</a></li>"
          : "<a href=\"$href\"></a>";
      } else {
        $&;
      }
    }gse;
    s{<img[^>]*classroom\.google\.com/webthumbnail[^>]*>}{}gs;
    1 while s{<div\b[^>]*>\s*</div>}{}gs;

    # Nur von uns erzeugte Classroom-Punkte zusammenziehen. Normale <li>
    # in vorhandenen <ol>/<ul> bleiben samt Listentyp und Struktur erhalten.
    1 while s{(<li\b[^>]*data-md-clip-classroom="1"[^>]*>.*?</li>)(?:\s*</?div[^>]*>\s*)+(?=<li\b[^>]*data-md-clip-classroom="1")}{${1}}gs;
    s{(?:<li\b[^>]*data-md-clip-classroom="1"[^>]*>.*?</li>\s*)+}{
      my $items = $&;
      $items =~ s/\s+data-md-clip-classroom="1"//g;
      $items =~ s/>\s+</></g;
      "<ul>$items</ul>";
    }gse;
  '
}

# Füllt leere HTML-Anker VOR pandoc. Dadurch müssen wir keine Markdown-URLs
# mit verschachtelten Klammern, Titeln oder Escapes selbst parsen.
#
# „Leer" heißt: der Anker hat keinen sichtbaren Text. Das gilt auch für den
# üblichen Icon-Link `<a href="…"><i class="icon"></i></a>` — die Auszeichnung
# darin bringt in Markdown nichts mit, pandoc schriebe daraus ein unsichtbares
# `[](…)`. Ein Anker um ein Bild bleibt dagegen unangetastet: das Bild IST der
# sichtbare Inhalt und wird zu `[![alt](bild)](ziel)`.
#
# Dasselbe gilt für ein eingebettetes `<svg>`: pandoc macht daraus ein Bild mit
# `data:`-URL, auch außerhalb eines Ankers. Ohne die Ausnahme ersetzte diese
# Funktion die komplette Grafik durch den nackten URL-Text — der Icon-Link mit
# Inline-SVG ist im Web der Normalfall, nicht der Sonderfall (Review-Fund
# 2026-08-05, am Verhalten von pandoc 3.9 belegt). `<video>`, `<audio>` und
# `<object>` bleiben bewusst draußen: aus ihnen macht pandoc gar nichts
# Sichtbares, dort ist der URL-Text die bessere Ausgabe.
fill_empty_html_links() {
  perl -0pe '
    s{<a\b([^>]*\bhref\s*=\s*(?:"([^"]*)"|\x27([^\x27]*)\x27)[^>]*)>(.*?)</a>}{
      my $whole = $&;
      my ($attributes, $inner) = ($1, $4);
      my $href = defined($2) ? $2 : $3;
      my $visible = $inner;
      $visible =~ s/<[^>]*>//g;        # Tags tragen selbst keinen Text bei
      $visible =~ s/&nbsp;/ /gi;
      $visible =~ s/\s+//g;
      # Span verhindert pandocs Autolink-Kürzung, die Link-Titel verwirft.
      ($visible eq q{} && $inner !~ /<(?:img|svg)\b/i)
        ? "<a$attributes><span>$href</span></a>"
        : $whole
    }gise
  '
}

clean_html() {
  sed -E 's/<span[^>]*>([^<]*)<\/span>/\1/g' \
    | sed -E 's/<span[^>]*>([^<]*)<\/span>/\1/g'
}

rtf_fix_escaped_newlines() {
  perl -0pe 's/(?<!\\)((?:\\\\)*)\\(\r?\n)/$1\\par$2/g'
}

flatten_layout_tables() {
  perl -0pe '
    my $cursor = 0;

    while (1) {
      pos($_) = $cursor;
      last unless m{<table\b[^>]*>}ig;

      my ($start, $after_open) = ($-[0], $+[0]);
      my $depth = 1;
      my $end;
      pos($_) = $after_open;

      while (m{</?table\b[^>]*>}ig) {
        my ($tag, $tag_end) = ($&, $+[0]);
        if ($tag =~ m{^</}i) {
          $depth--;
          if ($depth == 0) {
            $end = $tag_end;
            last;
          }
        } else {
          $depth++;
        }
      }

      # Kaputtes HTML nicht durch eine halb angewandte Reparatur verschlimmern.
      last unless defined $end;

      my $table = substr($_, $start, $end - $start);
      my $inside = substr($table, index($table, q{>}) + 1);
      $inside =~ s{</table>\s*\z}{}i;

      my $nested = $inside =~ /<table\b/i;
      my $has_heading = $inside =~ /<th\b/i;
      my $has_multi_cell_row = 0;
      while ($inside =~ m{<tr\b[^>]*>(.*?)</tr>}gis) {
        my $row = $1;
        my $cells = () = $row =~ /<t[dh]\b/gi;
        $has_multi_cell_row = 1 if $cells >= 2;
      }

      # Nur Layout-Tabellen plätten: verschachtelte Konstrukte sowie
      # einspaltige Tabellen ohne Kopfzelle. Echte Datenmatrizen bleiben für
      # pandoc als Tabelle erhalten, damit Zeilen und Spalten nicht zerfallen.
      if ($nested || (!$has_heading && !$has_multi_cell_row)) {
        my $replacement = $table;
        $replacement =~ s{<colgroup\b[^>]*>.*?</colgroup>}{}gis;
        $replacement =~ s{</?colgroup\b[^>]*>}{}gi;
        $replacement =~ s{<col\b[^>]*>}{}gi;
        $replacement =~ s{</?table\b[^>]*>}{}gi;
        $replacement =~ s{</?t(?:body|head|foot)\b[^>]*>}{}gi;
        $replacement =~ s{</?tr\b[^>]*>}{}gi;
        $replacement =~ s{<t[dh]\b[^>]*>}{<p>}gi;
        $replacement =~ s{</t[dh]>}{</p>}gi;
        if (my $path = $ENV{MD_CLIP_RESULT_FILE}) {
          open(my $status, q{>}, $path) or die "Statusdatei: $!";
          print {$status} "simplified\n";
          close($status) or die "Statusdatei: $!";
        }
        substr($_, $start, $end - $start, $replacement);
        $cursor = $start + length($replacement);
      } else {
        $cursor = $end;
      }
    }
  '
}

unwrap_list_paragraphs() {
  perl -0pe '
    s{<li([^>]*)>\s*<p[^>]*>((?:(?!<p\b|</p>).)*)</p>\s*</li>}{<li$1>$2</li>}gis
  '
}

# tidy_markdown: Räumt pandocs Markdown-Ausgabe auf. Das ist die einzige
# Stelle, an der wir das fertige Markdown noch anfassen.
#
# Drei Aufgaben:
#   1. Hard-Breaks. Einen Zeilenumbruch innerhalb eines Absatzes schreibt
#      pandoc als Backslash am Zeilenende — der ist im Ergebnis sichtbar.
#      Wir schreiben stattdessen zwei Leerzeichen: in Markdown dieselbe
#      Bedeutung, aber unsichtbar. Umbrüche, die nur Layout waren (vor einer
#      Leerzeile, vor einem Listenpunkt, am Dokumentende), fallen ganz weg.
#   2. Escapes zurücknehmen, die getippte Marker unlesbar machen: `\-` am
#      Zeilenanfang, eine Trennlinie aus `\_\_\_`, und ein Absatz, der nur
#      aus einem fett gesetzten Bullet besteht (`**•**` → `-`).
#   3. Mehr als eine Leerzeile hintereinander zusammenziehen.
#
# WICHTIG: Nichts davon darf Code-Blöcke anfassen. Dort ist ein Backslash am
# Zeilenende echter Inhalt (Shell-Fortsetzung), und `\-` echter Code. Der
# erste Durchlauf markiert deshalb alle Code-Zeilen — eingezäunte (``` oder
# ~~~) genauso wie eingerückte (vier Leerzeichen) — und alle Aufräumregeln
# überspringen sie.
tidy_markdown() {
  local target_format="${1:-gfm}"
  case "$target_format" in
    gfm|markdown|commonmark) ;;
    *)
      printf 'tidy_markdown: unbekanntes Zielformat: %s\n' "$target_format" >&2
      return 2
      ;;
  esac

  perl "$_MD_CLIP_LIB_DIR/tidy-markdown.pl" "$target_format"
}

pandoc_supports_rtf() {
  pandoc --list-input-formats 2>/dev/null | grep -Fxq 'rtf'
}

# `--sandbox` gibt es erst ab pandoc 2.15. Ältere Fassungen bestehen den
# RTF-Test, brechen danach aber JEDE Konvertierung mit „Unknown option
# --sandbox" ab. Die Option ist kein Komfort, sondern die Zusicherung, dass
# eingebettete Frames und Ressourcen keinen Netzabruf auslösen — sie darf
# deshalb nicht still entfallen, sondern muss vorab geprüft werden.
pandoc_supports_sandbox() {
  printf '' | pandoc --sandbox -f html -t plain >/dev/null 2>&1
}

# Doctor prüft mit einem echten Tabellenknoten die verwendete Lua-API.
# Kein eigener Dokumentinhalt, keine Netzwerk- oder Clipboard-Operation.
pandoc_supports_table_filter() {
  printf '%s' '<table><tr><th>A</th></tr><tr><td>x<br>y</td></tr></table>' \
    | MD_CLIP_RESULT_FILE= pandoc --sandbox -f html -t gfm-raw_html \
      --lua-filter="$_MD_CLIP_LIB_DIR/tables.lua" >/dev/null 2>&1
}

# Der einzige pandoc-Aufruf der HTML→Markdown-Strecke. Beide Konvertierungen
# gehen hier durch, damit die Optionen nur an einer Stelle stehen:
#   -f html            : HTML als Eingabeformat.
#   -t <ziel>-raw_html : Ziel-Markdown ohne raw_html-Extension — nicht
#                        abbildbare HTML-Tags werden verworfen statt
#                        durchgereicht.
#   --wrap=none        : kein Auto-Umbruch bei ~78 Zeichen.
#   --sandbox          : eingebettete Frames/Ressourcen dürfen beim reinen
#                        Clipboard-Konvertieren keinen Netzabruf auslösen.
# Entscheidend ist, dass `-t` und tidy_markdown dasselbe `$target_format`
# benutzen; ein zweiter, getrennt gesetzter Zustand darf es nicht geben.
# Deshalb ist das hier eine Funktion und keine zweimal hingeschriebene
# Optionsliste: Wer die Optionen ändert, ändert sie für beide Wege zugleich.

# Tabellen-Erweiterungen je Zielformat. Sie sorgen dafür, dass eine Tabelle in
# JEDEM Ziel als Pipe- oder Gittertabelle herauskommt — also mit `|` am Anfang
# jeder Inhaltszeile. Genau daran erkennt tidy_markdown eine Tabellenzeile und
# lässt deren Escapes stehen. Ohne diese Angleichung:
#
#   markdown    schrieb „simple"- und „multiline"-Tabellen, deren Zeilen mit
#               dem Zellinhalt beginnen. tidy_markdown hielt sie für Fließtext,
#               nahm das `\` vor einem `|` weg, und weil die Spalten dort über
#               die Zeichenposition definiert sind, rutschte der Text der
#               nächsten Spalte um ein Zeichen nach links: aus den Zellen
#               `x|y` und `ok` wurde `x|y o` und `k` (im AST belegt,
#               Review-Fund 2026-09-03).
#   commonmark  kennt ohne `pipe_tables` gar keine Tabellensyntax. Weil
#               `raw_html` bewusst abgeschaltet ist, schrieb pandoc statt der
#               Tabelle den Text `[TABLE]` — die Tabelle war komplett weg.
pandoc_table_extensions() {
  case "${1:-gfm}" in
    # Gittertabellen bleiben an: Nur sie können eine Zelle mit mehreren
    # Absätzen oder einem Zeilenumbruch abbilden, und ihre Inhaltszeilen
    # beginnen ebenfalls mit `|`.
    markdown)   printf '%s' '-simple_tables-multiline_tables' ;;
    commonmark) printf '%s' '+pipe_tables' ;;
    *)          printf '%s' '' ;;
  esac
}

run_pandoc() {
  local target_format="${1:-gfm}" table_extensions
  table_extensions="$(pandoc_table_extensions "$target_format")"
  # Ein einziger gepufferter Scan statt Tempdatei, cat und grep. Die
  # Entscheidung über Darstellbarkeit trifft weiterhin allein der AST-Filter.
  # Kommentare/Attribute dürfen falsch positiv treffen; mehrzeilige Tags
  # müssen erfasst werden. Listenform von open übergibt Argumente ohne Shell.
  perl -0777 -e '
    my ($target, $filter) = @ARGV;
    my $html = do { local $/; <STDIN> } // q{};
    my @args = (q{pandoc}, q{-f}, q{html}, q{-t}, $target,
                q{--wrap=none}, q{--sandbox});
    push @args, qq{--lua-filter=$filter} if $html =~ /<table(?=[\s\/>])/i;
    open(my $writer, q{|-}, @args) or die "pandoc: $!";
    print {$writer} $html or die "pandoc stdin: $!";
    close($writer) or exit 1;
  ' "${target_format}-raw_html${table_extensions}" "$_MD_CLIP_LIB_DIR/tables.lua"
}

# Pandoc schreibt auch für HTML ohne darstellbaren Inhalt ein Schluss-LF.
# Der Filter puffert nur die fertige Markdown-Ausgabe und meldet whitespace-only
# als Fehler, damit der Auto-Pfad auf den vorhandenen Plain-Text zurückfallen
# kann und --replace niemals unbemerkt das Clipboard leert.
require_nonempty_markdown() {
  # `\S` auf rohen Bytes hielt die zwei UTF-8-Bytes des geschützten
  # Leerzeichens U+00A0 (0xC2 0xA0) für sichtbaren Inhalt. Ein Rich-Text-
  # Flavor, der nur ein `&nbsp;` enthält, unterdrückte damit den vorhandenen
  # Plain-Text-Fallback und ersetzte mit --replace das Clipboard durch
  # Unsichtbares. Deshalb wird der Text zum Prüfen als UTF-8 dekodiert und
  # gegen die Unicode-Eigenschaft White_Space geprüft; ausgegeben werden
  # weiterhin exakt die eingelesenen Bytes.
  #
  # `utf8::decode` statt `Encode::decode`: Debian und Ubuntu liefern das Modul
  # Encode NICHT im Paket `perl-base` aus, sondern erst mit dem vollen
  # `perl`-Paket. Auf einem schlanken System (Container, Server) besteht
  # `command -v perl` deshalb, und trotzdem brach danach JEDE Konvertierung mit
  # „Can't locate Encode.pm" ab (im Ubuntu-24.04-Container belegt, Review-Fund
  # 2026-09-03). `utf8::decode` ist dagegen im Perl-Kern eingebaut, dekodiert
  # in-place und liefert wie das frühere FB_CROAK genau dann falsch, wenn die
  # Bytes kein gültiges UTF-8 sind.
  perl -0e '
    my $text = do { local $/; <STDIN> };
    print $text;
    my $decoded = $text;
    $decoded = $text unless utf8::decode($decoded);   # kein gültiges UTF-8
    # Neben Unicode-Whitespace zählen auch die breitenlosen und
    # Steuerzeichen als unsichtbar. Statt einer handgepflegten Liste
    # (früher nur U+200B..U+200D, U+2060, U+FEFF) steht hier die
    # Unicode-Eigenschaft Default_Ignorable_Code_Point: sie umfasst
    # dieselben Zeichen und zusätzlich unter anderem die Richtungszeichen
    # U+200E/U+200F (`&lrm;`/`&rlm;`), die unsichtbaren Operatoren
    # U+2061..U+2064, den weichen Trennstrich U+00AD und die
    # Variation Selectors U+FE00..U+FE0F. Ein Rich-Text-Flavor, der nur
    # daraus besteht, unterdrückte sonst den vorhandenen Plain-Text-Fallback.
    exit($decoded =~ /[^\s\p{White_Space}\p{Default_Ignorable_Code_Point}]/
         ? 0 : 1);
  '
}

# Das gemeinsame Ende beider Wege: aufbereitetes HTML von stdin, fertiges
# Markdown auf stdout. Davor steht der Teil, der sich unterscheidet — die
# Herkunftsbereinigung beim HTML, die Tabellen- und Listenkorrektur beim RTF.
#
# Eine Funktion und nicht zweimal dieselbe Kette: Drei dieser Stufen bekommen
# das Zielformat, und alle sechs müssen in beiden Wegen in derselben Reihenfolge
# stehen. Zweimal hingeschrieben blieb beim Ergänzen einer Stufe leicht eine
# Kette zurück — dann käme Clipboard-HTML anders heraus als dasselbe HTML aus
# einem RTF.
html_to_markdown() {
  local target_format="${1:-gfm}"
  clean_html \
    | fill_empty_html_links \
    | run_pandoc "$target_format" \
    | tidy_markdown "$target_format" \
    | require_nonempty_markdown
}

convert_html() {
  local target_format="${1:-gfm}"
  if declare -F vlog >/dev/null 2>&1; then
    vlog "Pfad: HTML → pandoc"
  fi
  preprocess_claude_desktop \
    | preprocess_google_classroom \
    | html_to_markdown "$target_format"
}

convert_rtf() {
  local target_format="${1:-gfm}"
  if declare -F vlog >/dev/null 2>&1; then
    vlog "Pfad: RTF → HTML → Layouttabellen → pandoc mit Tabellenprüfung → tidy"
  fi
  rtf_to_html \
    | flatten_layout_tables \
    | unwrap_list_paragraphs \
    | html_to_markdown "$target_format"
}
