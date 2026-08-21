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

preprocess_claude_desktop() {
  perl -0pe 's{<div\s+data-line="[^"]*"[^>]*>(.*?)</div>}{$1\n}gs' \
    | perl -0pe '
        s{(<pre[^>]*>.*?</pre>)}{
          my $block = $1;
          $block =~ s{</?div[^>]*>}{}g;
          $block;
        }gse' \
    | perl -0pe '
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

  perl -e '
    use strict;
    use warnings;

    my $target_format = shift @ARGV;
    my $text = do { local $/; <STDIN> };
    my $trailing_newline = ($text =~ /\n\z/) ? 1 : 0;
    $text =~ s/\n\z//;
    my @lines = split(/\n/, $text, -1);

    # GFM und CommonMark kennen an dieser Stelle nur normale Bullet- und
    # Dezimalmarker. Alphabetische/römische sowie Definitionslisten sind
    # pandoc-Markdown-Erweiterungen und dürfen in den anderen Zieldialekten
    # keinen gewöhnlichen Text zum Listencontainer machen.
    my $base_list_marker = qr/(?:[-*+]|\d{1,9}[.)])/;
    # Nur `1.`/`1)` kann aus einem laufenden Absatz heraus einen neuen
    # geordneten Listenblock beginnen. Weitere Zahlen sind erst dann
    # Listenpunkte, wenn Durchlauf 1 ihren Listenkontext belegt hat.
    my $block_list_marker = qr/(?:[-*+]|1[.)])/;
    # Darf ein solcher Marker einen laufenden Absatz unterbrechen?
    # GFM und CommonMark: ja. `<p>Text<br>- x</p>` wird dort zu Absatz plus
    # Liste, egal ob der Hard-Break stehen bleibt — die zwei Leerzeichen
    # wirken nicht mehr und wären nur toter Weißraum.
    # pandoc-Markdown: nein. Dort bleibt `Text  \n- x` EIN Absatz mit echtem
    # LineBreak; wird der Break weggelassen, degradiert er zum SoftBreak und
    # der bewusst gesetzte Umbruch ist weg (Review-Fund 2026-08-21, an allen
    # drei Zieldialekten mit `pandoc -t native` gegengeprüft). Deshalb zählt
    # dort nur der in Durchlauf 1 belegte Listenkontext.
    my $block_list_interrupts_paragraph = $target_format ne q{markdown};
    my $markdown_special_marker =
        qr/(?:[:~]|[IVXLCDM]+[.)]|[ivxlcdm]+[.)]|[A-Za-z][.)])/;
    my $list_marker = $target_format eq q{markdown}
        ? qr/(?:$base_list_marker|$markdown_special_marker)/
        : $base_list_marker;

    # Blockquote-Marker abschneiden. Innerhalb eines Zitats gelten dieselben
    # Regeln, nur eben hinter dem "> ".
    sub quote_prefix {
        my ($line) = @_;
        return ($line =~ /^((?: {0,3}>[ ]?)+)/) ? $1 : q{};
    }

    # Zitattiefe = Anzahl der `>`. Zwei Zeilen desselben Zitats haben nicht
    # unbedingt denselben Präfix-Text: pandoc schreibt die Leerzeile als `>`
    # und die Textzeile als `> Text`. Verglichen wird deshalb die Tiefe.
    sub quote_depth {
        my ($prefix) = @_;
        return scalar(() = $prefix =~ />/g);
    }

    # Die Term-Zeile über einem Definitionsmarker: die nächste nichtleere Zeile
    # derselben Zitattiefe oberhalb von $i. Leerzeilen des Zitats werden
    # übersprungen, ein Wechsel der Tiefe beendet die Suche.
    sub term_above {
        my ($i, $depth, $lines_ref) = @_;
        my $index = $i - 1;
        while ($index >= 0) {
            my $prefix = quote_prefix($lines_ref->[$index]);
            last if quote_depth($prefix) != $depth;
            my $candidate = substr($lines_ref->[$index], length($prefix));
            return $candidate if $candidate !~ /^[ \t]*$/;
            $index--;
        }
        return undef;
    }

    # Einrückung in Spalten. Ein Tab zählt wie vier Leerzeichen.
    sub indent_width {
        my ($body) = @_;
        my ($space) = $body =~ /^([ \t]*)/;
        $space =~ s/\t/    /g;
        return length($space);
    }

    # Endet die Zeile auf einem Hard-Break-Marker? pandoc schreibt einen
    # einzelnen Backslash; zwei Leerzeichen kommen aus fremden Quellen.
    # Eine gerade Anzahl Backslashes ist ein escapter Backslash, kein Umbruch.
    sub has_break {
        my ($body) = @_;
        return 1 if $body =~ /[ ]{2,}$/;
        my ($tail) = $body =~ /(\\*)$/;
        return (length($tail) % 2) == 1;
    }

    sub strip_break {
        my ($body) = @_;
        my ($tail) = $body =~ /(\\*)$/;
        $body =~ s/\\$// if (length($tail) % 2) == 1;
        $body =~ s/[ \t]+$//;
        return $body;
    }

    # Nimmt die überzähligen Escapes vor `|` und `#` zurück — aber nur
    # außerhalb von Inline-Code. Zwischen Backticks ist ein Backslash echter
    # Inhalt: `` `\#` `` bedeutet dort wirklich Backslash-Raute, und wer den
    # Backslash entfernt, ändert den Code.
    #
    # Die Zeile wird dafür von links nach rechts gelesen, und die
    # Backslash-Maskierung gilt dabei nur AUSSERHALB von Code:
    #
    #   * Außerhalb ist `` \` `` ein wörtlicher Backtick und beginnt keinen
    #     Code-Span. Ohne diese Regel hielt die Funktion den Bereich dahinter
    #     für Inline-Code und ließ ein `\#` darin escaped stehen, obwohl es
    #     gewöhnlicher Fließtext war (Review-Fund 2026-08-05).
    #   * Innerhalb eines Code-Spans hat der Backslash dagegen KEINE
    #     Escape-Wirkung. Ein gleich langer Backtick-Lauf schließt den Span
    #     deshalb auch dann, wenn direkt davor ein Backslash steht. Früher
    #     verschluckte die Zerlegung diesen Abschluss, der Span blieb offen,
    #     und sein Inhalt wurde als Fließtext entescapt — aus dem Code
    #     `` `\#foo\` `` wurde `` `#foo\` `` (Review-Fund 2026-08-06).

    # Sucht das Ende eines Code-Spans: den ersten Backtick-Lauf GLEICHER Länge
    # ab $start. Läufe anderer Länge sind innerhalb des Spans gewöhnlicher
    # Inhalt. Rückgabe: Index hinter dem schließenden Lauf — oder -1, wenn es
    # keinen gibt; dann war der öffnende Lauf gar kein Code-Anfang, sondern
    # selbst gewöhnlicher Text.
    sub find_code_span_end {
        my ($text, $start, $run_len) = @_;
        my $len = length $text;
        my $i   = $start;

        while ($i < $len) {
            if (substr($text, $i, 1) eq q{`}) {
                my ($run) = substr($text, $i) =~ /^(`+)/;
                return $i + length($run) if length($run) == $run_len;
                $i += length $run;
            } else {
                $i++;
            }
        }
        return -1;
    }

    # Nimmt in gewöhnlichem Text die Backslashes vor `|` und `#` weg. Läuft
    # über Escape-PAARE, nicht über einzelne Zeichen: sonst würde der zweite
    # Backslash eines echten `\\` als Anfang eines neuen Escapes gelesen.
    sub unescape_plain {
        my ($text) = @_;
        $text =~ s{\\(.)}{ ($1 eq q{|} || $1 eq q{#}) ? $1 : qq{\\$1} }gse;
        return $text;
    }

    sub unescape_pipe_hash {
        my ($text) = @_;
        my $out   = q{};   # fertiges Ergebnis
        my $plain = q{};   # gesammelter Fließtext, noch nicht entescapt
        my $i     = 0;
        my $len   = length $text;

        while ($i < $len) {
            my $c = substr($text, $i, 1);
            if ($c eq q{\\} && $i + 1 < $len) {
                $plain .= substr($text, $i, 2);   # Escape-Paar am Stück
                $i += 2;
            } elsif ($c eq q{`}) {
                my ($run) = substr($text, $i) =~ /^(`+)/;
                my $end = find_code_span_end($text, $i + length($run), length($run));
                if ($end < 0) {
                    $plain .= $run;               # kein Abschluss: bloßer Text
                    $i += length $run;
                } else {
                    $out .= unescape_plain($plain);
                    $plain = q{};
                    $out .= substr($text, $i, $end - $i);   # Code bleibt roh
                    $i = $end;
                }
            } else {
                $plain .= $c;
                $i++;
            }
        }

        return $out . unescape_plain($plain);
    }

    # ---- Durchlauf 1: Code-Zeilen markieren ----
    my @is_code = map { 0 } @lines;
    # Zeilen, die nachweislich ein Listenpunkt sind. Durchlauf 2b braucht
    # dieselbe Auskunft wie Durchlauf 1 — sonst behandelt der eine `b.  zwei`
    # als Listenpunkt und der andere als Absatztext (Review-Fund 2026-08-17).
    my @is_list_item = map { 0 } @lines;
    my $fence_char;                 # undef = kein offener Zaun
    my $fence_len    = 0;
    my $fence_indent = 0;
    my @item_indents = ();          # Inhalts-Einrückung offener Listenpunkte
    my @item_markers = ();          # Marker-Einrückung derselben Punkte

    for my $i (0 .. $#lines) {
        my $prefix = quote_prefix($lines[$i]);
        my $body   = substr($lines[$i], length($prefix));

        if (defined $fence_char) {
            $is_code[$i] = 1;
            # Der Abschluss darf bis zu drei Spalten weiter eingerückt sein
            # als der Anfang und mindestens genauso lang, aber nie kürzer.
            my $close = "^ {0," . ($fence_indent + 3) . "}"
                . quotemeta($fence_char) . "{$fence_len,}[ \t]*\$";
            $fence_char = undef if $body =~ /$close/;
            next;
        }

        next if $body =~ /^[ \t]*$/;   # Leerzeilen schließen keinen Container

        my $indent = indent_width($body);
        # Steht diese Zeile auf der Marker-Spalte eines noch offenen Punktes,
        # ist sie dessen Geschwister — also selbst ein Listenpunkt, auch wenn
        # die Vorzeile mit einem Hard-Break endet. Vor dem Schließen unten
        # ermitteln, denn genau dieser Punkt wird dabei zugeklappt.
        my $sibling_of_open_item = grep { $_ == $indent } @item_markers;
        # Die Zeile verlässt jeden Listenpunkt, dessen Inhalt weiter rechts
        # beginnt — dessen Einrückung zählt danach nicht mehr als Container.
        while (@item_indents && $indent < $item_indents[-1]) {
            pop @item_indents;
            pop @item_markers;
        }
        my $container = @item_indents ? $item_indents[-1] : 0;

        # Vier Spalten jenseits des Containers: eingerückter Code-Block.
        if ($indent >= $container + 4) {
            $is_code[$i] = 1;
            next;
        }

        if ($body =~ /^[ \t]*(`{3,}|~{3,})(.*)$/) {
            my ($delim, $info) = ($1, $2);
            # Ein Backtick-Zaun darf im Info-String keinen Backtick haben.
            unless (substr($delim, 0, 1) eq q{`} && $info =~ /`/) {
                $fence_char   = substr($delim, 0, 1);
                $fence_len    = length($delim);
                $fence_indent = $indent;
                $is_code[$i]  = 1;
                next;
            }
        }

        if ($body =~ /^[ \t]*($list_marker)([ \t]+)/) {
            my ($marker, $gap) = ($1, $2);
            my $proven_list_item = 1;
            my $depth = quote_depth($prefix);

            # Dokumentanfang oder Leerzeile derselben Zitattiefe beginnen
            # einen neuen Block. Dezimalmarker >1 dürfen dort eine Liste
            # starten, aber keinen laufenden Absatz unterbrechen.
            my $block_start = ($i == 0);
            if (!$block_start) {
                my $previous_prefix = quote_prefix($lines[$i - 1]);
                my $previous_body = substr(
                    $lines[$i - 1], length($previous_prefix)
                );
                $block_start = quote_depth($previous_prefix) == $depth
                    && $previous_body =~ /^[ \t]*$/;
            }

            if ($marker =~ /^\d{1,9}[.)]$/ && $marker !~ /^1[.)]$/) {
                $proven_list_item = $block_start || $sibling_of_open_item;
            }

            if ($target_format eq q{markdown}
                && $marker =~ /^$markdown_special_marker$/) {
                # Steht direkt darüber eine Leerzeile derselben Zitattiefe?
                # Dann eröffnet der Marker einen neuen Block. Die Tiefe wird
                # gezählt und nicht bytegleich verglichen: pandoc schreibt die
                # Leerzeile eines Zitats als `>`, die Textzeilen als `> Text`
                # (Review-Fund 2026-08-17).
                if ($marker eq q{:} || $marker eq q{~}) {
                    # Ein Definitionsmarker steht bei pandoc IMMER hinter einer
                    # Leerzeile, und darüber muss ein Term stehen. Beides
                    # zusammen trennt die echte Definitionsliste sauber vom
                    # Absatz `Begriff\` + `: Text`, der nur so aussieht. Die
                    # frühere Regel „Term darf keinen Hard-Break haben" verwarf
                    # dagegen eine echte Liste, deren Term auf `<br>` endet.
                    $proven_list_item = $block_start
                        && defined(term_above($i, $depth, \@lines));
                } else {
                    # Alphabetische und römische Marker: entweder Blockanfang
                    # oder Geschwister eines schon offenen Punktes. Nur Letzteres
                    # erkennt den zweiten Punkt `b.` einer engen Liste, dessen
                    # Vorzeile mit einem Hard-Break endet.
                    $proven_list_item = $block_start || $sibling_of_open_item;
                }
            }

            if ($proven_list_item) {
                $is_list_item[$i] = 1;
                push @item_indents,
                    $indent + length($marker) + indent_width($gap);
                push @item_markers, $indent;
            }
        }
    }

    # Eine Leerzeile mitten in einem eingerückten Code-Block ist selbst noch
    # Code — sie wird ja nicht eingerückt geschrieben und wäre oben deshalb
    # als Fließtext durchgegangen. Also nachträglich einsammeln: jeder
    # Leerzeilen-Lauf zwischen zwei Code-Zeilen gehört zum Code-Block.
    my $run_start;
    for my $i (0 .. $#lines) {
        if (!$is_code[$i] && $lines[$i] =~ /^[ \t]*$/) {
            $run_start = $i unless defined $run_start;
            next;
        }
        if (defined $run_start) {
            if ($run_start > 0 && $is_code[$run_start - 1] && $is_code[$i]) {
                $is_code[$_] = 1 for ($run_start .. $i - 1);
            }
            $run_start = undef;
        }
    }

    # ---- Durchlauf 2a: leere Absätze zu echten Leerzeilen ----
    # Eine leere Zeile aus Word kommt als Hard-Break ohne Inhalt an, oft mit
    # leerer Auszeichnung davor (`****\`).
    for my $i (0 .. $#lines) {
        next if $is_code[$i];
        my $prefix = quote_prefix($lines[$i]);
        my $body   = substr($lines[$i], length($prefix));
        next unless has_break($body);
        my $content = strip_break($body);
        $content =~ s/^[ \t]+//;
        next unless $content eq q{} || $content =~ /^[*_]+$/;
        $prefix =~ s/[ \t]+$//;
        $lines[$i] = $prefix;
    }

    # ---- Durchlauf 2b: Hard-Breaks entscheiden ----
    for my $i (0 .. $#lines) {
        next if $is_code[$i];
        my $prefix = quote_prefix($lines[$i]);
        my $body   = substr($lines[$i], length($prefix));
        next unless has_break($body);
        my $content = strip_break($body);

        my $drop = 0;
        if ($i == $#lines) {
            $drop = 1;                            # Umbruch am Dokumentende
        } elsif (!$is_code[$i + 1]) {
            my $next_prefix = quote_prefix($lines[$i + 1]);
            my $next_body   = substr($lines[$i + 1], length($next_prefix));
            if ($next_body =~ /^[ \t]*$/) {
                $drop = 1;                        # Umbruch vor einer Leerzeile
            # Ein Markdown-Sondermarker allein reicht hier nicht als Beleg:
            # Direkt hinter dem Hard-Break ist er Teil desselben Absatzes
            # (`a. Text`) und darf den echten Umbruch nicht verlieren. Deshalb
            # gilt derselbe Nachweis wie in Durchlauf 1 (`@is_list_item`) —
            # sonst behielte der zweite Punkt einer engen Sonderliste einen
            # reinen Layout-Umbruch (Review-Fund 2026-08-17).
            #
            # In einem Dialekt, in dem ein Marker den laufenden Absatz NICHT
            # unterbricht, zählt zusätzlich, was in der Zeile davor steht:
            # Gehört sie selbst zur Liste, ist der Umbruch pandocs Layout am
            # Ende eines Listenpunktes und darf weg. Ist sie gewöhnlicher
            # Absatztext (`<p>Text<br>- x</p>`), bleibt der Umbruch ein echter
            # LineBreak und muss stehen bleiben — sonst degradiert er zum
            # SoftBreak (Review-Fund 2026-08-21).
            } elsif ($is_list_item[$i + 1]
                     && ($block_list_interrupts_paragraph
                         || $is_list_item[$i])) {
                $drop = 1;                        # Umbruch vor einem Listenpunkt
            } elsif ($block_list_interrupts_paragraph
                     && $next_body =~ /^[ \t]*$block_list_marker[ \t]+/) {
                $drop = 1;                        # Marker unterbricht den Absatz
            }
        }

        $lines[$i] = $drop ? $prefix . $content : $prefix . $content . q{  };
    }

    # ---- Durchlauf 2c: unnötige Escapes zurücknehmen ----
    for my $i (0 .. $#lines) {
        next if $is_code[$i];
        my $prefix = quote_prefix($lines[$i]);
        my $body   = substr($lines[$i], length($prefix));
        my ($space) = $body =~ /^([ \t]*)/;
        my $rest = substr($body, length($space));

        # Ein Absatz, der nur aus einem Bullet-Zeichen besteht, war ein
        # getippter Listenpunkt. \xe2\x80\xa2 ist •, \xc2\xa0 ein geschütztes
        # Leerzeichen (beides UTF-8-Bytes, weil perl hier auf Bytes arbeitet).
        my $plain = $rest;
        $plain =~ s/[*_]//g;
        $plain =~ s/^(?:[ \t]|\xc2\xa0)+//;
        $plain =~ s/(?:[ \t]|\xc2\xa0)+$//;

        my $original = $rest;

        if ($plain eq "\xe2\x80\xa2") {
            $rest = q{-};
        } elsif ($rest =~ /^(?:\\_){3,}$/) {
            $rest = q{_} x (length($rest) / 2);
        } elsif ($rest =~ /^\\-/) {
            $rest = substr($rest, 1);
        }

        # Pipe und Raute escaped pandoc immer, obwohl beide nur in einem
        # einzigen Zusammenhang Markdown-Zeichen sind: `|` trennt Zellen in
        # einer Tabellenzeile, `#` beginnt eine Überschrift. Überall sonst ist
        # der Backslash überzählig und im Ergebnis sichtbar.
        # Eine Tabellenzeile bleibt komplett, wie pandoc sie geschrieben hat:
        # sie beginnt immer mit `|` (die Trennzeile eingeschlossen), und ihre
        # Escapes gehören dort zur Spaltenbreite. Ein Zeichen daraus zu
        # entfernen würde die Ausrichtung der Tabelle verschieben.
        unless ($rest =~ /^\|/) {
            # Eine Überschrift beginnt am Anfang ihres Blocks — das ist der
            # Zeilenanfang ODER die Stelle direkt hinter einem Listenmarker.
            # `- \# Text` ohne Backslash wäre eine Überschrift IM Listenpunkt,
            # also bleibt der Backslash auch dort stehen.
            #
            # MEHRERE Marker hintereinander, weil pandoc verschachtelte Listen
            # in einer Zeile schreibt: `- - \# tief`. Erkannte die Regel nur den
            # ersten, fiel der Backslash weg und aus dem Text wurde eine
            # Überschrift — im AST belegt (Review-Fund 2026-08-05). Alphabetische
            # Marker (`a.`, `b)`) kommen beim Ziel `markdown` dazu; ein
            # unmaskiertes `a)` am Zeilenanfang ist dort immer ein Listenmarker,
            # gewöhnlichen Text hätte pandoc als `a\)` geschrieben. `:` und `~`
            # sind die Definitionslisten-Marker desselben Ziels — auch dort
            # wurde aus dem Text sonst eine Überschrift.
            #
            # RÖMISCHE Marker sind mehrstellig: aus `<ol type="i" start="4">`
            # schreibt pandoc beim Ziel `markdown` ein `iv.`. Ein einzelner
            # Buchstabe deckt das nicht ab, und ohne den Marker fiel der
            # Backslash weg — aus dem Listentext wurde wieder eine Überschrift
            # (im AST belegt, Review-Fund 2026-08-06). Groß und klein getrennt,
            # weil pandoc römische Zahlen nie mischt.
            #
            # Im Zweifel lieber einen Marker zu viel erkennen: dann bleibt ein
            # überzähliger Backslash stehen (sichtbarer Schönheitsfehler), statt
            # dass sich die Dokumentstruktur ändert.
            my ($marker) = $rest =~ /^((?:$list_marker[ \t]+)+)/;
            $marker = defined($marker) ? $marker : q{};
            my $tail = substr($rest, length($marker));

            my $keep = q{};
            if ($tail =~ /^\\#/) {
                $keep = q{\#};  # Raute am Blockanfang bleibt escaped
                $tail = substr($tail, 2);
            }
            $rest = $marker . $keep . unescape_pipe_hash($tail);
        }

        $lines[$i] = $prefix . $space . $rest if $rest ne $original;
    }

    # ---- Durchlauf 2d: Leerzeilen-Läufe zusammenziehen ----
    my @out;
    my $blank_run = 0;
    for my $i (0 .. $#lines) {
        if (!$is_code[$i] && $lines[$i] =~ /^[ \t]*$/) {
            $blank_run++;
            push @out, q{} if $blank_run == 1;
            next;
        }
        $blank_run = 0;
        push @out, $lines[$i];
    }

    print join("\n", @out);
    print "\n" if $trailing_newline;
  ' "$target_format"
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
run_pandoc() {
  local target_format="${1:-gfm}"
  pandoc -f html -t "${target_format}-raw_html" --wrap=none --sandbox
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
  perl -0e '
    use Encode ();
    my $text = do { local $/; <STDIN> };
    print $text;
    my $decoded = eval { Encode::decode("UTF-8", $text, Encode::FB_CROAK()) };
    $decoded = $text unless defined $decoded;   # kein gültiges UTF-8
    # Neben Unicode-Whitespace zählen auch die breitenlosen Zeichen als
    # unsichtbar: U+200B..U+200D, U+2060 und U+FEFF. Unicode führt sie nicht
    # unter White_Space, für den Nutzer sind sie aber genauso leer wie ein
    # geschütztes Leerzeichen.
    exit($decoded =~ /[^\s\p{White_Space}\x{200B}-\x{200D}\x{2060}\x{FEFF}]/
         ? 0 : 1);
  '
}

convert_html() {
  local target_format="${1:-gfm}"
  if declare -F vlog >/dev/null 2>&1; then
    vlog "Pfad: HTML → pandoc"
  fi
  preprocess_claude_desktop \
    | preprocess_google_classroom \
    | clean_html \
    | fill_empty_html_links \
    | run_pandoc "$target_format" \
    | tidy_markdown "$target_format" \
    | require_nonempty_markdown
}

convert_rtf() {
  local target_format="${1:-gfm}"
  if declare -F vlog >/dev/null 2>&1; then
    vlog "Pfad: RTF → HTML → flatten → pandoc → tidy"
  fi
  rtf_to_html \
    | flatten_layout_tables \
    | unwrap_list_paragraphs \
    | clean_html \
    | fill_empty_html_links \
    | run_pandoc "$target_format" \
    | tidy_markdown "$target_format" \
    | require_nonempty_markdown
}
