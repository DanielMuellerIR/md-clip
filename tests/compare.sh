#!/usr/bin/env bash
# tests/compare.sh — Vergleicht md-clip mit Apples eingebauter Kurzbefehl-
# Aktion „Aus Rich Text Markdown erstellen" anhand des aktuellen Clipboards.
#
# Was passiert:
#   1. HTML-Flavor des Clipboards → <name>.html
#   2. RTF-Flavor des Clipboards → <name>.rtf
#   3. md-clip-Output → <name>.mdclip.md
#   4. Apples Kurzbefehl AppleMD → <name>.applemd.md
#
# Dateiname <name> wird aus den ersten Worten des Klartext-Clipboards
# gebildet: max. 7 Wörter, max. 35 Zeichen — je nachdem, was kürzer ist.
#
# Voraussetzung: ein Kurzbefehl namens „AppleMD" muss in Kurzbefehle.app
# existieren mit den Aktionen [Inhalt der Zwischenablage abrufen] →
# [Aus Rich Text Markdown erstellen]. KEINE Schnellansicht als letzte
# Aktion — sonst lässt sich der Output nicht in eine Datei umleiten.

set -euo pipefail

# Projekt-Root und Ausgabe-Verzeichnis.
PROJECT_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
CAPTURES_DIR="$PROJECT_ROOT/tests/captures"
mkdir -p "$CAPTURES_DIR"
cd "$PROJECT_ROOT"

# --- 1. Dateinamen-Basis bestimmen ---
# Wenn das Skript von compare-file.sh aufgerufen wird, kann dort eine
# stabile Basis (= Dateiname ohne Endung) per Env-Variable vorgegeben
# werden. Das vermeidet hässliche Auto-Namen wie „rtf1-ansi-ansicpg…"
# bei Clipboards, die nur RTF-Quelle als Plain-Text liefern.
if [ -n "${BASENAME_OVERRIDE:-}" ]; then
  base="$BASENAME_OVERRIDE"
else
  # Sonst: aus dem Klartext-Clipboard ableiten.
  plain="$(pbpaste)"
  if [ -z "$plain" ]; then
    echo "Clipboard ist leer — nichts zu vergleichen." >&2
    exit 1
  fi

  # Strategie:
  #   a) Klartext auf erste 7 Wörter zuschneiden.
  #   b) Ergebnis auf max. 35 Zeichen kürzen (UTF-8-sicher).
  #   c) Nicht-Wort-Zeichen durch `-` ersetzen.
  #   d) Mehrfach-Bindestriche kollabieren, führende/trailing entfernen.
  # Falls am Ende leer (z.B. nur Sonderzeichen kopiert): Timestamp-Fallback.
  base="$(
  printf '%s' "$plain" \
    | tr '\n\t' '  ' \
    | awk '{
        # Erste 7 Felder ausgeben, mit Leerzeichen verbunden.
        n = (NF < 7) ? NF : 7
        for (i = 1; i <= n; i++) printf "%s%s", $i, (i < n ? " " : "")
      }' \
    | perl -CSDA -e '
        # UTF-8-sichere Truncation auf 35 Zeichen + Sanitize.
        undef $/;
        my $s = <>;
        $s = substr($s, 0, 35);
        # \p{Word} matcht Buchstaben (auch Umlaute), Ziffern, _.
        # Alles andere → Bindestrich.
        $s =~ s/[^\p{Word}._-]+/-/g;
        $s =~ s/-+/-/g;
        $s =~ s/^-//;
        $s =~ s/-$//;
        print $s;
      '
)"

  if [ -z "$base" ]; then
    base="clip-$(date +%Y%m%d-%H%M%S)"
  fi
fi

echo "==> Basis-Dateiname: $base"
echo "==> Ausgabe-Ordner:  $CAPTURES_DIR"
echo

# --- 3. HTML-Flavor sichern ---
HTML_HELPER="$PROJECT_ROOT/helpers/clipboard-html"
if html="$("$HTML_HELPER" 2>/dev/null)"; then
  printf '%s' "$html" > "$CAPTURES_DIR/${base}.html"
  printf '✓ HTML    → %s.html (%d Bytes)\n' "$base" "$(wc -c < "$CAPTURES_DIR/${base}.html")"
else
  printf '· HTML    — kein HTML-Flavor auf dem Clipboard\n'
fi

# --- 4. RTF-Flavor sichern ---
# Wir nutzen den eigenen Swift-Helper, NICHT `pbpaste -Prefer rtf`.
# Grund: pbpaste weicht auf Plain Text aus, sobald zusätzlich RTFD auf
# dem Clipboard liegt (z.B. TextEdit mit Bildern). Der Helper greift
# direkt auf den .rtf-Flavor in NSPasteboard zu.
RTF_HELPER="$PROJECT_ROOT/helpers/clipboard-rtf"
if rtf="$("$RTF_HELPER" 2>/dev/null)"; then
  printf '%s' "$rtf" > "$CAPTURES_DIR/${base}.rtf"
  printf '✓ RTF     → %s.rtf (%d Bytes)\n' "$base" "$(wc -c < "$CAPTURES_DIR/${base}.rtf")"
else
  printf '· RTF     — kein RTF-Flavor auf dem Clipboard\n'
fi

# --- 5. md-clip-Konvertierung sichern ---
# md-clip ohne --replace verändert das Clipboard NICHT — wichtig, weil
# AppleMD danach noch dasselbe Clipboard lesen soll.
if ./bin/md-clip --quiet > "$CAPTURES_DIR/${base}.mdclip.md" 2>/dev/null; then
  printf '✓ md-clip → %s.mdclip.md\n' "$base"
else
  printf '✗ md-clip — Aufruf fehlgeschlagen\n'
fi

# --- 6. AppleMD-Output abgreifen (nur im Manual-Modus) ---
# `shortcuts run` als CLI ist kaputt: es kommt nicht zuverlässig ans
# Clipboard. Deshalb gibt es einen halbautomatischen Modus, in dem das
# Skript pausiert, der Nutzer AppleMD per Hotkey/Kurzbefehle.app auslöst
# und das Resultat zurück ins Clipboard schreiben lässt — dann greifen
# wir es per pbpaste ab. Eingeschaltet per Env-Variable.
if [ "${CAPTURE_APPLEMD_MANUAL:-0}" = "1" ]; then
  echo
  echo "============================================================"
  echo "JETZT manuell AppleMD aufrufen:"
  echo "  - Hotkey oder via Kurzbefehle.app"
  echo "  - AppleMD muss als letzte Aktion „In Zwischenablage kopieren"
  echo "    haben, damit wir das Resultat hier abgreifen können."
  echo
  echo "Dann hier Enter drücken."
  echo "============================================================"
  read -r _ < /dev/tty

  applemd_out="$(pbpaste)"
  applemd_file="$CAPTURES_DIR/${base}.applemd.md"

  if [ -z "$applemd_out" ]; then
    printf '✗ AppleMD — Clipboard war leer. Hat AppleMD wirklich gelaufen?\n'
  elif [ "$applemd_out" = "${plain:-}" ]; then
    printf '✗ AppleMD — Clipboard hat noch den Source-Inhalt. Apple hat\n'
    printf '            wahrscheinlich nichts überschrieben (Schnellansicht\n'
    printf '            statt „In Zwischenablage kopieren" am Ende?).\n'
  else
    printf '%s' "$applemd_out" > "$applemd_file"
    printf '✓ AppleMD → %s.applemd.md (%d Zeichen)\n' "$base" "${#applemd_out}"
  fi
fi

echo
echo "Fertig. Dateien in: $CAPTURES_DIR/"
