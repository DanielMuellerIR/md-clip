#!/usr/bin/env bash
# Nur den geprüften Bundle-Konverter bereitstellen; kein App-Build/Signing.
set -euo pipefail
[ "$#" -eq 1 ] && [ -n "$1" ] || { echo 'Aufruf: prepare-bundled-pandoc.sh ZIELVERZEICHNIS' >&2; exit 2; }
[ "$(uname -s)" = Darwin ] && [ "$(uname -m)" = arm64 ] || {
  echo 'Das Bundle-pandoc benötigt macOS arm64.' >&2; exit 2;
}
for tool in curl unzip; do
  command -v "$tool" >/dev/null 2>&1 || { echo "Testbereitstellung benötigt $tool." >&2; exit 2; }
done
TESTS_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=../wrappers/pandoc-pin.sh
source "$TESTS_DIR/../wrappers/pandoc-pin.sh"
# shellcheck source=../wrappers/verified-cache.sh
source "$TESTS_DIR/../wrappers/verified-cache.sh"
mkdir -p "$1"
DESTINATION="$(cd "$1" && pwd -P)"
if [ -L "$DESTINATION/pandoc" ] || [ -d "$DESTINATION/pandoc" ]; then
  echo 'Ziel pandoc ist ein fremder Link oder ein Verzeichnis.' >&2; exit 2
fi
STAGE=$(mktemp -d "$DESTINATION/.extract.XXXXXX")
trap 'rm -rf "$STAGE"' EXIT
trap 'exit 130' INT
trap 'exit 143' TERM
ARCHIVE="$DESTINATION/pandoc-${PANDOC_VERSION}-arm64-macOS.zip"
URL="https://github.com/jgm/pandoc/releases/download/${PANDOC_VERSION}/pandoc-${PANDOC_VERSION}-arm64-macOS.zip"
download_verified "$URL" "$PANDOC_ZIP_SHA256" "$ARCHIVE"
MEMBER="pandoc-${PANDOC_VERSION}-arm64/bin/pandoc"
unzip -q "$ARCHIVE" "$MEMBER" -d "$STAGE"
BINARY="$STAGE/$MEMBER"
chmod +x "$BINARY"
verify_pandoc_version "$BINARY" "$PANDOC_VERSION" || { echo 'Falsche pandoc-Version im verifizierten Archiv.' >&2; exit 1; }
# Erst nach Archiv- und Versionsprüfung ein vorhandenes Testergebnis ersetzen.
mv -f "$BINARY" "$DESTINATION/pandoc"
printf 'Bundle-pandoc %s bereit: %s/pandoc\n' "$PANDOC_VERSION" "$DESTINATION"
