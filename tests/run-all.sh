#!/usr/bin/env bash
# Gemeinsamer Einstieg für lokale Prüfungen und CI.
set -euo pipefail

cd "$(dirname "${BASH_SOURCE[0]}")/.."
TEST_PYTHON="${TEST_PYTHON:-python3}"
export TEST_PYTHON
export PYTHONDONTWRITEBYTECODE=1

case "${1:-}" in
  --x11)
    [ "$#" -eq 1 ] && [ "$(uname -s)" = Linux ] || exit 2
    # Ein eigener X-Server schützt das Clipboard der angemeldeten Sitzung.
    # Im Container --init verwenden, damit xvfb-run sein Bereitschaftssignal erhält.
    xvfb-run -a env -u WAYLAND_DISPLAY MD_CLIP_SKIP_CLIPBOARD=0 bash tests/run-tests.sh
    xvfb-run -a env -u WAYLAND_DISPLAY MD_CLIP_UNDO_TEST_ISOLATED=1 \
      "$TEST_PYTHON" tests/test-undo-linux.py --integration
    status=0
    xvfb-run -a env -u WAYLAND_DISPLAY ./bin/md-clip --quiet || status=$?
    [ "$status" -eq 1 ] || { echo "Leeres X11-Clipboard: erwartet Exit 1, erhalten $status." >&2; exit 1; }
    ;;
  --wayland)
    [ "$#" -eq 1 ] && [ "$(uname -s)" = Linux ] || exit 2
    env -u WAYLAND_DISPLAY bash tests/run-wayland.sh
    ;;
  --bundle)
    [ "$#" -eq 2 ] && [ "$(uname -s)" = Darwin ] || exit 2
    bash wrappers/verify-bundle.sh "$2"
    "$TEST_PYTHON" tests/test-bundle-conversion.py "$2"
    ;;
  --lint)
    [ "$#" -eq 1 ] || exit 2
    for file in bin/md-clip ./*.sh lib/*.sh wrappers/*.sh tests/*.sh tests/lib/*.sh tests/wrappers/*.sh; do
      bash -n "$file"
    done
    shellcheck -x -S error -P SCRIPTDIR bin/md-clip ./*.sh lib/*.sh wrappers/*.sh tests/run-all.sh
    for file in lib/*.pl; do perl -cw "$file"; done
    luac -p lib/pandoc-filter.lua
    actionlint -shellcheck= .github/workflows/*.yml
    ;;
  --help|-h)
    printf '%s\n' 'tests/run-all.sh [--x11 | --wayland | --bundle APP | --lint]'
    ;;
  "")
    [ "$#" -eq 0 ] || exit 2
    MD_CLIP_SKIP_CLIPBOARD=1 bash tests/run-tests.sh
    for suite in plain-newlines install-safety dependencies wrapper-safety review-content; do
      bash "tests/test-$suite.sh"
    done
    for suite in cli-inputs compare html-normalization conversion-report images tables-text doctor pandoc-pin app-actions; do
      "$TEST_PYTHON" "tests/test-$suite.py"
    done
    case "$(uname -s)" in
      Linux) "$TEST_PYTHON" tests/test-undo-linux.py ;;
      Darwin)
        "$TEST_PYTHON" tests/test-undo-macos.py
        "$TEST_PYTHON" tests/test-preview-macos.py
        ;;
    esac
    ;;
  *) echo "Unbekannter Testmodus: $1 (siehe --help)." >&2; exit 2 ;;
esac
