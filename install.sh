#!/usr/bin/env bash
# install.sh — Setup für md-clip auf macOS.
#
# Was passiert hier:
#   1. Swift-Helper aus helpers/clipboard-html.swift kompilieren.
#   2. Prüfen, dass pandoc verfügbar ist (sonst Hinweis auf brew install).
#   3. Symlink von bin/md-clip nach /usr/local/bin/md-clip anlegen.
#
# Idempotent: kann mehrfach aufgerufen werden, baut den Helper bei Bedarf neu
# und überschreibt einen veralteten Symlink.

set -euo pipefail

# Projekt-Root ist das Verzeichnis, in dem dieses Skript liegt.
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
cd "$SCRIPT_DIR"

# Pfade im Projekt.
MAIN_SCRIPT="bin/md-clip"

# Beide Swift-Helper als (Source, Binary)-Paare. Die Schleife unten
# kompiliert jedes Paar, falls die Source neuer ist als das Binary.
HELPERS=(
  "helpers/clipboard-html.swift:helpers/clipboard-html"
  "helpers/clipboard-rtf.swift:helpers/clipboard-rtf"
)

# Default-Installationsziel. Kann per Env-Variable überschrieben werden,
# z.B. INSTALL_PREFIX=~/.local/bin ./install.sh
INSTALL_PREFIX="${INSTALL_PREFIX:-/usr/local/bin}"
INSTALL_TARGET="$INSTALL_PREFIX/md-clip"

echo "==> md-clip installieren"
echo "    Projekt: $SCRIPT_DIR"
echo "    Ziel:    $INSTALL_TARGET"
echo

# --- 1. Dependency-Check: pandoc ---
if ! command -v pandoc >/dev/null 2>&1; then
  echo "FEHLER: pandoc nicht gefunden."
  echo "       Installation: brew install pandoc"
  exit 2
fi
echo "✓ pandoc gefunden: $(pandoc --version | head -1)"

# --- 2. Swift-Helper kompilieren ---
# swiftc kommt mit den Xcode CommandLineTools (xcode-select --install).
# Wenn kein swiftc da ist, geben wir einen klaren Hinweis.
if ! command -v swiftc >/dev/null 2>&1; then
  echo "FEHLER: swiftc nicht gefunden."
  echo "       Installation: xcode-select --install"
  exit 2
fi

# Alle Helper durchgehen. Format pro Eintrag: "source:binary".
# `[ A -nt B ]` testet: ist A neuer als B?
for entry in "${HELPERS[@]}"; do
  src="${entry%%:*}"   # alles vor dem Doppelpunkt
  bin="${entry##*:}"   # alles nach dem Doppelpunkt
  if [ ! -x "$bin" ] || [ "$src" -nt "$bin" ]; then
    echo "==> Kompiliere $src → $bin"
    swiftc "$src" -o "$bin"
    chmod +x "$bin"
  else
    echo "✓ Helper-Binary ist aktuell: $bin"
  fi
done

# --- 3. Hauptskript ausführbar machen ---
chmod +x "$MAIN_SCRIPT"

# --- 4. Symlink anlegen ---
# Wenn das Ziel-Verzeichnis nicht existiert oder nicht beschreibbar ist,
# fragen wir den Nutzer nach sudo.
if [ ! -d "$INSTALL_PREFIX" ]; then
  echo "FEHLER: Verzeichnis existiert nicht: $INSTALL_PREFIX"
  echo "       Anlegen oder INSTALL_PREFIX setzen."
  exit 2
fi

# Absoluten Pfad zum Hauptskript bilden — der Symlink soll auch funktionieren,
# wenn das Verzeichnis später aus einem anderen Pfad heraus aufgerufen wird.
ABS_MAIN="$SCRIPT_DIR/$MAIN_SCRIPT"

# Prüfen, ob wir Schreibrechte auf das Ziel-Verzeichnis haben.
# `-w` testet auf Schreibbarkeit aus Sicht des aktuellen Prozesses.
if [ -w "$INSTALL_PREFIX" ]; then
  ln -sf "$ABS_MAIN" "$INSTALL_TARGET"
else
  echo "==> $INSTALL_PREFIX braucht sudo zum Schreiben"
  sudo ln -sf "$ABS_MAIN" "$INSTALL_TARGET"
fi

echo "✓ Symlink: $INSTALL_TARGET → $ABS_MAIN"
echo
echo "Fertig. Test:"
echo "  echo '<p>Hallo <b>Welt</b></p>' | pbcopy && md-clip"
