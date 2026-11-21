#!/usr/bin/env perl
use strict;
use warnings;

my $directory = __FILE__ =~ m{^(.*/)} ? $1 : './';
require(($directory =~ m{^/} ? '' : './') . $directory . 'conversion-support.pl');

# Wenn Classroom die Klasse ändert, ergänzt der Pandoc-Filter bei
# leerem Titel das Linkziel als sichtbaren Text.
my $classroom_title_class = 'mvRF3b';

sub tokenize {
    my ($html) = @_;
    my $tag_body = qr/(?:[^"'<>]|"[^"]*"|'[^']*')*/;
    my $markup = qr/<!--.*?-->|<!\[CDATA\[.*?\]\]>|<\?.*?\?>|<![^>]*>|<\/?[A-Za-z][A-Za-z0-9:_-]*$tag_body>/s;
    my @tokens;
    my $cursor = 0;

    # Nur die Quellenreparatur braucht rohe Tags. Attribute werden als ganze
    # Tokens gelesen, damit ein > oder scheinbares data-line im Titel nichts trennt.
    while ($html =~ /$markup/g) {
        push @tokens, { raw => substr($html, $cursor, $-[0] - $cursor) } if $-[0] > $cursor;
        my $raw = substr($html, $-[0], $+[0] - $-[0]);
        $cursor = $+[0];
        my $token = { raw => $raw };
        if ($raw =~ /^<(\/?)([A-Za-z][A-Za-z0-9:_-]*)(?=[\s\/>])/) {
            $token->{close} = $1 ne '';
            $token->{name} = lc $2;
            my $offset = $+[0];
            my (%attrs, @ranges);
            pos($raw) = $offset;
            while ($raw =~ /\G\s+([^\s"'<>\/=]+)(?:\s*=\s*(?:"([^"]*)"|'([^']*)'|([^\s"'<>`=]+)))?/gc) {
                my $name = lc $1;
                $attrs{$name} = defined($2) ? $2 : defined($3) ? $3 : $4 // ''
                    unless exists $attrs{$name};
                push @ranges, [$-[0], $+[0], $name];
            }
            $token->{attrs} = \%attrs;
            $token->{ranges} = \@ranges;
            $token->{self_closing} = substr($raw, pos($raw) // $offset) =~ m{\A\s*/>\z};
        }
        push @tokens, $token;
        # Auch RCDATA in textarea/title enthält keine inneren HTML-Tags. Reader
        # dekodieren dort Zeichenreferenzen selbst; die Quellbytes bleiben unangetastet.
        if ($token->{name} && !$token->{close} && $token->{name} =~ /^(script|style|textarea|title)$/) {
            my $name = $token->{name};
            pos($html) = $cursor;
            if ($html =~ m{</\Q$name\E(?=[\s/>])$tag_body>}ig) {
                push @tokens, { raw => substr($html, $cursor, $-[0] - $cursor), opaque => 1 };
                push @tokens, { raw => substr($html, $-[0], $+[0] - $-[0]), name => $name, close => 1 };
                $cursor = $+[0];
            } else {
                push @tokens, { raw => substr($html, $cursor), opaque => 1 };
                $cursor = length $html;
                last;
            }
        }
        pos($html) = $cursor;
    }
    push @tokens, { raw => substr($html, $cursor) } if $cursor < length $html;

    # Vollständiges SVG ist Bildinhalt. Styles, foreignObject-HTML und data-line darin
    # müssen unverändert zum Reader gelangen, statt Quellenreparaturen auszulösen.
    my @protected;
    my $svg_start;
    my $svg_depth = 0;
    for (my $i = 0; $i < @tokens; $i++) {
        my $token = $tokens[$i];
        my $svg = ($token->{name} // '') eq 'svg';
        if (defined $svg_start) {
            $svg_depth += $token->{close} ? -1 : $token->{self_closing} ? 0 : 1 if $svg;
            if (!$svg_depth) {
                push @protected, { raw => join('', map { $_->{raw} } @tokens[$svg_start .. $i]), svg => 1 };
                undef $svg_start;
            }
            next;
        }
        if ($svg && !$token->{close}) {
            if ($token->{self_closing}) { push @protected, { raw => $token->{raw}, svg => 1 }; }
            else { $svg_start = $i; $svg_depth = 1; }
            next;
        }
        push @protected, $token;
    }
    push @protected, @tokens[$svg_start .. $#tokens] if defined $svg_start;
    return \@protected;
}

sub repair_source_code {
    my ($tokens) = @_;
    # Reiner pre-Text braucht ein code-Kind, damit pandoc die Vorformatierung
    # erhält. Rich-Inhalt und unvollständige/verschachtelte pre-Blöcke ausnehmen.
    my @pre_frames;
    for my $i (0 .. $#$tokens) {
        my $token = $tokens->[$i];
        my $name = $token->{name} // '';
        if ($name eq 'pre') {
            if (!$token->{close}) {
                $pre_frames[-1]{eligible} = 0 if @pre_frames;
                push @pre_frames, { start => $i, eligible => !@pre_frames && !$token->{self_closing}, breaks => [] };
            } elsif (@pre_frames) {
                my $frame = pop @pre_frames;
                if ($frame->{eligible} && !$frame->{code}) {
                    $tokens->[$frame->{start}]{raw} .= '<code>';
                    $token->{raw} = '</code>' . $token->{raw};
                    for my $line_break (@{$frame->{breaks}}) { $tokens->[$line_break] = { raw => "\n" }; }
                }
            }
        } elsif (@pre_frames) {
            my $frame = $pre_frames[-1];
            if ($name eq 'code') { $frame->{code} = 1; }
            elsif ($name eq 'br') { push @{$frame->{breaks}}, $i; }
            elsif (($name ne '' && $name ne 'span') || $token->{svg}
                   || $token->{raw} =~ /^<[!?]/) { $frame->{eligible} = 0; }
        }
    }
    my $pre_depth = 0;
    my @divs;
    for my $token (@$tokens) {
        my $raw = $token->{raw};
        my $name = $token->{name} // '';
        if ($name ne '' && !$token->{close}) {
            for my $range (reverse @{$token->{ranges} // []}) {
                substr($raw, $range->[0], $range->[1] - $range->[0], '')
                    if $range->[2] eq 'style' || $range->[2] =~ /^data-[a-z-]+$/;
            }
        }
        if ($name eq 'pre') {
            $pre_depth += $token->{close} ? -1 : 1;
            $pre_depth = 0 if $pre_depth < 0;
        } elsif ($name eq 'div') {
            if (!$token->{close}) {
                my $line = exists $token->{attrs}{'data-line'};
                push @divs, [$line, $pre_depth > 0];
                $raw = '' if $line || $pre_depth;
            } elsif (@divs) {
                my ($line, $in_pre) = @{pop @divs};
                $raw = $line ? "\n" : '' if $line || $in_pre;
            } elsif ($pre_depth) {
                $raw = '';
            }
        }
        $token->{raw} = $raw;
        $token = { raw => $raw } if $name eq 'div' && $raw !~ /^</;
    }
}

sub element_ends {
    my ($tokens, @names) = @_;
    my %pending = map { $_ => [] } @names;
    my %end;
    for my $i (0 .. $#$tokens) {
        my $token = $tokens->[$i];
        my $stack = $pending{$token->{name} // ''} or next;
        if ($token->{close}) {
            $end{pop @$stack} = $i if @$stack;
        } elsif (!$token->{self_closing}) {
            push @$stack, $i;
        }
    }
    return \%end;
}

sub thumbnail {
    my ($token) = @_;
    return ($token->{name} // '') eq 'img' && !$token->{close}
        && ($token->{attrs}{src} // '') =~ m{\A(?:(?i:https?):)?//(?i:classroom\.google\.com)/webthumbnail(?:[/?#]|\z)};
}

sub attachment_link {
    my ($href, $title) = @_;
    $href =~ s/&amp;/&/gi;
    # Gleichnamiger Text im Fragment gehört zum Linkziel.
    my ($address, $fragment) = split /#/, $href, 2;
    my ($path, $query) = split /\?/, ($address // ''), 2;
    if (defined $query) {
        my @parameters = grep { !/^authuser=/ } split /&/, $query, -1;
        $href = $path . (@parameters ? '?' . join('&', @parameters) : '')
            . (defined($fragment) ? '#' . $fragment : '');
    }
    $href =~ s/&(?!(?:\#\d+|\#x[0-9a-f]+|[a-z][a-z0-9]+);)/&amp;/gi;
    $href =~ s/"/&quot;/g;
    return qq{<a href="$href">$title</a>};
}

sub classroom_links {
    my ($tokens) = @_;
    my $ends = element_ends($tokens, 'a', 'div');
    my @output;
    for (my $i = 0; $i < @$tokens; $i++) {
        my $token = $tokens->[$i];
        my $end = $ends->{$i};
        if (($token->{name} // '') eq 'a' && defined($end) && exists($token->{attrs}{href})
            && grep { thumbnail($_) } @$tokens[$i + 1 .. $end - 1]) {
            my $title = '';
            for my $j ($i + 1 .. $end - 1) {
                my $candidate = $tokens->[$j];
                next unless ($candidate->{name} // '') eq 'div' && defined($ends->{$j})
                    && $ends->{$j} < $end
                    && ($candidate->{attrs}{class} // '') =~ /(?:^|\s)\Q$classroom_title_class\E(?:\s|$)/;
                $title = join '', map { $_->{raw} =~ /^</ ? '' : $_->{raw} }
                    @$tokens[$j + 1 .. $ends->{$j} - 1];
                $title =~ s/^\s+|\s+$//g;
                last;
            }
            my $link = attachment_link($token->{attrs}{href}, $title);
            push @output, $title ne '' ? { raw => "<li>$link</li>", attachment => 1 } : { raw => $link };
            $i = $end;
        } elsif (!thumbnail($token)) {
            push @output, $token;
        }
    }
    return \@output;
}

sub blank_text {
    my ($token) = @_;
    return !$token->{opaque} && $token->{raw} =~ /^\s*$/;
}

sub group_attachment_lists {
    my ($tokens) = @_;
    my (@output, @space);
    for my $token (@$tokens) {
        if (blank_text($token)) {
            push @space, $token;
            next;
        }
        if (($token->{name} // '') eq 'div' && $token->{close}
            && @output && ($output[-1]{name} // '') eq 'div' && !$output[-1]{close}
            && !$output[-1]{self_closing}) {
            pop @output;
            # Whitespace vor dem entfernten Div bleibt erhalten.
            undef @space;
            while (@output && blank_text($output[-1])) {
                unshift @space, pop @output;
            }
            next;
        }
        push @output, @space, $token;
        undef @space;
    }
    push @output, @space;

    my $html = '';
    for (my $i = 0; $i < @output; $i++) {
        my $token = $output[$i];
        if (!$token->{attachment}) {
            $html .= $token->{raw};
            next;
        }
        $html .= '<ul>' . $token->{raw};
        while (1) {
            my $next = $i + 1;
            $next++ while $next < @output
                && (blank_text($output[$next]) || ($output[$next]{name} // '') eq 'div');
            if ($next < @output && $output[$next]{attachment}) {
                # Zwischen Anhängen sind die Classroom-Divs reine Verpackung.
                if (!grep { ($_->{name} // '') eq 'div' } @output[$i + 1 .. $next - 1]) {
                    $html .= join '', map { $_->{raw} } @output[$i + 1 .. $next - 1];
                }
                $html .= $output[$next]{raw};
                $i = $next;
                next;
            }
            while ($i + 1 < @output && blank_text($output[$i + 1])) {
                $html .= $output[++$i]{raw};
            }
            last;
        }
        $html .= '</ul>';
    }
    return $html;
}

sub numeric_entity {
    my ($hex, $decimal) = @_;
    my $digits = lc($hex // $decimal);
    $digits =~ s/^0+(?=.)//;
    my $max = defined($hex) ? '10ffff' : '1114111';
    return "\x{fffd}" if length($digits) > length($max)
        || (length($digits) == length($max) && $digits gt $max);
    my $point = defined($hex) ? hex($digits) : $digits;
    return "\x{fffd}" if $point >= 0xd800 && $point <= 0xdfff;
    return chr($point);
}

sub check_table_spans {
    my ($tokens) = @_;
    for my $token (@$tokens) {
        next unless ($token->{name} // '') =~ /^(td|th)$/ && !$token->{close};
        for my $name ('rowspan', 'colspan') {
            next unless exists $token->{attrs}{$name};
            my $value = $token->{attrs}{$name};
            $value =~ s/&#(?:x([0-9a-f]+)|([0-9]+));?/numeric_entity($1, $2)/gie;
            $value =~ s/^\s+|\s+$//g;
            my $duplicates = grep { $_->[2] eq $name } @{$token->{ranges}};
            if ($value !~ /^0*[1-9][0-9]*$/ || $duplicates != 1) {
                append_result('table-ambiguous', 1);
                die "Tabellenspannweite muss eine eindeutige positive Ganzzahl sein.\n";
            }
        }
    }
}

sub protect_rtf_code {
    my ($tokens) = @_;
    my $ends = element_ends($tokens, 'pre');
    my @protected;
    for (my $i = 0; $i < @$tokens; $i++) {
        if (defined(my $end = $ends->{$i})) {
            push @protected, { raw => join('', map { $_->{raw} } @$tokens[$i .. $end]), opaque => 1 };
            $i = $end;
        } else {
            push @protected, $tokens->[$i];
        }
    }
    return \@protected;
}

sub flatten_layout_tables {
    my ($tokens, $ends) = @_;
    my $flattened = 0;
    for (my $i = 0; $i < @$tokens; $i++) {
        my $name = $tokens->[$i]{name} // '';
        my $end = $ends->{$i};
        next unless $name eq 'table' && !$tokens->[$i]{close} && !$tokens->[$i]{self_closing};
        # Eine offene Außentabelle ohne Abschluss lässt sich nicht sicher umschreiben.
        last unless defined $end;
        my ($tables, $row_cells, $has_heading, $has_multiple_cells) = (1, 0, 0, 0);
        for my $j ($i + 1 .. $end - 1) {
            my $token = $tokens->[$j];
            my $name = $token->{name} // '';
            if ($name eq 'tr') {
                $has_multiple_cells = 1 if $token->{close} && $row_cells >= 2;
                $row_cells = 0;
            } elsif (!$token->{close}) {
                $tables++ if $name eq 'table' && !$token->{self_closing};
                $has_heading = 1 if $name eq 'th';
                $row_cells++ if $name eq 'td' || $name eq 'th';
            }
        }
        # Verschachtelte RTF-Tabellen und einspaltige Tabellen ohne Kopf
        # dienen dem Layout. Datenmatrizen bleiben für Pandoc erhalten.
        if ($tables > 1 || (!$has_heading && !$has_multiple_cells)) {
            $flattened += $tables;
            if (($ENV{MD_CLIP_STRICT} // '') eq '1') {
                append_result('layout-tables-flattened', $flattened);
                die "Strenger Modus: RTF-Layouttabelle müsste vereinfacht werden.\n";
            }
            for (my $j = $i; $j <= $end; $j++) {
                my $token = $tokens->[$j];
                my $name = $token->{name} // '';
                if ($name eq 'colgroup' && defined($ends->{$j}) && $ends->{$j} < $end) {
                    $tokens->[$_] = { raw => '' } for $j .. $ends->{$j};
                    $j = $ends->{$j};
                } elsif ($name =~ /^(table|colgroup|col|t(?:body|head|foot)|tr)$/) {
                    $tokens->[$j] = { raw => '' };
                } elsif ($name eq 'td' || $name eq 'th') {
                    $tokens->[$j] = { raw => $token->{close} ? '</p>' : '<p>', name => 'p',
                                     close => $token->{close} };
                }
            }
        }
        $i = $end;
    }
    append_result('layout-tables-flattened', $flattened) if $flattened;
}

sub unwrap_list_paragraphs {
    my ($tokens) = @_;
    my $ends = element_ends($tokens, 'li', 'p');
    for (my $i = 0; $i < @$tokens; $i++) {
        my $name = $tokens->[$i]{name} // '';
        my $end = $ends->{$i};
        next unless defined $end;
        next unless $name eq 'li';
        my ($first, $last) = ($i + 1, $end - 1);
        $first++ while $first <= $last && blank_text($tokens->[$first]);
        $last-- while $last >= $first && blank_text($tokens->[$last]);
        next unless ($tokens->[$first]{name} // '') eq 'p' && ($ends->{$first} // -1) == $last;
        next if grep { ($_->{name} // '') eq 'p' } @$tokens[$first + 1 .. $last - 1];
        $tokens->[$_]{raw} = '' for ($i + 1 .. $first, $last .. $end - 1);
    }
}

my $mode = shift // '';
die "HTML-Vorverarbeitung: html oder rtf-html erwartet.\n"
    unless $mode eq 'html' || $mode eq 'rtf-html';

my $html = do { local $/; <STDIN> } // '';
# Manche Clipboard-HTML-Angebote enden mit einem C-String-Terminator.
$html =~ s/\x00+\z//;
my $tokens = tokenize($html);
my $tables_as_text = ($ENV{MD_CLIP_TABLES} // '') eq 'text';
if ($mode eq 'html') {
    repair_source_code($tokens);
    $tokens = classroom_links($tokens);
    check_table_spans($tokens) if $tables_as_text;
    print group_attachment_lists($tokens);
} else {
    $tokens = protect_rtf_code($tokens);
    if ($tables_as_text) {
        check_table_spans($tokens);
    } else {
        flatten_layout_tables($tokens, element_ends($tokens, 'table', 'colgroup'));
    }
    unwrap_list_paragraphs($tokens);
    print join '', map { $_->{raw} } @$tokens;
}
