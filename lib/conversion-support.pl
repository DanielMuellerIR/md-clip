#!/usr/bin/env perl
use strict;
use warnings;

sub has_visible_text {
    my ($bytes) = @_;
    # utf8::decode ist auch mit Debians perl-base ohne Encode.pm verfügbar.
    my $text = $bytes;
    $text = $bytes unless utf8::decode($text);
    return $text =~ /[^\s\p{White_Space}\p{Default_Ignorable_Code_Point}]/;
}

sub append_result {
    my ($code, $count) = @_;
    my $path = $ENV{MD_CLIP_RESULT_FILE};
    return unless defined $path && length $path;
    my $error = "Konvertierungsbericht konnte nicht geschrieben werden.\n";
    open(my $file, '>>', $path) or die $error;
    print {$file} "$code\t$count\n" or die $error;
    close($file) or die $error;
}

sub check_rtf_header {
    my ($path) = @_;
    open(my $input, '<', $path) or die "RTF-Quelle konnte nicht geöffnet werden.\n";
    binmode($input);
    my $head = '';
    my $first = 1;
    while (length($head) < 7) {
        my $count = read($input, my $chunk, 4096);
        die "RTF-Kopf konnte nicht gelesen werden.\n" unless defined $count;
        last unless $count;
        $head .= $chunk;
        $head =~ s/\A\xEF\xBB\xBF// if $first;
        $first = 0;
        $head =~ s/\A[ \t\r\n\f\x0b]+//;
    }
    close($input);
    return 1 if $head =~ /\A\{\\rtf1(?=[^A-Za-z0-9]|$)/;
    append_result('rtf-header-invalid', 1);
    return 0;
}

unless (caller) {
    my $mode = shift // '';
    if ($mode eq 'visible') {
        my $text = do { local $/; <STDIN> } // '';
        print has_visible_text($text) ? 'yes' : 'no';
    } elsif ($mode eq 'rtf-header' && @ARGV == 1) {
        exit(check_rtf_header($ARGV[0]) ? 0 : 1);
    } else {
        die "Konvertierungsprüfung: visible oder rtf-header DATEI erwartet.\n";
    }
}

1;
