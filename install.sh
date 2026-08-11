#!/usr/bin/env bash
# install.sh — CLI direkt aus diesem Git-Clone einrichten (macOS und Linux).
#
# Was passiert hier:
#   1. Prüfen, dass die Abhängigkeiten da sind (plattformabhängig).
#   2. Nur macOS: Swift-Helper aus helpers/clipboard-*.swift kompilieren.
#      Auf Linux übernimmt xclip/wl-clipboard deren Job — nichts zu bauen.
#   3. Symlink auf bin/md-clip anlegen (macOS: /usr/local/bin,
#      Linux: ~/.local/bin — dort braucht es kein sudo).
#
# Idempotent: kann mehrfach aufgerufen werden, baut den Helper bei Bedarf neu
# und überschreibt einen veralteten Symlink.

set -euo pipefail

# Projekt-Root ist das Verzeichnis, in dem dieses Skript liegt.
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
cd "$SCRIPT_DIR"

# Derselbe Fähigkeitscheck wie im Produkt, ohne Versionsstrings zu raten.
# shellcheck source=lib/pipeline.sh
source "$SCRIPT_DIR/lib/pipeline.sh"

# Pfade im Projekt.
MAIN_SCRIPT="bin/md-clip"

# Beide Swift-Helper als (Source, Binary)-Paare. Die Schleife unten
# kompiliert jedes Paar, falls die Source neuer ist als das Binary.
HELPERS=(
  "helpers/clipboard-html.swift:helpers/clipboard-html"
  "helpers/clipboard-rtf.swift:helpers/clipboard-rtf"
)

# --- Plattform erkennen (spiegelt bin/md-clip) ---
case "$(uname -s)" in
  Darwin) PLATFORM="macos" ;;
  Linux)  PLATFORM="linux" ;;
  *)
    echo "FEHLER: Nicht unterstützte Plattform: $(uname -s)"
    echo "       md-clip läuft auf macOS und Linux."
    exit 2
    ;;
esac

# Default-Installationsziel. Kann per Env-Variable überschrieben werden,
# z.B. INSTALL_PREFIX=~/bin ./install.sh
#
# Unterschiedliche Defaults pro Plattform: Auf macOS ist /usr/local/bin der
# eingebürgerte Ort für Handinstalliertes (und via Homebrew meist schon dem
# Nutzer überschrieben). Auf Linux gehört /usr/local/bin root, jede
# Installation bräuchte also sudo — ~/.local/bin ist dort der vom
# XDG-Standard vorgesehene Nutzer-Ort und liegt bei den meisten
# Distributionen schon im PATH.
if [ "$PLATFORM" = "macos" ]; then
  INSTALL_PREFIX="${INSTALL_PREFIX:-/usr/local/bin}"
else
  INSTALL_PREFIX="${INSTALL_PREFIX:-$HOME/.local/bin}"
fi
INSTALL_TARGET="$INSTALL_PREFIX/md-clip"
ABS_MAIN="$SCRIPT_DIR/$MAIN_SCRIPT"

# Vor allen Abhängigkeitsprüfungen erklären, wenn die CLI bereits über die App
# eingerichtet ist. App-Nutzer brauchen weder System-pandoc noch Swift-Helper;
# ein später Fehler dazu würde den eigentlichen Sachverhalt verschleiern.
check_install_target() {
  if [ -L "$INSTALL_TARGET" ]; then
    CURRENT_TARGET=$(readlink "$INSTALL_TARGET")
    if [ "$CURRENT_TARGET" != "$ABS_MAIN" ] && [ -e "$INSTALL_TARGET" ]; then
      case "$CURRENT_TARGET" in
        */md-clip.app/Contents/Resources/bin/md-clip)
          echo "ABBRUCH: md-clip ist bereits über die installierte App eingerichtet:"
          echo "         $INSTALL_TARGET → $CURRENT_TARGET"
          echo
          echo "         ./install.sh ist nur für die CLI direkt aus diesem Git-Clone gedacht"
          echo "         und wird für die App oder Sparkle-Updates nicht benötigt."
          echo
          echo "         App jetzt manuell auf Updates prüfen:"
          echo "           md-clip --check-updates"
          echo
          echo "         Ziel bleibt unverändert."
          ;;
        *)
          echo "FEHLER: Der Befehl md-clip gehört bereits zu einer anderen Installation:"
          echo "        $INSTALL_TARGET → $CURRENT_TARGET"
          echo "        Ziel bleibt unverändert."
          ;;
      esac
      exit 2
    fi
  elif [ -e "$INSTALL_TARGET" ]; then
    echo "FEHLER: Installationsziel ist bereits eine Datei oder ein Verzeichnis:"
    echo "        $INSTALL_TARGET"
    echo "        Ziel bleibt unverändert."
    exit 2
  fi
}

echo "==> md-clip-CLI direkt aus dem Git-Clone installieren"
echo "    Projekt:   $SCRIPT_DIR"
echo "    Plattform: $PLATFORM"
echo "    Ziel:      $INSTALL_TARGET"
echo "    App:       wird von diesem Skript nicht installiert"
echo

check_install_target

# --- 1. Dependency-Check ---
# Sammelt ALLE fehlenden Pakete und meldet sie in einem Rutsch. Wer drei
# Sachen nicht installiert hat, soll nicht dreimal hintereinander scheitern.
missing=()
command -v pandoc >/dev/null 2>&1 || missing+=("pandoc")
command -v perl   >/dev/null 2>&1 || missing+=("perl")

if [ "$PLATFORM" = "linux" ]; then
  # Beide Clipboard-Werkzeuge empfehlen, nicht nur das der aktuellen Sitzung:
  # Beim Wechsel zwischen X11- und Wayland-Sitzung (Login-Bildschirm) soll
  # md-clip weiter laufen, ohne dass man nachinstallieren muss.
  command -v xclip    >/dev/null 2>&1 || missing+=("xclip (X11-Sitzungen)")
  command -v wl-paste >/dev/null 2>&1 || missing+=("wl-clipboard (Wayland-Sitzungen)")
fi

if [ "${#missing[@]}" -gt 0 ]; then
  echo "FEHLER: Fehlende Abhängigkeiten: ${missing[*]}"
  echo
  if [ "$PLATFORM" = "macos" ]; then
    echo "       Installation: brew install pandoc"
  else
    echo "       Installation (Debian/Ubuntu/Mint):"
    echo "         sudo apt install pandoc xclip wl-clipboard libnotify-bin"
    echo "       Installation (Fedora):"
    echo "         sudo dnf install pandoc xclip wl-clipboard libnotify"
    echo "       Installation (Arch):"
    echo "         sudo pacman -S pandoc xclip wl-clipboard libnotify"
  fi
  exit 2
fi

if [ "$PLATFORM" = "linux" ] && ! pandoc_supports_rtf; then
  echo "FEHLER: Das installierte pandoc unterstützt das Eingabeformat RTF nicht."
  echo "        Bitte pandoc >= 2.14.2 installieren; die Paketversion von"
  echo "        Ubuntu 22.04 ist dafür zu alt."
  exit 2
fi
echo "✓ pandoc gefunden: $(pandoc --version | head -1)"

# --- 2. Swift-Helper kompilieren (nur macOS) ---
# Auf Linux gibt es kein NSPasteboard und damit nichts zu bauen — das
# Clipboard liest dort xclip bzw. wl-paste.
if [ "$PLATFORM" = "macos" ]; then
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
else
  echo "✓ Keine Helper zu bauen (Linux nutzt xclip/wl-clipboard)"
fi

# --- 3. Hauptskript ausführbar machen ---
chmod +x "$MAIN_SCRIPT"

# --- 4. Symlink sicher anlegen ---
if [ ! -d "$INSTALL_PREFIX" ]; then
  # Ein fehlendes Verzeichnis IM EIGENEN HOME legen wir einfach an: Das ist
  # der Normalfall auf Linux (~/.local/bin existiert auf einem frischen
  # System oft noch nicht) und braucht weder sudo noch eine Rückfrage.
  # Außerhalb des Homes bleiben wir vorsichtig und fragen nicht ungefragt
  # nach sudo, um irgendwo im System ein Verzeichnis anzulegen.
  case "$INSTALL_PREFIX" in
    "$HOME"/*)
      echo "==> Lege $INSTALL_PREFIX an"
      mkdir -p "$INSTALL_PREFIX"
      ;;
    *)
      echo "FEHLER: Verzeichnis existiert nicht: $INSTALL_PREFIX"
      echo "       Anlegen oder INSTALL_PREFIX setzen."
      exit 2
      ;;
  esac
fi

# Reguläre Dateien, Verzeichnisse und lebende fremde Symlinks gehören dem
# Nutzer. Ersetzen dürfen wir nur unseren eigenen Symlink oder einen
# nachweislich toten Symlink.
check_install_target

# Prüfen, ob wir Schreibrechte auf das Ziel-Verzeichnis haben.
# `-w` testet auf Schreibbarkeit aus Sicht des aktuellen Prozesses.
if [ -w "$INSTALL_PREFIX" ]; then
  ln -sf "$ABS_MAIN" "$INSTALL_TARGET"
else
  echo "==> $INSTALL_PREFIX braucht sudo zum Schreiben"
  sudo ln -sf "$ABS_MAIN" "$INSTALL_TARGET"
fi

echo "✓ Symlink: $INSTALL_TARGET → $ABS_MAIN"

# Ein Symlink, den der PATH nicht findet, sieht aus wie eine kaputte
# Installation („command not found"). Lieber hier einmal deutlich sagen.
# Die :-Rahmen um beide Seiten verhindern Teiltreffer (/usr/local/bin
# soll nicht in /usr/local/binaries „gefunden" werden).
case ":$PATH:" in
  *":$INSTALL_PREFIX:"*) ;;
  *)
    echo
    echo "HINWEIS: $INSTALL_PREFIX liegt nicht in deinem PATH."
    echo "         Ergänze in ~/.bashrc bzw. ~/.zshrc:"
    echo "           export PATH=\"$INSTALL_PREFIX:\$PATH\""
    ;;
esac

echo
echo "Fertig. Test:"
if [ "$PLATFORM" = "macos" ]; then
  echo "  echo '<p>Hallo <b>Welt</b></p>' | pbcopy && md-clip"
elif [ -n "${WAYLAND_DISPLAY:-}" ]; then
  echo "  echo '<p>Hallo <b>Welt</b></p>' | wl-copy --type text/html && md-clip"
else
  echo "  echo '<p>Hallo <b>Welt</b></p>' | xclip -selection clipboard -t text/html && md-clip"
fi
