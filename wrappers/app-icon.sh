#!/usr/bin/env bash
# Kopiert das App-Icon an den in Info.plist referenzierten Ort.

copy_app_icon() {
  cp "$1" "$2/Contents/Resources/md-clip.icns" || return
  echo "✓ Icon mitgeliefert"
}
