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
COMPARE_WORK=$(mktemp -d)
trap 'rm -rf "$COMPARE_WORK"' EXIT
trap 'exit 130' INT
trap 'exit 143' TERM

# compare-file.sh bringt aktuelle Leser und Pipeline in einem privaten Layout mit.
RUNTIME_DIR="${MD_CLIP_COMPARE_RUNTIME:-$PROJECT_ROOT/bin}"
if [ -n "${MD_CLIP_COMPARE_RUNTIME:-}" ]; then
  HELPER_DIR="$RUNTIME_DIR"
else
  HELPER_DIR="$PROJECT_ROOT/helpers"
fi

# Dateien erhalten Schluss-LFs; ein identischer Inhalt beweist weder Erfolg
# noch Ausbleiben des manuell ausgelösten Kurzbefehls.
pbpaste > "$COMPARE_WORK/plain"
plain="$(cat "$COMPARE_WORK/plain")"

# --- 1. Dateinamen-Basis bestimmen ---
# Wenn das Skript von compare-file.sh aufgerufen wird, kann dort eine
# stabile Basis (= Dateiname ohne Endung) per Env-Variable vorgegeben
# werden. Das vermeidet hässliche Auto-Namen wie „rtf1-ansi-ansicpg…"
# bei Clipboards, die nur RTF-Quelle als Plain-Text liefern.
if [ -n "${BASENAME_OVERRIDE:-}" ]; then
  base="$BASENAME_OVERRIDE"
else
  # Sonst: aus dem Klartext-Clipboard ableiten.
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
HTML_HELPER="$HELPER_DIR/clipboard-html"
if [ ! -x "$HTML_HELPER" ]; then
  echo "HTML-Helper nicht gebaut: $HTML_HELPER" >&2
  echo "Bitte zuerst ./install.sh ausführen." >&2
  exit 2
fi
if "$HTML_HELPER" > "$COMPARE_WORK/html" 2>/dev/null; then
  mv "$COMPARE_WORK/html" "$CAPTURES_DIR/${base}.html"
  printf '✓ HTML    → %s.html (%d Bytes)\n' "$base" "$(wc -c < "$CAPTURES_DIR/${base}.html")"
else
  printf '· HTML    — kein HTML-Flavor auf dem Clipboard\n'
fi

# --- 4. RTF-Flavor sichern ---
# Wir nutzen den eigenen Swift-Helper, NICHT `pbpaste -Prefer rtf`.
# Grund: pbpaste weicht auf Plain Text aus, sobald zusätzlich RTFD auf
# dem Clipboard liegt (z.B. TextEdit mit Bildern). Der Helper greift
# direkt auf den .rtf-Flavor in NSPasteboard zu.
RTF_HELPER="$HELPER_DIR/clipboard-rtf"
if [ ! -x "$RTF_HELPER" ]; then
  echo "RTF-Helper nicht gebaut: $RTF_HELPER" >&2
  echo "Bitte zuerst ./install.sh ausführen." >&2
  exit 2
fi
if "$RTF_HELPER" > "$COMPARE_WORK/rtf" 2>/dev/null; then
  mv "$COMPARE_WORK/rtf" "$CAPTURES_DIR/${base}.rtf"
  printf '✓ RTF     → %s.rtf (%d Bytes)\n' "$base" "$(wc -c < "$CAPTURES_DIR/${base}.rtf")"
else
  printf '· RTF     — kein RTF-Flavor auf dem Clipboard\n'
fi

# --- 5. md-clip-Konvertierung sichern ---
# md-clip ohne --replace verändert das Clipboard NICHT — wichtig, weil
# AppleMD danach noch dasselbe Clipboard lesen soll.
if "$RUNTIME_DIR/md-clip" --quiet > "$COMPARE_WORK/mdclip.md"; then
  mv "$COMPARE_WORK/mdclip.md" "$CAPTURES_DIR/${base}.mdclip.md"
  printf '✓ md-clip → %s.mdclip.md\n' "$base"
else
  status=$?
  printf '✗ md-clip — Aufruf fehlgeschlagen (Exit %s)\n' "$status" >&2
  exit "$status"
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

  pbpaste > "$COMPARE_WORK/applemd.md"
  applemd_file="$CAPTURES_DIR/${base}.applemd.md"

  if [ ! -s "$COMPARE_WORK/applemd.md" ]; then
    printf '✗ AppleMD — Clipboard war leer; kein Ergebnis gespeichert.\n' >&2
    exit 1
  fi
  if cmp -s "$COMPARE_WORK/plain" "$COMPARE_WORK/applemd.md"; then
    printf '· AppleMD — Inhalt ist identisch; die Ausführung lässt sich daraus nicht erkennen.\n'
  fi
  mv "$COMPARE_WORK/applemd.md" "$applemd_file"
  printf '✓ AppleMD → %s.applemd.md (%d Bytes)\n' "$base" "$(wc -c < "$applemd_file")"
fi

echo
echo "Fertig. Dateien in: $CAPTURES_DIR/"
