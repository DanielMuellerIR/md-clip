#!/usr/bin/env perl
use strict;
use warnings;

my $mode = shift // '';
die "HTML-Vorverarbeitung: claude|classroom erwartet\n"
    unless $mode eq 'claude' || $mode eq 'classroom';
my $html = do { local $/; <STDIN> } // '';
my $tag_body = qr/(?:[^"'<>]|"[^"]*"|'[^']*')*/;
my $markup = qr/<!--.*?-->|<![^>]*>|<\/?[A-Za-z][A-Za-z0-9:_-]*$tag_body>/s;
my @tokens;
my $cursor = 0;

# Nur die Quellenreparatur braucht rohe Tags. Attribute werden als ganze
# Tokens gelesen, damit ein > oder scheinbares data-line im Titel nichts trennt.
while ($html =~ /$markup/g) {
    push @tokens, { raw => substr($html, $cursor, $-[0] - $cursor) } if $-[0] > $cursor;
    my $raw = $&;
    $cursor = $+[0];
    my $token = { raw => $raw };
    if ($raw =~ /^<(\/?)([A-Za-z][A-Za-z0-9:_-]*)\b/) {
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
    }
    push @tokens, $token;
    # JavaScript/CSS sind Rohtext; deren String-Literale sind keine HTML-Tags.
    if ($token->{name} && !$token->{close} && $token->{name} =~ /^(script|style)$/) {
        my $name = $token->{name};
        pos($html) = $cursor;
        if ($html =~ m{</\Q$name\E\s*>}ig) {
            push @tokens, { raw => substr($html, $cursor, $-[0] - $cursor) };
            push @tokens, { raw => $&, name => $name, close => 1, attrs => {} };
            $cursor = $+[0];
        } else {
            last;
        }
    }
    pos($html) = $cursor;
}
push @tokens, { raw => substr($html, $cursor) } if $cursor < length $html;

if ($mode eq 'claude') {
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
        && ($token->{attrs}{src} // '') =~ m{classroom\.google\.com/webthumbnail};
}

my $output = '';
for (my $i = 0; $i < @tokens; $i++) {
    my $token = $tokens[$i];
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
            $href =~ s/([?&])authuser=[^&#]*&/$1/g;
            $href =~ s/[?&]authuser=[^&#]*//g;
            $href =~ s/\?&/?/g;
            $href =~ s/[?&](?=#|$)//g;
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

my $div = qr/<\/?div\b$tag_body>/i;
my $opaque = qr{<!--.*?-->|<script\b$tag_body>.*?</script\s*>|<style\b$tag_body>.*?</style\s*>}is;
1 while $output =~ s{$opaque(*SKIP)(*F)|<div\b$tag_body>\s*</div\s*>}{}gi;
1 while $output =~ s{$opaque(*SKIP)(*F)|(<li data-md-clip-classroom="1">.*?</li>)(?:\s*$div\s*)+(?=<li data-md-clip-classroom="1">)}{$1}gs;
$output =~ s{$opaque(*SKIP)(*F)|(?:<li data-md-clip-classroom="1">.*?</li>\s*)+}{
    my $items = $&;
    $items =~ s/ data-md-clip-classroom="1"//g;
    "<ul>$items</ul>";
}gse;
print $output;
