#!/usr/bin/env bash
# Die Produktversion steht an genau einer Stelle: als VERSION="…" in
# bin/md-clip. Gelesen wird sie an sechs Stellen — Build, Bundle-Bau,
# Bundle-Prüfung, App-Installation, Release und Appcast-Workflow. Bis zum
# 2026-09-03 stand dort zweimal dieselbe Aufgabe in zwei Schreibweisen
# (`awk -F'"'` und `grep | head | cut`); wer die Zeile in bin/md-clip anfasst,
# müsste sonst sechs Stellen im Kopf haben.
#
# Diese Datei wird nur gesourct und hat keine Seiteneffekte.

# md_clip_version <datei>: Gibt den VERSION-Wert der übergebenen md-clip-Datei
# auf stdout aus.
#
# Rückgabe 1 und keine Ausgabe, wenn dort keine Zeile `VERSION="…"` mit einem
# nicht leeren Wert steht. Der Aufrufer entscheidet, ob das ein Abbruch ist und
# mit welchem Code — die Einstiegspunkte melden das unterschiedlich.
#
# Nur die ERSTE Zeile zählt, und nur am Zeilenanfang: Das Wort VERSION taucht
# in Kommentaren und Meldungen auch anderswo auf.
md_clip_version() {
  local source_file="$1"
  local version

  version="$(awk -F'"' '/^VERSION=/{print $2; exit}' "$source_file")" || return 1
  [ -n "$version" ] || return 1
  printf '%s\n' "$version"
}
