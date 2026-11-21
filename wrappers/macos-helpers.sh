#!/usr/bin/env bash
# Swift-Sprachmodus und Quelldateien der ausgelieferten Helfer.

# Auch das gebündelte Pandoc setzt mindestens macOS 14.0 voraus.
MACOS_MINIMUM=14.0
MACOS_SWIFT_FLAGS=(-swift-version 6 -strict-concurrency=complete -warnings-as-errors)

compile_macos_helper() {
  local helper="$1" output="$2" target="$3"
  shift 3
  local sources=("helpers/$helper.swift")
  case "$helper" in
    clipboard-undo|md-clip-preview) sources+=("helpers/$helper-main.swift") ;;
    md-clip-updater) sources+=(helpers/md-clip-updater-mode.swift) ;;
  esac
  swiftc -target "$target-apple-macos$MACOS_MINIMUM" "${MACOS_SWIFT_FLAGS[@]}" \
    "${sources[@]}" -o "$output" "$@"
}
