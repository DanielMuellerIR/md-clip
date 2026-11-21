#!/usr/bin/env bash
# Liest den Bericht der Pipeline und bewertet Strukturverluste.

CONVERTED=0
RESULT=""
TABLE_CELLS_FLATTENED=0
LAYOUT_TABLES_FLATTENED=0
TABLES_TEXT=0
IMAGES_ALT=0
IMAGES_OMITTED=0
SOURCE_REASON=""

# Der Bericht enthält nur feste Kennungen und Anzahlen, niemals Nutztext.
# Neue Kennungen werden ausdrücklich aufgenommen, statt fremde Daten als
# Shell-Ausdruck oder als erfolgreich bewertete Konvertierung zu behandeln.
read_conversion_report() {
  local record="" code count count_value
  TABLE_CELLS_FLATTENED=0
  LAYOUT_TABLES_FLATTENED=0
  TABLES_TEXT=0
  IMAGES_ALT=0
  IMAGES_OMITTED=0
  SOURCE_REASON=""
  if [ ! -f "$MD_CLIP_RESULT_FILE" ]; then
    err "Konvertierungsbericht konnte nicht gelesen werden."
    return 3
  fi
  # Bash lässt NUL in einer zeilenweisen Abfrage weg. Der Bericht darf
  # ausschließlich die Bytes des TSV-Formats enthalten.
  if IFS= read -r -d '' record < "$MD_CLIP_RESULT_FILE"; then
    err "Ungültiger Konvertierungsbericht."
    return 3
  fi
  record=""
  while IFS= read -r record; do
    case "$record" in
      *$'\t'*) code=${record%%$'\t'*}; count=${record#*$'\t'} ;;
      *) err "Ungültiger Konvertierungsbericht."; return 3 ;;
    esac
    case "$count" in
      ""|*[!0-9]*) err "Ungültiger Konvertierungsbericht."; return 3 ;;
    esac
    [ "${#count}" -le 9 ] || { err "Ungültiger Konvertierungsbericht."; return 3; }
    count_value=$((10#$count))
    [ "$count_value" -gt 0 ] || { err "Ungültiger Konvertierungsbericht."; return 3; }
    case "$code" in
      table-cells-flattened) TABLE_CELLS_FLATTENED=$((TABLE_CELLS_FLATTENED + count_value)) ;;
      layout-tables-flattened) LAYOUT_TABLES_FLATTENED=$((LAYOUT_TABLES_FLATTENED + count_value)) ;;
      tables-text) TABLES_TEXT=$((TABLES_TEXT + count_value)) ;;
      images-alt) IMAGES_ALT=$((IMAGES_ALT + count_value)) ;;
      images-omitted) IMAGES_OMITTED=$((IMAGES_OMITTED + count_value)) ;;
      table-nested|table-spanned|table-ambiguous|empty-document|rtf-header-invalid)
        [ -n "$SOURCE_REASON" ] || SOURCE_REASON="$code" ;;
      *) err "Unbekannter Konvertierungsbericht: $code"; return 3 ;;
    esac
  done < "$MD_CLIP_RESULT_FILE" || { err "Konvertierungsbericht konnte nicht gelesen werden."; return 3; }
  [ -z "$record" ] || { err "Unvollständiger Konvertierungsbericht."; return 3; }
}

source_label() {
  case "$1" in html) printf 'HTML' ;; rtf) printf 'RTF' ;; plain) printf 'Klartext' ;; esac
}

source_failure_reason() {
  if [ "$STRICT" -eq 1 ] && { [ "$IMAGES_ALT" -gt 0 ] || [ "$IMAGES_OMITTED" -gt 0 ]; }; then
    printf 'Strenger Modus verbietet die Bildvereinfachung'
    return
  fi
  if [ "$STRICT" -eq 1 ] && { [ "$TABLE_CELLS_FLATTENED" -gt 0 ] || [ "$LAYOUT_TABLES_FLATTENED" -gt 0 ] || [ "$TABLES_TEXT" -gt 0 ]; }; then
    printf 'Strenger Modus verbietet die nötige Strukturvereinfachung'
    return
  fi
  case "$SOURCE_REASON" in
    rtf-header-invalid) printf 'kein gültiger RTF-Kopf' ;;
    table-nested) printf 'verschachtelte Tabelle nicht darstellbar' ;;
    table-spanned) printf 'verbundene Tabellenzellen nicht darstellbar' ;;
    table-ambiguous) printf 'Tabellenzellen nicht eindeutig zuordenbar' ;;
    empty-document)
      if [ "$IMAGES_ALT" -gt 0 ] || [ "$IMAGES_OMITTED" -gt 0 ]; then
        printf 'Bildbehandlung lässt keinen sichtbaren Inhalt'
      else printf 'kein sichtbarer Rich-Text-Inhalt'; fi ;;
    *)
      if [ "$1" -eq 2 ]; then printf 'benötigtes Werkzeug oder Fähigkeit fehlt'
      else printf 'Konvertierung fehlgeschlagen'; fi ;;
  esac
}

report_simplifications() {
  local label
  if [ "$TABLE_CELLS_FLATTENED" -gt 0 ]; then
    label=Tabellenzellen
    if [ "$TABLE_CELLS_FLATTENED" -eq 1 ]; then label=Tabellenzelle; fi
    conversion_note "md-clip: Vereinfachung: $TABLE_CELLS_FLATTENED $label; Blockgrenzen und Umbrüche zusammengeführt."
  fi
  if [ "$LAYOUT_TABLES_FLATTENED" -gt 0 ]; then
    label=RTF-Layouttabellen
    if [ "$LAYOUT_TABLES_FLATTENED" -eq 1 ]; then label=RTF-Layouttabelle; fi
    conversion_note "md-clip: Vereinfachung: $LAYOUT_TABLES_FLATTENED $label in Absätze umgewandelt."
  fi
  if [ "$TABLES_TEXT" -gt 0 ]; then
    label=Tabellen
    if [ "$TABLES_TEXT" -eq 1 ]; then label=Tabelle; fi
    conversion_note "md-clip: Vereinfachung: $TABLES_TEXT $label als beschrifteten Text dargestellt."
  fi
  if [ "$IMAGES_ALT" -gt 0 ]; then
    label=Bilder
    if [ "$IMAGES_ALT" -eq 1 ]; then label=Bild; fi
    conversion_note "md-clip: Vereinfachung: $IMAGES_ALT $label auf Alternativtext reduziert."
  fi
  if [ "$IMAGES_OMITTED" -gt 0 ]; then
    label=Bilder
    if [ "$IMAGES_OMITTED" -eq 1 ]; then label=Bild; fi
    conversion_note "md-clip: Vereinfachung: $IMAGES_OMITTED $label entfernt."
  fi
}

has_simplification() {
  [ "$TABLE_CELLS_FLATTENED" -gt 0 ] || [ "$LAYOUT_TABLES_FLATTENED" -gt 0 ] \
    || [ "$IMAGES_ALT" -gt 0 ] || [ "$IMAGES_OMITTED" -gt 0 ] || [ "$TABLES_TEXT" -gt 0 ]
}
