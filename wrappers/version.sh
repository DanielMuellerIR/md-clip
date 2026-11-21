#!/usr/bin/env bash
# Der erste VERSION-Eintrag am Zeilenanfang ist maßgeblich. Der
# Appcast-Workflow benutzt dieselbe Grammatik für die Release-Daten.
md_clip_version() {
  local source_file="$1"
  local version

  version="$(awk -F'"' '/^VERSION=/{print $2; exit}' "$source_file")" || return 1
  [ -n "$version" ] || return 1
  printf '%s\n' "$version"
}
