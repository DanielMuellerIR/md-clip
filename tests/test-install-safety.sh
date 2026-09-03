#!/usr/bin/env bash
# install.sh darf fremde Ziele nicht mit ln -sf überschreiben.

set -euo pipefail

TESTS_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=lib/test-helpers.sh
source "$TESTS_DIR/lib/test-helpers.sh"
init_test_environment "$TESTS_DIR"

PROJECT_COPY="$TEST_ROOT/project"
FAKE_BIN="$TEST_ROOT/fake-bin"
copy_install_test_project "$PROJECT_COPY"
write_install_platform_mocks "$FAKE_BIN"
export PATH="$FAKE_BIN:/usr/bin:/bin"

run_install() {
  local prefix="$1"
  INSTALL_PREFIX="$prefix" "$PROJECT_COPY/install.sh" >/dev/null 2>&1
}

run_install_with_output() {
  local prefix="$1"
  local output="$2"
  INSTALL_PREFIX="$prefix" "$PROJECT_COPY/install.sh" >"$output" 2>&1
}

ABS_MAIN="$PROJECT_COPY/bin/md-clip"

# Reguläre Datei: Fehler und Byteinhalt bleibt erhalten.
mkdir -p "$TEST_ROOT/regular"
printf 'fremd\n' > "$TEST_ROOT/regular/md-clip"
if run_install "$TEST_ROOT/regular"; then
  echo "✗ install-regular wurde überschrieben" >&2
  exit 1
fi
grep -Fxq 'fremd' "$TEST_ROOT/regular/md-clip"
echo "✓ install-regular bleibt erhalten"

# Verzeichnis: Fehler und Inhalt bleibt erhalten.
mkdir -p "$TEST_ROOT/directory/md-clip"
printf 'marker\n' > "$TEST_ROOT/directory/md-clip/marker"
if run_install "$TEST_ROOT/directory"; then
  echo "✗ install-directory wurde überschrieben" >&2
  exit 1
fi
grep -Fxq 'marker' "$TEST_ROOT/directory/md-clip/marker"
echo "✓ install-directory bleibt erhalten"

# Lebender fremder Symlink: Fehler, Linkziel unverändert.
mkdir -p "$TEST_ROOT/foreign"
printf 'fremd\n' > "$TEST_ROOT/foreign/other"
ln -s "$TEST_ROOT/foreign/other" "$TEST_ROOT/foreign/md-clip"
if run_install "$TEST_ROOT/foreign"; then
  echo "✗ install-foreign-symlink wurde überschrieben" >&2
  exit 1
fi
[ "$(readlink "$TEST_ROOT/foreign/md-clip")" = "$TEST_ROOT/foreign/other" ]
echo "✓ install-foreign-symlink bleibt erhalten"

# Lebender Symlink in md-clip.app: weiterhin nicht überschreiben, aber als
# gültige App-Installation erklären statt irreführend „fremd“ zu melden.
APP_CLI="$TEST_ROOT/app/md-clip.app/Contents/Resources/bin/md-clip"
APP_OUTPUT="$TEST_ROOT/app-install.out"
mkdir -p "$(dirname "$APP_CLI")" "$TEST_ROOT/app-prefix"
printf '#!/bin/sh\nexit 0\n' > "$APP_CLI"
chmod +x "$APP_CLI"
ln -s "$APP_CLI" "$TEST_ROOT/app-prefix/md-clip"
if run_install_with_output "$TEST_ROOT/app-prefix" "$APP_OUTPUT"; then
  echo "✗ install-app-symlink wurde als Git-Installation übernommen" >&2
  exit 1
fi
[ "$(readlink "$TEST_ROOT/app-prefix/md-clip")" = "$APP_CLI" ]
grep -Fq 'md-clip ist bereits über die installierte App eingerichtet' "$APP_OUTPUT"
grep -Fq './install.sh ist nur für die CLI direkt aus diesem Git-Clone gedacht' "$APP_OUTPUT"
grep -Fq 'md-clip --check-updates' "$APP_OUTPUT"
if grep -Fq 'pandoc gefunden' "$APP_OUTPUT"; then
  echo "✗ App-Hinweis kommt erst nach unnötigen Abhängigkeitsprüfungen" >&2
  exit 1
fi
echo "✓ install-app-symlink wird verständlich als App-Installation erklärt"

# Für die Linux-Fälle reicht ein Attrappen-Verzeichnis vor dem System-PATH
# nicht: Auf einem CI-Runner könnte das vermeintlich fehlende Werkzeug unter
# /usr/bin liegen. Jeder Fall erhält deshalb einen abgeschlossenen PATH mit nur
# den ausdrücklich zugelassenen Programmen.
prepare_linux_path() {
  local destination="$1"
  shift
  local tool source

  mkdir -p "$destination"
  for tool in bash chmod dirname grep head ln perl; do
    source=$(command -v "$tool")
    ln -s "$source" "$destination/$tool"
  done
  ln -s "$FAKE_BIN/uname" "$destination/uname"
  ln -s "$FAKE_BIN/pandoc" "$destination/pandoc"
  for tool in "$@"; do
    ln -s "$FAKE_BIN/$tool" "$destination/$tool"
  done
}

assert_linux_dependency_missing() {
  local name="$1"
  local wayland="$2"
  local expected_message="$3"
  shift 3
  local case_root="$TEST_ROOT/linux-missing-$name"
  local case_bin="$case_root/bin"
  local prefix="$case_root/prefix"
  local output="$case_root/install.out"

  mkdir -p "$prefix"
  printf 'unverändert\n' > "$prefix/sentinel"
  prepare_linux_path "$case_bin" "$@"

  if (
    export PATH="$case_bin"
    MD_CLIP_TEST_UNAME=Linux WAYLAND_DISPLAY="$wayland" \
      run_install_with_output "$prefix" "$output"
  ); then
    echo "✗ install-linux akzeptiert fehlendes Backend-Werkzeug ($name)" >&2
    exit 1
  fi
  grep -Fq "$expected_message" "$output"
  [ ! -e "$prefix/md-clip" ]
  grep -Fxq 'unverändert' "$prefix/sentinel"
  echo "✓ install-linux lehnt fehlendes Backend-Werkzeug ab ($name)"
}

assert_linux_dependency_missing x11 "" 'xclip (X11-Sitzung)' wl-paste wl-copy
assert_linux_dependency_missing wayland-paste wayland-test \
  'wl-clipboard (Wayland-Sitzung; wl-paste + wl-copy)' xclip wl-copy
assert_linux_dependency_missing wayland-copy wayland-test \
  'wl-clipboard (Wayland-Sitzung; wl-paste + wl-copy)' xclip wl-paste

assert_linux_backend_succeeds() {
  local name="$1"
  local wayland="$2"
  shift 2
  local case_root="$TEST_ROOT/linux-success-$name"
  local case_bin="$case_root/bin"
  local prefix="$case_root/prefix"

  mkdir -p "$prefix"
  prepare_linux_path "$case_bin" "$@"
  (
    export PATH="$case_bin"
    MD_CLIP_TEST_UNAME=Linux WAYLAND_DISPLAY="$wayland" run_install "$prefix"
  )
  [ "$(readlink "$prefix/md-clip")" = "$ABS_MAIN" ]
  printf '✓ install-linux braucht nur %s\n' "$name"
}

assert_linux_backend_succeeds X11 "" xclip
assert_linux_backend_succeeds Wayland wayland-test wl-paste wl-copy

# Fehlende Präfixe: innerhalb von HOME anlegen, außerhalb fail-closed und
# mit einem konkreten vorbereitenden Befehl erklären.
HOME_ROOT="$TEST_ROOT/home"
HOME_PREFIX="$HOME_ROOT/.local/bin"
mkdir -p "$HOME_ROOT"
HOME="$HOME_ROOT" run_install "$HOME_PREFIX"
[ -d "$HOME_PREFIX" ]
[ "$(readlink "$HOME_PREFIX/md-clip")" = "$ABS_MAIN" ]
echo "✓ install-prefix legt fehlendes Verzeichnis im Home an"

OUTSIDE_PREFIX="$TEST_ROOT/outside/missing/bin"
OUTSIDE_OUTPUT="$TEST_ROOT/outside-prefix.out"
if HOME="$HOME_ROOT" run_install_with_output "$OUTSIDE_PREFIX" "$OUTSIDE_OUTPUT"; then
  echo "✗ install-prefix legt Verzeichnis außerhalb des Homes an" >&2
  exit 1
fi
[ ! -e "$OUTSIDE_PREFIX" ]
grep -Fq "sudo mkdir -p \"$OUTSIDE_PREFIX\"" "$OUTSIDE_OUTPUT"
echo "✓ install-prefix lehnt fehlendes Verzeichnis außerhalb des Homes ab"

# Toter Symlink und eigener Symlink dürfen idempotent repariert werden.
mkdir -p "$TEST_ROOT/dead"
ln -s "$TEST_ROOT/dead/missing" "$TEST_ROOT/dead/md-clip"
run_install "$TEST_ROOT/dead"
[ "$(readlink "$TEST_ROOT/dead/md-clip")" = "$ABS_MAIN" ]
run_install "$TEST_ROOT/dead"
[ "$(readlink "$TEST_ROOT/dead/md-clip")" = "$ABS_MAIN" ]
echo "✓ install-eigener-oder-toter-symlink wird sicher gesetzt"

# Zwischen der Prüfung des Ziels und dem Verlinken liegt ein Moment, in dem dort
# etwas Fremdes entstehen kann — bei /usr/local/bin läuft der Befehl zudem als
# root. `ln -sf` würde das ungefragt ersetzen. Diese Rennbedingung lässt sich
# nicht auslösen, der Befehlsvertrag dagegen schon prüfen; dieselbe Regel hält
# tests/test-wrapper-safety.sh für den Launcher fest.
# Kommentarzeilen vorher weg: Die Begründung im Skript nennt `ln -sf` beim
# Namen und würde sonst den eigenen Vertrag verletzen.
if grep -v '^[[:space:]]*#' "$PROJECT_COPY/install.sh" \
  | grep -Eq 'ln[[:space:]]+-sf|ln[[:space:]]+-fs'; then
  echo "✗ install.sh verlinkt mit -f und ersetzt damit ein fremdes Ziel" >&2
  exit 1
fi
grep -Fq 'ln -s "$ABS_MAIN" "$INSTALL_TARGET"' "$PROJECT_COPY/install.sh"
echo "✓ install-verlinkt-nie-mit-f"
