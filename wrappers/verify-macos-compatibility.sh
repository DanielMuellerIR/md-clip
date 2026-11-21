#!/usr/bin/env bash
# Prüft die macOS-Mindestversion aller ausgelieferten Mach-O-Dateien.

macos_version_at_most() {
  local actual="$1"
  local declared="$2"

  awk -v actual="$actual" -v declared="$declared" '
    BEGIN {
      actual_count = split(actual, actual_parts, ".")
      declared_count = split(declared, declared_parts, ".")
      for (i = 1; i <= 3; i++) {
        actual_part = (i <= actual_count ? actual_parts[i] : 0) + 0
        declared_part = (i <= declared_count ? declared_parts[i] : 0) + 0
        if (actual_part < declared_part) exit 0
        if (actual_part > declared_part) exit 1
      }
      exit 0
    }
  '
}

macho_minimum_versions() {
  local binary="$1"

  # Universal-Binaries besitzen je Architektur einen Load Command. Bei alten
  # SDKs heißt das Feld `version` unter LC_VERSION_MIN_MACOSX, bei neuen
  # `minos` unter LC_BUILD_VERSION; beide Formen werden vollständig gelesen.
  vtool -show-build "$binary" | awk '
    /cmd LC_VERSION_MIN_MACOSX/ { legacy = 1; next }
    legacy && $1 == "version" { print $2; legacy = 0; next }
    $1 == "minos" { print $2 }
  '
}

verify_macos_compatibility() {
  local declared="$1"
  local label="$2"
  local binary="$3"
  local minimums minimum

  if ! [[ "$declared" =~ ^[0-9]+\.[0-9]+(\.[0-9]+)?$ ]]; then
    echo "Ungültige LSMinimumSystemVersion: ${declared:-<leer>}." >&2
    return 65
  fi
  if ! minimums="$(macho_minimum_versions "$binary")" || [ -z "$minimums" ]; then
    echo "macOS-Mindestversion fehlt oder ist nicht lesbar: $label." >&2
    return 65
  fi

  while IFS= read -r minimum; do
    if ! [[ "$minimum" =~ ^[0-9]+\.[0-9]+(\.[0-9]+)?$ ]]; then
      echo "Ungültige macOS-Mindestversion in $label: $minimum." >&2
      return 65
    fi
    if ! macos_version_at_most "$minimum" "$declared"; then
      echo "$label benötigt macOS $minimum, Info.plist verspricht aber $declared." >&2
      return 65
    fi
  done <<< "$minimums"
}

verify_all_macos_compatibility() {
  local declared="$1"
  local labels=(
    "Updater-Helfer"
    "HUD-Helfer"
    "Vorschau-Helfer"
    "HTML-Helper"
    "RTF-Helper"
    "Undo-Helper"
    "pandoc"
    "Sparkle-Framework"
    "Sparkle-Autoupdate"
    "Sparkle-Updater"
  )
  local binaries=(
    "$UPDATER"
    "$APP/Contents/MacOS/md-clip-hud"
    "$APP/Contents/MacOS/md-clip-preview"
    "$APP/Contents/Resources/bin/clipboard-html"
    "$APP/Contents/Resources/bin/clipboard-rtf"
    "$APP/Contents/Resources/bin/clipboard-undo"
    "$APP/Contents/Resources/bin/pandoc"
    "$SPARKLE_FRAMEWORK/Versions/B/Sparkle"
    "$SPARKLE_FRAMEWORK/Versions/B/Autoupdate"
    "$SPARKLE_FRAMEWORK/Versions/B/Updater.app/Contents/MacOS/Updater"
  )
  local index

  for index in "${!labels[@]}"; do
    verify_macos_compatibility \
      "$declared" "${labels[$index]}" "${binaries[$index]}"
  done
}
