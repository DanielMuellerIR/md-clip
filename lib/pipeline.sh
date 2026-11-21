#!/usr/bin/env bash
# Gemeinsame Pipeline für Produkt und Fixtures. Der Aufrufer stellt
# rtf_to_html bereit und aktiviert pipefail, damit jede Stufe Fehler meldet.

case "${BASH_SOURCE[0]}" in
  */*) _MD_CLIP_LIB_DIR="${BASH_SOURCE[0]%/*}" ;;
  *) _MD_CLIP_LIB_DIR=. ;;
esac
case "$_MD_CLIP_LIB_DIR" in
  /*) ;;
  *) _MD_CLIP_LIB_DIR="$PWD/$_MD_CLIP_LIB_DIR" ;;
esac

preprocess_html() {
  perl "$_MD_CLIP_LIB_DIR/preprocess-html.pl" html
}

preprocess_rtf_html() {
  perl "$_MD_CLIP_LIB_DIR/preprocess-html.pl" rtf-html
}

rtf_fix_escaped_newlines() {
  perl -0pe 's/(?<!\\)((?:\\\\)*)\\(\r?\n)/$1\\par$2/g'
}

# Der Check lässt die erfassten Bytes für den Reader unverändert.
check_rtf_header() {
  [ "$#" -eq 1 ] || return 2
  perl "$_MD_CLIP_LIB_DIR/conversion-support.pl" rtf-header "$1"
}

tidy_markdown() {
  local target_format="${1:-gfm}"
  case "$target_format" in
    gfm|markdown|commonmark) ;;
    *)
      printf 'tidy_markdown: unbekanntes Zielformat: %s\n' "$target_format" >&2
      return 2
      ;;
  esac

  perl "$_MD_CLIP_LIB_DIR/tidy-markdown.pl" "$target_format" "${2:-}"
}

pandoc_supports_rtf() {
  pandoc --list-input-formats 2>/dev/null | grep -Fxq 'rtf'
}

# Die Sandbox ist für Clipboard-Inhalte verpflichtend und fehlt in alten Versionen.
pandoc_supports_sandbox() {
  printf '' | pandoc --sandbox -f html -t plain >/dev/null 2>&1
}

# Eine echte Tabelle prüft die benötigte Lua-API einschließlich Tabellenzellen.
pandoc_supports_table_filter() {
  printf '%s' '<table><tr><th>A</th></tr><tr><td>x<br>y</td></tr></table>' \
    | MD_CLIP_RESULT_FILE= pandoc --sandbox -f html -t gfm-raw_html \
      --lua-filter="$_MD_CLIP_LIB_DIR/pandoc-filter.lua" >/dev/null 2>&1
}

# Pipe- und Gittertabellen beginnen mit |. So schützt die Nachbearbeitung
# die spaltenrelevanten Escapes in jedem Zielformat.
pandoc_table_extensions() {
  case "${1:-gfm}" in
    markdown)   printf '%s' '-simple_tables-multiline_tables' ;;
    commonmark) printf '%s' '+pipe_tables' ;;
    *)          printf '%s' '' ;;
  esac
}

run_pandoc() {
  local target_format="${1:-gfm}" table_extensions code_extensions
  table_extensions="$(pandoc_table_extensions "$target_format")"
  # Pandoc 3.1.3 liest einen sprachlosen Backtick-Zaun direkt hinter einem
  # Listenmarker als Inline-Code. Tilde-Zäune erhalten dort den Codeblock.
  case "$target_format" in
    markdown) code_extensions=-backtick_code_blocks ;;
    *) code_extensions= ;;
  esac
  pandoc -f html -t "${target_format}-raw_html${table_extensions}${code_extensions}" \
    --wrap=none --sandbox --lua-filter="$_MD_CLIP_LIB_DIR/pandoc-filter.lua"
}

html_to_markdown() {
  local target_format="${1:-gfm}"
  run_pandoc "$target_format" | tidy_markdown "$target_format" --require-visible
}

convert_html() {
  local target_format="${1:-gfm}"
  if declare -F vlog >/dev/null 2>&1; then
    vlog "Pfad: HTML → pandoc"
  fi
  preprocess_html | html_to_markdown "$target_format"
}

convert_rtf() {
  local target_format="${1:-gfm}"
  if declare -F vlog >/dev/null 2>&1; then
    vlog "Pfad: RTF → HTML → pandoc"
  fi
  rtf_to_html | preprocess_rtf_html | html_to_markdown "$target_format"
}
