#!/usr/bin/env perl
use strict;
use warnings;

my $mode = shift // '';
die "HTML-Vorverarbeitung: claude|classroom|tables erwartet\n"
    unless $mode eq 'claude' || $mode eq 'classroom' || $mode eq 'tables';
my $html = do { local $/; <STDIN> } // '';
# Manche Clipboard-HTML-Angebote enden mit einem C-String-Terminator.
# Nur diesen Abschluss entfernen; NUL im Inhalt und Klartext bleiben unverändert.
$html =~ s/\x00+\z//;
my $tag_body = qr/(?:[^"'<>]|"[^"]*"|'[^']*')*/;
my $markup = qr/<!--.*?-->|<!\[CDATA\[.*?\]\]>|<\?.*?\?>|<![^>]*>|<\/?[A-Za-z][A-Za-z0-9:_-]*$tag_body>/s;
my @tokens;
my $cursor = 0;

# Nur die Quellenreparatur braucht rohe Tags. Attribute werden als ganze
# Tokens gelesen, damit ein > oder scheinbares data-line im Titel nichts trennt.
while ($html =~ /$markup/g) {
    push @tokens, { raw => substr($html, $cursor, $-[0] - $cursor) } if $-[0] > $cursor;
    my $raw = $&;
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
            push @tokens, { raw => $&, name => $name, close => 1, attrs => {} };
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
@tokens = @protected;

if ($mode eq 'tables') {
    for my $token (@tokens) {
        next unless ($token->{name} // '') =~ /^(td|th)$/ && !$token->{close};
        for my $name ('rowspan', 'colspan') {
            next unless exists $token->{attrs}{$name};
            my $value = $token->{attrs}{$name};
            $value =~ s/&#(?:x([0-9a-f]+)|(\d+));?/chr(defined($1) ? hex($1) : $2)/gie;
            $value =~ s/^\s+|\s+$//g;
            my $duplicates = grep { $_->[2] eq $name } @{$token->{ranges}};
            if ($value !~ /^0*[1-9][0-9]*$/ || $duplicates != 1) {
                if (my $path = $ENV{MD_CLIP_RESULT_FILE}) {
                    open(my $status, '>>', $path) or die "Statusdatei: $!";
                    print {$status} "table-ambiguous\t1\n";
                    close($status) or die "Statusdatei: $!";
                }
                die "Tabellenspannweite muss eine eindeutige positive Ganzzahl sein.\n";
            }
        }
    }
    print $html;
    exit;
}

if ($mode eq 'claude') {
    # Reiner pre-Text braucht ein code-Kind, damit pandoc die Vorformatierung
    # erhält. Rich-Inhalt und unvollständige/verschachtelte pre-Blöcke ausnehmen.
    my @pre_frames;
    for my $i (0 .. $#tokens) {
        my $token = $tokens[$i];
        my $name = $token->{name} // '';
        if ($name eq 'pre') {
            if (!$token->{close}) {
                $pre_frames[-1]{eligible} = 0 if @pre_frames;
                push @pre_frames, { start => $i, eligible => !@pre_frames && !$token->{self_closing}, breaks => [] };
            } elsif (@pre_frames) {
                my $frame = pop @pre_frames;
                if ($frame->{eligible} && !$frame->{code}) {
                    $tokens[$frame->{start}]{raw} .= '<code>';
                    $token->{raw} = '</code>' . $token->{raw};
                    for my $line_break (@{$frame->{breaks}}) { $tokens[$line_break] = { raw => "\n" }; }
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
    for my $token (@tokens) {
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
        print $raw;
    }
    exit;
}

sub closing_tag {
    my ($start, $name) = @_;
    my $depth = 1;
    for my $i ($start + 1 .. $#tokens) {
        next unless ($tokens[$i]{name} // '') eq $name;
        $depth += $tokens[$i]{close} ? -1 : 1;
        return $i if !$depth;
    }
    return;
}

sub thumbnail {
    my ($token) = @_;
    return ($token->{name} // '') eq 'img' && !$token->{close}
        && ($token->{attrs}{src} // '') =~ m{\A(?:(?i:https?):)?//(?i:classroom\.google\.com)/webthumbnail(?:[/?#]|\z)};
}

sub cleanup_classroom {
    my ($output) = @_;
    my $div = qr/<\/?div\b$tag_body>/i;
    my $opaque = qr{<!--.*?-->|<script\b$tag_body>.*?</script\s*>|<style\b$tag_body>.*?</style\s*>}is;
    1 while $output =~ s{$opaque(*SKIP)(*F)|<div\b$tag_body>\s*</div\s*>}{}gi;
    1 while $output =~ s{$opaque(*SKIP)(*F)|(<li data-md-clip-classroom="1">.*?</li>)(?:\s*$div\s*)+(?=<li data-md-clip-classroom="1">)}{$1}gs;
    $output =~ s{$opaque(*SKIP)(*F)|(?:<li data-md-clip-classroom="1">.*?</li>\s*)+}{
        my $items = $&;
        $items =~ s/ data-md-clip-classroom="1"//g;
        "<ul>$items</ul>";
    }gse;
    return $output;
}

my $output = '';
for (my $i = 0; $i < @tokens; $i++) {
    my $token = $tokens[$i];
    if ($token->{svg} || $token->{opaque}) {
        print cleanup_classroom($output), $token->{raw};
        $output = '';
        next;
    }
    if (($token->{name} // '') eq 'a' && !$token->{close} && exists $token->{attrs}{href}) {
        my $end = closing_tag($i, 'a');
        if (defined $end && grep { thumbnail($_) } @tokens[$i + 1 .. $end - 1]) {
            my $title = '';
            for my $j ($i + 1 .. $end - 1) {
                my $candidate = $tokens[$j];
                next unless ($candidate->{name} // '') eq 'div' && !$candidate->{close}
                    && ($candidate->{attrs}{class} // '') =~ /(?:^|\s)mvRF3b(?:\s|$)/;
                my $last = closing_tag($j, 'div');
                next unless defined $last && $last < $end;
                $title = join '', map { $_->{raw} =~ /^</ ? '' : $_->{raw} } @tokens[$j + 1 .. $last - 1];
                $title =~ s/^\s+|\s+$//g;
                last;
            }
            my $href = $token->{attrs}{href};
            $href =~ s/&amp;/&/gi;
            # Nur Query-Parameter entfernen; gleichnamiger Fragmenttext ist
            # Teil des Linkziels. Wiederholte Parameter einzeln behandeln.
            my ($address, $fragment) = split /#/, $href, 2;
            my ($path, $query) = split /\?/, ($address // ''), 2;
            if (defined $query) {
                my @parameters = grep { !/^authuser=/ } split /&/, $query, -1;
                $href = $path . (@parameters ? '?' . join('&', @parameters) : '')
                    . (defined($fragment) ? '#' . $fragment : '');
            }
            # Bereits maskierte Anführungszeichen bleiben maskiert; nur nackte
            # Query-Trenner werden für das neu erzeugte Attribut kodiert.
            $href =~ s/&(?!(?:\#\d+|\#x[0-9a-f]+|[a-z][a-z0-9]+);)/&amp;/gi;
            $href =~ s/"/&quot;/g;
            $output .= $title ne ''
                ? qq{<li data-md-clip-classroom="1"><a href="$href">$title</a></li>}
                : qq{<a href="$href"></a>};
            $i = $end;
            next;
        }
    }
    $output .= $token->{raw} unless thumbnail($token);
}

print cleanup_classroom($output);
