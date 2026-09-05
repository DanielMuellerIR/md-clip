#!/usr/bin/env bash
# Isolierter Compositor: niemals die Zwischenablage einer laufenden Sitzung.
set -euo pipefail
[ "$(id -u)" -ne 0 ] || { echo 'Wayland-Test als unprivilegierter Benutzer starten.' >&2; exit 2; }
[ -z "${WAYLAND_DISPLAY:-}" ] || { echo 'Wayland-Test benötigt eine Umgebung ohne laufende Wayland-Sitzung.' >&2; exit 2; }
for tool in sway wl-copy wl-paste; do command -v "$tool" >/dev/null; done
ROOT=$(cd "$(dirname "$0")/.." && pwd)
RUNTIME=$(mktemp -d)
SWAY_PID=""
cleanup() {
  if [ -n "$SWAY_PID" ]; then kill "$SWAY_PID" 2>/dev/null || true; wait "$SWAY_PID" 2>/dev/null || true; fi
  rm -rf "$RUNTIME"
}
trap cleanup EXIT
trap 'exit 130' INT
trap 'exit 143' TERM
export XDG_RUNTIME_DIR="$RUNTIME"
export WLR_BACKENDS=headless WLR_LIBINPUT_NO_DEVICES=1 WLR_RENDERER=pixman
unset DISPLAY
printf 'output * resolution 800x600\n' > "$RUNTIME/config"
sway --unsupported-gpu -c "$RUNTIME/config" > "$RUNTIME/sway.log" 2>&1 &
SWAY_PID=$!
ready=0
for ((i=0; i<100; i++)); do
  for socket in "$RUNTIME"/wayland-*; do
    if [ -S "$socket" ]; then export WAYLAND_DISPLAY="${socket##*/}"; ready=1; break; fi
  done
  [ "$ready" -eq 0 ] || break
  kill -0 "$SWAY_PID" 2>/dev/null || { cat "$RUNTIME/sway.log" >&2; exit 1; }
  sleep 0.1
done
[ "$ready" -eq 1 ] || { cat "$RUNTIME/sway.log" >&2; exit 1; }
MD_CLIP_SKIP_CLIPBOARD=0 bash "$ROOT/tests/run-tests.sh"
