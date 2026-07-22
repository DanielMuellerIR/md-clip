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
fill_empty_html_links() {
  perl -0pe '
    s{<a\b([^>]*\bhref\s*=\s*(?:"([^"]*)"|\x27([^\x27]*)\x27)[^>]*)>\s*</a>}{
      my $attributes = $1;
      my $href = defined($2) ? $2 : $3;
      # Span verhindert pandocs Autolink-Kürzung, die Link-Titel verwirft.
      "<a$attributes><span>$href</span></a>"
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

tidy_rtf_artifacts() {
  perl -0pe '
    s/^\\\s*$//gm;
    s/\n{3,}/\n\n/g;
  '
}

tidy_hard_breaks() {
  perl -0pe '
    s/[ \t]*(?:\\|[ ]{2,})\n(?=[ \t]*(?:[-*+] |\d+[.)] ))/\n/g;
    s/^[ \t]*\\?[ \t]*$//gm;
    s/[ \t]*(?:\\|[ ]{2,})\n(?=[ \t]*\n)/\n/g;
    s/\n{3,}/\n\n/g;
    s/[ \t]*(?:\\|[ ]{2,})[ \t]*(\n*)\z/$1/;
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
    | tidy_hard_breaks
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
    | tidy_rtf_artifacts \
    | tidy_hard_breaks
}
