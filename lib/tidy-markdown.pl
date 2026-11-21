#!/usr/bin/env perl
# Strukturerkennung und Aufräumregeln; Einstieg über lib/pipeline.sh.
use strict;
use warnings;

my $base_list_marker = qr/(?:[-*+]|\d{1,9}[.)])/;
# Nur `1.`/`1)` kann aus einem laufenden Absatz heraus einen neuen
# geordneten Listenblock beginnen. Weitere Zahlen sind erst dann
# Listenpunkte, wenn Durchlauf 1 ihren Listenkontext belegt hat.
my $block_list_marker = qr/(?:[-*+]|1[.)])/;
my $markdown_special_marker =
    qr/(?:[:~]|[IVXLCDM]+[.)]|[ivxlcdm]+[.)]|[A-Za-z][.)])/;
sub quote_prefix {
    my ($line, $prefix) = @_;
    return $prefix if defined $prefix;
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
    my ($i, $depth, $lines, $quote_prefixes) = @_;
    my $index = $i - 1;
    while ($index >= 0) {
        my $prefix = quote_prefix($lines->[$index], $quote_prefixes->[$index]);
        last if quote_depth($prefix) != $depth;
        my $candidate = substr($lines->[$index], length($prefix));
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

# Ein Code-Span schließt mit einem gleich langen Backtick-Lauf, auch
# hinter einem Backslash. Nur außerhalb von Code können Backticks maskiert sein.
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
    # Ohne diese beiden Escape-Arten kann die Regel nichts ändern. Der
    # schnelle Test spart den zeichenweisen Code-Span-Lauf bei langen Absätzen.
    return $text unless $text =~ /\\[|#]/;
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

sub opening_fence {
    my ($content, $indent) = @_;
    return unless $content =~ /^[ \t]*(`{3,}|~{3,})(.*)$/;
    my ($delimiter, $info) = ($1, $2);
    my $char = substr($delimiter, 0, 1);
    return if $char eq q{`} && $info =~ /`/;
    return { char => $char, length => length($delimiter), indent => $indent };
}

sub detect_structure {
    my ($state, $target_format, $list_marker) = @_;
    my ($lines, $is_code, $is_list_item, $in_list_container, $quote_prefixes) =
        @{$state}{qw(lines is_code is_list_item in_list_container quote_prefixes)};
    my $fence;

    # Listen innerhalb eines Zitats dürfen die Einrückung außerhalb nicht ändern.
    # Beim Rückweg bleibt die äußere Liste erhalten; verlassene Zitate verlieren
    # ihren Zustand, damit ein späteres neues Zitat keine alte Liste übernimmt.
    my %lists_by_depth;
    my $previous_depth = 0;

    for my $i (0 .. $#$lines) {
        my $prefix = q{};
        my $quote_level = 0;
        while (substr($lines->[$i], length($prefix)) =~ /^([ ]*)>[ ]?/) {
            my ($part, $space) = (substr($lines->[$i], length($prefix), $+[0]), $1);
            my $outer = $lists_by_depth{$quote_level};
            my $container = $outer && @{$outer->{indents}} ? $outer->{indents}->[-1] : 0;
            last if length($space) > $container + 3;
            $prefix .= $part;
            $quote_level++;
        }
        $quote_prefixes->[$i] = $prefix;
        my $body   = substr($lines->[$i], length($prefix));
        my $depth = quote_depth($prefix);
        if (!$fence && $depth > $previous_depth) {
            # Ein Zitat erhält die äußere Liste nur, wenn sein Marker tatsächlich
            # im Listeninhalt eingerückt ist. Ein eigenständiges Zitat beendet sie.
            my $outer_body = $lines->[$i];
            $outer_body =~ s/^(?:[ ]*>[ ]?){$previous_depth}//;
            my $quote_indent = indent_width($outer_body);
            my $outer_list = $lists_by_depth{$previous_depth};
            if ($outer_list) {
                while (@{$outer_list->{indents}} &&
                       $quote_indent < $outer_list->{indents}->[-1]) {
                    pop @{$outer_list->{indents}};
                    pop @{$outer_list->{markers}};
                }
            }
        }
        if ($depth < $previous_depth) {
            delete $lists_by_depth{$_} for grep { $_ > $depth } keys %lists_by_depth;
        }
        $previous_depth = $depth;
        my $list = ($lists_by_depth{$depth} ||= { indents => [], markers => [] });
        my $item_indents = $list->{indents};
        my $item_markers = $list->{markers};

        if ($fence) {
            $is_code->[$i] = 1;
            # Der Abschluss darf bis zu drei Spalten weiter eingerückt sein
            # als der Anfang und mindestens genauso lang, aber nie kürzer.
            my $close = "^ {0," . ($fence->{indent} + 3) . "}"
                . quotemeta($fence->{char}) . "{$fence->{length},}[ \t]*\$";
            undef $fence if $body =~ /$close/;
            next;
        }

        next if $body =~ /^[ \t]*$/;   # Leerzeilen schließen keinen Container

        my $indent = indent_width($body);
        # Steht diese Zeile auf der Marker-Spalte eines noch offenen Punktes,
        # ist sie dessen Geschwister — also selbst ein Listenpunkt, auch wenn
        # die Vorzeile mit einem Hard-Break endet. Vor dem Schließen unten
        # ermitteln, denn genau dieser Punkt wird dabei zugeklappt.
        my $sibling_of_open_item = grep { $_ == $indent } @{$item_markers};
        # Die Zeile verlässt jeden Listenpunkt, dessen Inhalt weiter rechts
        # beginnt — dessen Einrückung zählt danach nicht mehr als Container.
        while (@{$item_indents} && $indent < $item_indents->[-1]) {
            pop @{$item_indents};
            pop @{$item_markers};
        }
        my $container = @{$item_indents} ? $item_indents->[-1] : 0;
        # Nach dem Zuklappen offener Punkte gilt: Bleibt ein Punkt offen,
        # gehört diese Zeile zu seinem Inhalt.
        $in_list_container->[$i] = 1 if @{$item_indents};

        # Vier Spalten jenseits des Containers: eingerückter Code-Block.
        if ($indent >= $container + 4) {
            $is_code->[$i] = 1;
            next;
        }

        if ($fence = opening_fence($body, $indent)) {
            $is_code->[$i] = 1;
            next;
        }

        if ($body =~ /^[ \t]*($list_marker)([ \t]+)(.*)$/) {
            my ($marker, $gap, $content) = ($1, $2, $3);
            my $proven_list_item = 1;

            # Dokumentanfang oder Leerzeile derselben Zitattiefe beginnen
            # einen neuen Block. Dezimalmarker >1 dürfen dort eine Liste
            # starten, aber keinen laufenden Absatz unterbrechen.
            my $block_start = ($i == 0);
            if (!$block_start) {
                my $previous_prefix = quote_prefix($lines->[$i - 1], $quote_prefixes->[$i - 1]);
                my $previous_body = substr(
                    $lines->[$i - 1], length($previous_prefix)
                );
                $block_start = quote_depth($previous_prefix) == $depth
                    && $previous_body =~ /^[ \t]*$/;
            }

            if ($marker =~ /^\d{1,9}[.)]$/ && $marker !~ /^1[.)]$/) {
                $proven_list_item = $block_start || $sibling_of_open_item;
            }

            if ($target_format eq q{markdown}
                && $marker =~ /^$markdown_special_marker$/) {
                if ($marker eq q{:} || $marker eq q{~}) {
                    # Pandoc trennt den Definitionsterm durch eine Leerzeile vom Marker.
                    $proven_list_item = $block_start
                        && defined(term_above($i, $depth, $lines, $quote_prefixes));
                } else {
                    # Alphabetische und römische Marker: entweder Blockanfang
                    # oder Geschwister eines schon offenen Punktes. Nur Letzteres
                    # erkennt den zweiten Punkt `b.` einer engen Liste, dessen
                    # Vorzeile mit einem Hard-Break endet.
                    $proven_list_item = $block_start || $sibling_of_open_item;
                }
            }

            if ($proven_list_item) {
                $is_list_item->[$i] = 1;
                $in_list_container->[$i] = 1;
                my $marker_indent = $indent;
                while (1) {
                    my $padding = indent_width($gap);
                    # Ab fünf Spalten folgt eingerückter Code: Nur eine Spalte
                    # gehört zum Marker, der Rest zum Code. Sonst wird dessen
                    # Einrückung zum Container und die Bereinigung verändert ihn.
                    my $content_indent = $marker_indent + length($marker)
                        + ($padding > 4 ? 1 : $padding);
                    push @{$item_indents}, $content_indent;
                    push @{$item_markers}, $marker_indent;
                    if ($padding > 4 || ($fence = opening_fence($content, $content_indent))) {
                        $is_code->[$i] = 1;
                        last;
                    }
                    # pandoc schreibt innere Listen auch direkt hinter äußere
                    # Marker, etwa `- - ``` `. Der Zaun gehört zum inneren Punkt.
                    last unless $content =~ /^($list_marker)([ \t]+)(.*)$/;
                    ($marker, $gap, $content) = ($1, $2, $3);
                    $marker_indent = $content_indent;
                }
            }
        }
    }
}

sub mark_blank_code_lines {
    my ($state) = @_;
    my ($lines, $is_code) = @{$state}{qw(lines is_code)};
    # Leerzeilen in eingerücktem Code tragen keinen Marker, gehören aber zum Block.
    my $run_start;
    for my $i (0 .. $#$lines) {
        if (!$is_code->[$i] && $lines->[$i] =~ /^[ \t]*$/) {
            $run_start = $i unless defined $run_start;
            next;
        }
        if (defined $run_start) {
            if ($run_start > 0 && $is_code->[$run_start - 1] && $is_code->[$i]) {
                $is_code->[$_] = 1 for ($run_start .. $i - 1);
            }
            $run_start = undef;
        }
    }
}

sub clean_empty_paragraphs {
    my ($state) = @_;
    my ($lines, $is_code, $quote_prefixes) = @{$state}{qw(lines is_code quote_prefixes)};
    # Eine leere Zeile aus Word kommt als Hard-Break ohne Inhalt an, oft mit
    # leerer Auszeichnung davor (`****\`).
    for my $i (0 .. $#$lines) {
        next if $is_code->[$i];
        my $prefix = quote_prefix($lines->[$i], $quote_prefixes->[$i]);
        my $body   = substr($lines->[$i], length($prefix));
        next unless has_break($body);
        my $content = strip_break($body);
        $content =~ s/^[ \t]+//;
        next unless $content eq q{} || $content =~ /^[*_]+$/;
        $prefix =~ s/[ \t]+$//;
        $lines->[$i] = $prefix;
        # Der zwischengespeicherte Präfix darf jetzt nicht länger als die Zeile sein.
        $quote_prefixes->[$i] = $prefix;
    }
}

sub clean_hard_breaks {
    my ($state, $target_format) = @_;
    my ($lines, $is_code, $is_list_item, $in_list_container, $quote_prefixes) =
        @{$state}{qw(lines is_code is_list_item in_list_container quote_prefixes)};
    # In Pandoc-Markdown kann ein Listenmarker einen laufenden Absatz nicht unterbrechen.
    my $block_list_interrupts_paragraph = $target_format ne q{markdown};
    for my $i (0 .. $#$lines) {
        next if $is_code->[$i];
        my $prefix = quote_prefix($lines->[$i], $quote_prefixes->[$i]);
        my $body   = substr($lines->[$i], length($prefix));
        next unless has_break($body);
        my $content = strip_break($body);

        my $drop = 0;
        if ($i == $#$lines) {
            $drop = 1;                            # Umbruch am Dokumentende
        } elsif (!$is_code->[$i + 1]) {
            my $next_prefix = quote_prefix($lines->[$i + 1], $quote_prefixes->[$i + 1]);
            my $next_body   = substr($lines->[$i + 1], length($next_prefix));
            if ($next_body =~ /^[ \t]*$/) {
                $drop = 1;                        # Umbruch vor einer Leerzeile
            # Vor einem belegten Listenpunkt ist der Umbruch im Listencontainer
            # nur Layout. Im laufenden Pandoc-Markdown-Absatz ist er Nutzinhalt.
            } elsif ($is_list_item->[$i + 1]
                     && ($block_list_interrupts_paragraph
                         || $in_list_container->[$i])) {
                $drop = 1;                        # Umbruch vor einem Listenpunkt
            } elsif ($block_list_interrupts_paragraph
                     && $next_body =~ /^[ \t]*$block_list_marker[ \t]+/) {
                $drop = 1;                        # Marker unterbricht den Absatz
            }
        }

        $lines->[$i] = $drop ? $prefix . $content : $prefix . $content . q{  };
    }
}

sub clean_escapes {
    my ($state, $list_marker) = @_;
    my ($lines, $is_code, $quote_prefixes) = @{$state}{qw(lines is_code quote_prefixes)};
    for my $i (0 .. $#$lines) {
        next if $is_code->[$i];
        my $prefix = quote_prefix($lines->[$i], $quote_prefixes->[$i]);
        my $body   = substr($lines->[$i], length($prefix));
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

        # Pandocs Tabellenzeilen beginnen mit Pipe. Ihre Escapes zählen zur
        # Spaltenbreite. Auch getippte Trennzeilen dürfen keine Tabelle eröffnen.
        my $separator = $rest;
        $separator =~ s/\\([|:-])/$1/g;
        my $literal_table_separator = $separator =~ /\|/
            && $separator =~ /^[ \t]*\|?[ \t]*:?-+:?[ \t]*(?:\|[ \t]*:?-+:?[ \t]*)*\|?[ \t]*$/;
        # Am Blockanfang eröffnet | außerdem pandoc-Markdowns LineBlock-Syntax.
        my $pipe_block_start = $rest =~ /^(?:$list_marker[ \t]+)*(?:\\)?\|/;
        unless ($pipe_block_start || $literal_table_separator) {
            # Eine führende Raute muss auch hinter verschachtelten Listenmarkern
            # maskiert bleiben, damit sie keine Überschrift im Listenpunkt beginnt.
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

        $lines->[$i] = $prefix . $space . $rest if $rest ne $original;
    }
}

sub compress_blank_lines {
    my ($lines, $is_code) = @_;
    my @out;
    my $blank_run = 0;
    for my $i (0 .. $#$lines) {
        if (!$is_code->[$i] && $lines->[$i] =~ /^[ \t]*$/) {
            $blank_run++;
            push @out, q{} if $blank_run == 1;
            next;
        }
        $blank_run = 0;
        push @out, $lines->[$i];
    }
    return join("\n", @out);
}

my $target_format = shift @ARGV;
my $require_visible = (shift(@ARGV) // '') eq '--require-visible';
my $text = do { local $/; <STDIN> } // '';
my $trailing_newline = $text =~ s/\n\z//;
my @lines = split(/\n/, $text, -1);
my $state = {
    lines => \@lines,
    is_code => [],
    is_list_item => [],
    in_list_container => [],
    quote_prefixes => [],
};
# Alphabetische, römische und Definitionslisten sind Pandoc-Erweiterungen.
my $list_marker = $target_format eq 'markdown'
    ? qr/(?:$base_list_marker|$markdown_special_marker)/
    : $base_list_marker;

detect_structure($state, $target_format, $list_marker);
mark_blank_code_lines($state);
clean_empty_paragraphs($state);
clean_hard_breaks($state, $target_format);
clean_escapes($state, $list_marker);
my $markdown = compress_blank_lines($state->{lines}, $state->{is_code});
$markdown .= "\n" if $trailing_newline;

# Der AST-Wächter prüft Nutzinhalt vor Markdown-Markern. Diese zweite Prüfung
# sieht die tatsächliche Ausgabe nach Writer und Bereinigung.
if ($require_visible) {
    my $directory = __FILE__ =~ m{^(.*/)} ? $1 : './';
    require(($directory =~ m{^/} ? '' : './') . $directory . 'conversion-support.pl');
    exit 1 unless has_visible_text($markdown);
}
print $markdown;
