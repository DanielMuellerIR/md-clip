#!/usr/bin/env bash
# install.sh darf fremde Ziele nicht mit ln -sf überschreiben.

set -euo pipefail

TESTS_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
PROJECT_ROOT="$(dirname "$TESTS_DIR")"
TEST_ROOT=$(mktemp -d)
trap 'rm -rf "$TEST_ROOT"' EXIT INT TERM

PROJECT_COPY="$TEST_ROOT/project"
FAKE_BIN="$TEST_ROOT/fake-bin"
mkdir -p "$PROJECT_COPY/bin" "$PROJECT_COPY/lib" "$PROJECT_COPY/helpers" "$FAKE_BIN"
cp "$PROJECT_ROOT/install.sh" "$PROJECT_COPY/install.sh"
cp "$PROJECT_ROOT/bin/md-clip" "$PROJECT_COPY/bin/md-clip"
cp "$PROJECT_ROOT/lib/pipeline.sh" "$PROJECT_COPY/lib/pipeline.sh"
cp "$PROJECT_ROOT/helpers/clipboard-html.swift" "$PROJECT_COPY/helpers/clipboard-html.swift"
cp "$PROJECT_ROOT/helpers/clipboard-rtf.swift" "$PROJECT_COPY/helpers/clipboard-rtf.swift"

cat > "$FAKE_BIN/uname" <<'SH'
#!/bin/sh
printf '%s\n' "${MD_CLIP_TEST_UNAME:-Darwin}"
SH
cat > "$FAKE_BIN/pandoc" <<'SH'
#!/bin/sh
case "${1:-}" in
  --version) echo 'pandoc 3.9.0.2' ;;
  --list-input-formats) printf 'html\nrtf\n' ;;
  *) exit 0 ;;
esac
SH
cat > "$FAKE_BIN/swiftc" <<'SH'
#!/bin/sh
output=""
while [ "$#" -gt 0 ]; do
  if [ "$1" = "-o" ]; then
    shift
    output="$1"
  fi
  shift
done
printf '#!/bin/sh\nexit 0\n' > "$output"
chmod +x "$output"
SH
cat > "$FAKE_BIN/xclip" <<'SH'
#!/bin/sh
exit 0
SH
cat > "$FAKE_BIN/wl-paste" <<'SH'
#!/bin/sh
exit 0
SH
cat > "$FAKE_BIN/wl-copy" <<'SH'
#!/bin/sh
exit 0
SH
chmod +x "$FAKE_BIN/"*
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
  local missing_tool="$1"
  local expected_message="$2"
  local case_root="$TEST_ROOT/linux-missing-$missing_tool"
  local case_bin="$case_root/bin"
  local prefix="$case_root/prefix"
  local output="$case_root/install.out"
  local available=()
  local tool

  mkdir -p "$prefix"
  printf 'unverändert\n' > "$prefix/sentinel"
  for tool in xclip wl-paste wl-copy; do
    [ "$tool" = "$missing_tool" ] || available+=("$tool")
  done
  prepare_linux_path "$case_bin" "${available[@]}"

  if (
    export PATH="$case_bin"
    MD_CLIP_TEST_UNAME=Linux run_install_with_output "$prefix" "$output"
  ); then
    echo "✗ install-linux akzeptiert fehlendes $missing_tool" >&2
    exit 1
  fi
  grep -Fq "$expected_message" "$output"
  [ ! -e "$prefix/md-clip" ]
  grep -Fxq 'unverändert' "$prefix/sentinel"
  echo "✓ install-linux lehnt fehlendes $missing_tool ab"
}

assert_linux_dependency_missing xclip 'xclip (X11-Sitzungen)'
assert_linux_dependency_missing wl-paste 'wl-clipboard (Wayland-Sitzungen; wl-paste + wl-copy)'
assert_linux_dependency_missing wl-copy 'wl-clipboard (Wayland-Sitzungen; wl-paste + wl-copy)'

LINUX_PREFIX="$TEST_ROOT/linux-complete/prefix"
LINUX_BIN="$TEST_ROOT/linux-complete/bin"
mkdir -p "$LINUX_PREFIX"
prepare_linux_path "$LINUX_BIN" xclip wl-paste wl-copy
(
  export PATH="$LINUX_BIN"
  MD_CLIP_TEST_UNAME=Linux run_install "$LINUX_PREFIX"
)
[ "$(readlink "$LINUX_PREFIX/md-clip")" = "$ABS_MAIN" ]
echo "✓ install-linux prüft X11- und beide Wayland-Werkzeuge"

# Toter Symlink und eigener Symlink dürfen idempotent repariert werden.
mkdir -p "$TEST_ROOT/dead"
ln -s "$TEST_ROOT/dead/missing" "$TEST_ROOT/dead/md-clip"
run_install "$TEST_ROOT/dead"
[ "$(readlink "$TEST_ROOT/dead/md-clip")" = "$ABS_MAIN" ]
run_install "$TEST_ROOT/dead"
[ "$(readlink "$TEST_ROOT/dead/md-clip")" = "$ABS_MAIN" ]
echo "✓ install-eigener-oder-toter-symlink wird sicher gesetzt"
