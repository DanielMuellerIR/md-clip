#!/usr/bin/env bash
# Gemeinsame, seiteneffektfreie Konvertierungs-Pipeline für Produkt und Tests.
# Aufrufer setzen PANDOC_OPTS und stellen die plattformspezifische Funktion
# rtf_to_html bereit. Beim Sourcen wird weder Clipboard noch Dateisystem berührt.

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
    s{<colgroup[^>]*>.*?</colgroup>}{}gs;
    s{<col[^/]*/?>}{}g;
    s{</?table[^>]*>}{}gs;
    s{</?t(?:body|head|foot)[^>]*>}{}gs;
    s{</?tr[^>]*>}{}gs;
    s{<t[dh][^>]*>}{<p>}gs;
    s{</t[dh]>}{</p>}gs;
  '
}

unwrap_list_paragraphs() {
  perl -0pe 's{<li([^>]*)>\s*<p[^>]*>([^<]*)</p>\s*</li>}{<li$1>$2</li>}gs'
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
  perl -e '
    use strict;
    use warnings;

    my $text = do { local $/; <STDIN> };
    my $trailing_newline = ($text =~ /\n\z/) ? 1 : 0;
    $text =~ s/\n\z//;
    my @lines = split(/\n/, $text, -1);

    # Alle Listenmarker, die pandoc in den unterstützten Zieldialekten
    # ausgeben kann. Dieselbe Grammatik muss sowohl die Code-Erkennung als
    # auch den Schutz einer Raute am Anfang eines Listenpunkts verwenden:
    # Driften die beiden Stellen auseinander, gilt eine eingerückte
    # Fortsetzungszeile fälschlich als Code und wird nicht aufgeräumt.
    my $list_marker = qr/(?:[-*+:~]|\d{1,9}[.)]|[IVXLCDM]+[.)]|[ivxlcdm]+[.)]|[A-Za-z][.)])/;

    # Blockquote-Marker abschneiden. Innerhalb eines Zitats gelten dieselben
    # Regeln, nur eben hinter dem "> ".
    sub quote_prefix {
        my ($line) = @_;
        return ($line =~ /^((?: {0,3}>[ ]?)+)/) ? $1 : q{};
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
    my $fence_char;                 # undef = kein offener Zaun
    my $fence_len    = 0;
    my $fence_indent = 0;
    my @item_indents = ();          # Inhalts-Einrückung offener Listenpunkte

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
        # Die Zeile verlässt jeden Listenpunkt, dessen Inhalt weiter rechts
        # beginnt — dessen Einrückung zählt danach nicht mehr als Container.
        pop @item_indents while @item_indents && $indent < $item_indents[-1];
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
            push @item_indents, $indent + length($1) + indent_width($2);
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
            } elsif ($next_body =~ /^[ \t]*$list_marker[ \t]+/) {
                $drop = 1;                        # Umbruch vor einem Listenpunkt
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
  '
}

pandoc_supports_rtf() {
  pandoc --list-input-formats 2>/dev/null | grep -Fxq 'rtf'
}

convert_html() {
  if declare -F vlog >/dev/null 2>&1; then
    vlog "Pfad: HTML → pandoc"
  fi
  preprocess_claude_desktop \
    | preprocess_google_classroom \
    | clean_html \
    | fill_empty_html_links \
    | pandoc "${PANDOC_OPTS[@]}" \
    | tidy_markdown
}

convert_rtf() {
  if declare -F vlog >/dev/null 2>&1; then
    vlog "Pfad: RTF → HTML → flatten → pandoc → tidy"
  fi
  rtf_to_html \
    | flatten_layout_tables \
    | unwrap_list_paragraphs \
    | clean_html \
    | fill_empty_html_links \
    | pandoc "${PANDOC_OPTS[@]}" \
    | tidy_markdown
}
