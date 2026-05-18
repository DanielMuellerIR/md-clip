#!/usr/bin/env bash
# tests/compare-manual.sh — Halbautomatischer Apple-vs-md-clip-Vergleich.
#
# Workflow:
#   1. Du kopierst Source-Inhalt aufs Clipboard (formatierter Text).
#   2. Du startest dieses Skript.
#   3. Das Skript sichert HTML / RTF / md-clip-Output und PAUSIERT.
#   4. Du löst AppleMD aus (Hotkey oder Klick in Kurzbefehle.app).
#      AppleMD MUSS als letzte Aktion „In Zwischenablage kopieren"
#      haben, sonst können wir das Apple-Resultat nicht abgreifen.
#   5. Du drückst Enter. Das Skript liest den neuen Clipboard-Inhalt
#      und speichert ihn als <name>.applemd.md.
#
# Hintergrund: `shortcuts run` aus der Kommandozeile kommt nicht
# zuverlässig ans Clipboard. Ein GUI-Aufruf von AppleMD klappt.
# Daher der halbautomatische Weg.

# Genau dasselbe wie compare.sh, plus Manual-AppleMD-Capture.
# Statt zu duplizieren rufen wir compare.sh mit gesetzter Env-Variable auf.
exec env CAPTURE_APPLEMD_MANUAL=1 bash "$(dirname "${BASH_SOURCE[0]}")/compare.sh"
