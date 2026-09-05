#!/usr/bin/env bash
# Vom Wrapper-Testrunner im isolierten Testverzeichnis geladen.
TEST_SCRIPT="${BASH_SOURCE[0]}"
# --- Bundle: Apple-Kette, Team-ID und Bundle-ID vor Produktcode. ---
TRUST_HELPER="$PROJECT_ROOT/wrappers/verify-bundle-trust.sh"
VERIFY_BUNDLE="$PROJECT_ROOT/wrappers/verify-bundle.sh"
TRUST_TEST_ROOT="$TEST_ROOT/bundle-trust"
mkdir -p "$TRUST_TEST_ROOT/App.app/Contents" "$TRUST_TEST_ROOT/fake-bin"
: > "$TRUST_TEST_ROOT/App.app/Contents/Info.plist"

cat > "$TRUST_TEST_ROOT/fake-bin/PlistBuddy" <<'SH'
#!/bin/sh
printf '%s\n' "$MD_CLIP_FAKE_BUNDLE_ID"
SH
cat > "$TRUST_TEST_ROOT/fake-bin/codesign" <<'SH'
#!/bin/sh
if [ "$1" = "--verify" ]; then
  printf '%s\n' "$@" > "$MD_CLIP_CODESIGN_CAPTURE"
  test_requirement=""
  while [ "$#" -gt 0 ]; do
    case "$1" in
      --test-requirement|-R)
        shift
        test_requirement="${1:-}"
        ;;
    esac
    shift
  done
  # Ohne den wertenden Schalter muss schon der Positivtest rot werden. Das
  # haette den wirkungslosen alten Aufruf mit --requirements erkannt.
  [ -n "$test_requirement" ] || exit 64
  required_identifier="identifier \"$MD_CLIP_FAKE_SIGNED_BUNDLE_ID\""
  required_team="certificate leaf[subject.OU] = \"$MD_CLIP_FAKE_TEAM_ID\""
  case "$test_requirement" in
    =*"$required_identifier"*"$required_team"*) exit 0 ;;
    *) exit 3 ;;
  esac
fi
printf 'details\n' >> "$MD_CLIP_CODESIGN_DETAIL_CAPTURE"
cat <<EOF
Executable=$1
Identifier=$MD_CLIP_FAKE_SIGNED_BUNDLE_ID
Format=app bundle with Mach-O thin
CodeDirectory v=20500 size=1 flags=0x10000(runtime)
Authority=Developer ID Application: Test ($MD_CLIP_FAKE_TEAM_ID)
TeamIdentifier=$MD_CLIP_FAKE_TEAM_ID
Timestamp=2026-08-10 00:00:00 +0000
EOF
SH
chmod +x "$TRUST_TEST_ROOT/fake-bin/"*

export MD_CLIP_CODESIGN_CAPTURE="$TRUST_TEST_ROOT/codesign-verify.args"
export MD_CLIP_CODESIGN_DETAIL_CAPTURE="$TRUST_TEST_ROOT/codesign-details.calls"
export MD_CLIP_FAKE_BUNDLE_ID="io.github.danielmuellerir.md-clip"
export MD_CLIP_FAKE_SIGNED_BUNDLE_ID="io.github.danielmuellerir.md-clip"
export MD_CLIP_FAKE_TEAM_ID="9QSWKSR4NQ"
# shellcheck source=../wrappers/verify-bundle-trust.sh
source "$TRUST_HELPER"
verify_signed_bundle_trust \
  "$TRUST_TEST_ROOT/App.app" \
  "$TRUST_TEST_ROOT/fake-bin/PlistBuddy" \
  "$TRUST_TEST_ROOT/fake-bin/codesign"
grep -Fxq -- '--test-requirement' "$MD_CLIP_CODESIGN_CAPTURE"
grep -Fxq '=anchor apple generic and identifier "io.github.danielmuellerir.md-clip" and certificate leaf[subject.OU] = "9QSWKSR4NQ" and certificate leaf[field.1.2.840.113635.100.6.1.13] exists and certificate 1[field.1.2.840.113635.100.6.2.6] exists' "$MD_CLIP_CODESIGN_CAPTURE"
if grep -Fxq -- '--requirements' "$MD_CLIP_CODESIGN_CAPTURE"; then
  echo "✗ Bundle-Vertrauen verwendet den wirkungslosen codesign-Schalter --requirements" >&2
  exit 1
fi

# Plist-ID ist korrekt, die simulierte Signatur trägt aber eine fremde ID:
# Die Requirement-Prüfung selbst muss mit Exit 3 abbrechen, bevor `codesign -d`
# als nachträglicher Texttest läuft.
: > "$MD_CLIP_CODESIGN_DETAIL_CAPTURE"
MD_CLIP_FAKE_SIGNED_BUNDLE_ID="invalid.example.fremd-signiert"
if verify_signed_bundle_trust \
  "$TRUST_TEST_ROOT/App.app" \
  "$TRUST_TEST_ROOT/fake-bin/PlistBuddy" \
  "$TRUST_TEST_ROOT/fake-bin/codesign" >/dev/null 2>&1; then
  echo "✗ Bundle-Requirement akzeptiert eine fremde signierte Kennung" >&2
  exit 1
fi
[ ! -s "$MD_CLIP_CODESIGN_DETAIL_CAPTURE" ]
echo "✓ Bundle-Requirement lehnt eine fremde signierte Kennung direkt ab"
MD_CLIP_FAKE_SIGNED_BUNDLE_ID="io.github.danielmuellerir.md-clip"

rm -f "$MD_CLIP_CODESIGN_CAPTURE"
MD_CLIP_FAKE_BUNDLE_ID="invalid.example.fremd"
if verify_signed_bundle_trust \
  "$TRUST_TEST_ROOT/App.app" \
  "$TRUST_TEST_ROOT/fake-bin/PlistBuddy" \
  "$TRUST_TEST_ROOT/fake-bin/codesign" >/dev/null 2>&1; then
  echo "✗ Bundle-Vertrauen akzeptiert eine fremde Bundle-ID" >&2
  exit 1
fi
[ ! -e "$MD_CLIP_CODESIGN_CAPTURE" ]

MD_CLIP_FAKE_BUNDLE_ID="io.github.danielmuellerir.md-clip"
MD_CLIP_FAKE_TEAM_ID="ANDERETEAM"
if verify_signed_bundle_trust \
  "$TRUST_TEST_ROOT/App.app" \
  "$TRUST_TEST_ROOT/fake-bin/PlistBuddy" \
  "$TRUST_TEST_ROOT/fake-bin/codesign" >/dev/null 2>&1; then
  echo "✗ Bundle-Vertrauen akzeptiert eine fremde Team-ID" >&2
  exit 1
fi

# Ein bewusst gesetztes APPLE_TEAM_ID muss bis in denselben Vertrauensanker
# gelangen. Sonst signiert der Release-Weg mit einer ID und prüft heimlich eine
# andere, fest eingebaute ID.
MD_CLIP_FAKE_TEAM_ID="TEAMID1234"
verify_signed_bundle_trust \
  "$TRUST_TEST_ROOT/App.app" \
  "$TRUST_TEST_ROOT/fake-bin/PlistBuddy" \
  "$TRUST_TEST_ROOT/fake-bin/codesign" \
  "TEAMID1234"
grep -Fq 'certificate leaf[subject.OU] = "TEAMID1234"' "$MD_CLIP_CODESIGN_CAPTURE"
grep -Fq -- '--team-id "$TEAM_ID"' "$PROJECT_ROOT/install-app.sh"
grep -Fq -- '--team-id "$TEAM_ID"' "$PROJECT_ROOT/wrappers/sign-and-release.sh"

TRUST_CALL_LINE=$(grep -n 'verify_signed_bundle_trust "\$APP"' "$VERIFY_BUNDLE" | cut -d: -f1)
PRODUCT_EXEC_LINE=$(grep -n 'CLI_OUTPUT="\$("\$BUNDLED_CLI" --version)"' "$VERIFY_BUNDLE" | cut -d: -f1)
if [ -z "$TRUST_CALL_LINE" ] || [ -z "$PRODUCT_EXEC_LINE" ] \
   || [ "$TRUST_CALL_LINE" -ge "$PRODUCT_EXEC_LINE" ]; then
  echo "✗ Bundle-Vertrauen steht nicht vor der Produktausführung" >&2
  exit 1
fi
echo "✓ Bundle wird vor Produktcode an Apple-Kette, Team-ID und Bundle-ID gebunden"

# Auch ein toter XPC-Symlink ist unerlaubter Bundle-Inhalt. `-e` allein folgt
# dem Ziel und würde ihn übersehen; der minimale Bundle-Aufbau muss bereits an
# der Strukturprüfung scheitern, bevor otool oder Produktcode laufen.
XPC_TEST_APP="$TEST_ROOT/dead-xpc/md-clip.app"
mkdir -p \
  "$XPC_TEST_APP/Contents/MacOS" \
  "$XPC_TEST_APP/Contents/Resources/bin" \
  "$XPC_TEST_APP/Contents/Resources/Licenses" \
  "$XPC_TEST_APP/Contents/Frameworks/Sparkle.framework/Versions/B/Updater.app"
: > "$XPC_TEST_APP/Contents/Info.plist"
for executable in \
  "$XPC_TEST_APP/Contents/MacOS/md-clip" \
  "$XPC_TEST_APP/Contents/MacOS/md-clip-updater" \
  "$XPC_TEST_APP/Contents/MacOS/md-clip-hud" \
  "$XPC_TEST_APP/Contents/Resources/bin/md-clip" \
  "$XPC_TEST_APP/Contents/Resources/bin/pipeline.sh" \
  "$XPC_TEST_APP/Contents/Resources/bin/tidy-markdown.pl" \
  "$XPC_TEST_APP/Contents/Resources/bin/tables.lua" \
  "$XPC_TEST_APP/Contents/Resources/bin/pandoc" \
  "$XPC_TEST_APP/Contents/Resources/bin/clipboard-html" \
  "$XPC_TEST_APP/Contents/Resources/bin/clipboard-rtf" \
  "$XPC_TEST_APP/Contents/Frameworks/Sparkle.framework/Versions/B/Autoupdate"; do
  : > "$executable"
  chmod +x "$executable"
done
for resource in tidy-markdown.pl tables.lua; do
  printf 'resource\n' > "$XPC_TEST_APP/Contents/Resources/bin/$resource"
done
for license in pandoc-COPYRIGHT.txt Sparkle-LICENSE.txt README.txt; do
  printf 'Lizenz\n' > "$XPC_TEST_APP/Contents/Resources/Licenses/$license"
done
for resource in tidy-markdown.pl tables.lua; do
  : > "$XPC_TEST_APP/Contents/Resources/bin/$resource"
  if bash "$VERIFY_BUNDLE" "$XPC_TEST_APP" > "$TEST_ROOT/resource.out" 2> "$TEST_ROOT/resource.err"; then
    echo "Leere Pipeline-Ressource akzeptiert: $resource" >&2; exit 1
  fi
  grep -Fq "Pipeline-Ressource fehlt oder ist leer: $resource" "$TEST_ROOT/resource.err"
  printf 'resource\n' > "$XPC_TEST_APP/Contents/Resources/bin/$resource"
done
echo "✓ Bundle-Prüfer lehnt leere Pipeline-Ressourcen ab"
ln -s "$TEST_ROOT/nicht-vorhanden" \
  "$XPC_TEST_APP/Contents/Frameworks/Sparkle.framework/Versions/B/XPCServices"
if bash "$VERIFY_BUNDLE" "$XPC_TEST_APP" \
  >"$TEST_ROOT/dead-xpc.out" 2>"$TEST_ROOT/dead-xpc.err"; then
  echo "✗ Bundle-Prüfer akzeptiert einen toten XPCServices-Symlink" >&2
  exit 1
fi
grep -Fq 'Sparkles XPC-Dienste sind noch im Bundle' "$TEST_ROOT/dead-xpc.err"

grep -Fq 'verify_distribution_signature "$APP/Contents/Resources/bin/clipboard-html" "HTML-Helfer"' "$VERIFY_BUNDLE"
grep -Fq 'verify_distribution_signature "$APP/Contents/Resources/bin/clipboard-rtf" "RTF-Helfer"' "$VERIFY_BUNDLE"
echo "✓ Bundle-Prüfer erfasst tote XPC-Symlinks und beide Clipboard-Helfer"

# --- Bundle: Info.plist darf keine ältere Kompatibilität versprechen als Code. ---
# Der echte Prüfer liest sowohl LC_BUILD_VERSION/minos als auch die ältere
# LC_VERSION_MIN_MACOSX/version-Form aus vtool. Der isolierte Test führt den
# vollständigen markierten Produktionsblock aus und zeichnet jedes Ziel auf;
# dadurch fällt auch ein künftig aus der Schleife entferntes Binary auf.
APP="$TRUST_TEST_ROOT/compatibility/md-clip.app"
UPDATER="$APP/Contents/MacOS/md-clip-updater"
SPARKLE_FRAMEWORK="$APP/Contents/Frameworks/Sparkle.framework"
MINIMUM_SYSTEM_VERSION=14.0
MD_CLIP_VTOOL_CAPTURE="$TRUST_TEST_ROOT/vtool-targets"
MD_CLIP_FAKE_MINOS=14.0
export MD_CLIP_VTOOL_CAPTURE MD_CLIP_FAKE_MINOS

cat > "$TRUST_TEST_ROOT/fake-bin/vtool" <<'SH'
#!/bin/sh
printf '%s\n' "${2:-}" >> "$MD_CLIP_VTOOL_CAPTURE"
case "${MD_CLIP_FAKE_VTOOL_STYLE:-modern}" in
  modern)
    printf '      cmd LC_BUILD_VERSION\n    minos %s\n' "$MD_CLIP_FAKE_MINOS"
    ;;
  legacy)
    printf '      cmd LC_VERSION_MIN_MACOSX\n  version %s\n' "$MD_CLIP_FAKE_MINOS"
    ;;
  missing)
    printf 'kein Load Command\n'
    ;;
esac
SH
chmod +x "$TRUST_TEST_ROOT/fake-bin/vtool"
PATH="$TRUST_TEST_ROOT/fake-bin:$PATH"
export PATH

COMPATIBILITY_CHECK="$TEST_ROOT/macos-compatibility-check.sh"
extract_shell_block "$VERIFY_BUNDLE" MACOS_COMPATIBILITY_CHECK "$COMPATIBILITY_CHECK"
# shellcheck source=/dev/null
source "$COMPATIBILITY_CHECK"

EXPECTED_VTOOL_TARGETS="$TRUST_TEST_ROOT/expected-vtool-targets"
printf '%s\n' \
  "$UPDATER" \
  "$APP/Contents/MacOS/md-clip-hud" \
  "$APP/Contents/Resources/bin/clipboard-html" \
  "$APP/Contents/Resources/bin/clipboard-rtf" \
  "$APP/Contents/Resources/bin/pandoc" \
  "$SPARKLE_FRAMEWORK/Versions/B/Sparkle" \
  "$SPARKLE_FRAMEWORK/Versions/B/Autoupdate" \
  "$SPARKLE_FRAMEWORK/Versions/B/Updater.app/Contents/MacOS/Updater" \
  > "$EXPECTED_VTOOL_TARGETS"
if ! cmp -s "$EXPECTED_VTOOL_TARGETS" "$MD_CLIP_VTOOL_CAPTURE"; then
  echo "✗ Bundle-Kompatibilitätsprüfung erreicht nicht alle Mach-O-Ziele" >&2
  diff "$EXPECTED_VTOOL_TARGETS" "$MD_CLIP_VTOOL_CAPTURE" >&2 || true
  exit 1
fi

MD_CLIP_FAKE_VTOOL_STYLE=modern MD_CLIP_FAKE_MINOS=14.0 \
  verify_macos_compatibility 14.0 "Test-Binary" "$TRUST_TEST_ROOT/dummy"
MD_CLIP_FAKE_VTOOL_STYLE=legacy MD_CLIP_FAKE_MINOS=10.13 \
  verify_macos_compatibility 14.0 "Test-Binary" "$TRUST_TEST_ROOT/dummy"
if MD_CLIP_FAKE_VTOOL_STYLE=modern MD_CLIP_FAKE_MINOS=14.1 \
  verify_macos_compatibility 14.0 "Test-Binary" "$TRUST_TEST_ROOT/dummy" >/dev/null 2>&1; then
  echo "✗ Bundle-Prüfer akzeptiert ein Binary oberhalb von LSMinimumSystemVersion" >&2
  exit 1
fi
if MD_CLIP_FAKE_VTOOL_STYLE=missing MD_CLIP_FAKE_MINOS=14.0 \
  verify_macos_compatibility 14.0 "Test-Binary" "$TRUST_TEST_ROOT/dummy" >/dev/null 2>&1; then
  echo "✗ Bundle-Prüfer akzeptiert ein Binary ohne lesbare Mindestversion" >&2
  exit 1
fi
echo "✓ Bundle-Kompatibilität deckt Info.plist und alle Mach-O-Ziele"

# --- Lokaler Build: nur die gerade gebaute, bytegleiche CLI ausführen. ---
BUILD_SCRIPT="$PROJECT_ROOT/build.sh"
BUILD_CLI_SMOKE="$TEST_ROOT/build-cli-smoke.sh"
extract_shell_block "$BUILD_SCRIPT" TRUSTED_BUILD_CLI_SMOKE "$BUILD_CLI_SMOKE"
# shellcheck source=/dev/null
source "$BUILD_CLI_SMOKE"

SMOKE_SOURCE="$TEST_ROOT/smoke-source"
SMOKE_BUNDLE="$TEST_ROOT/smoke-bundle"
printf '%s\n' '#!/bin/sh' 'echo "md-clip 1.2.4"' > "$SMOKE_SOURCE"
cp "$SMOKE_SOURCE" "$SMOKE_BUNDLE"
chmod +x "$SMOKE_SOURCE" "$SMOKE_BUNDLE"
verify_trusted_build_cli "$SMOKE_SOURCE" "$SMOKE_BUNDLE" 1.2.4

SMOKE_EXECUTED="$TEST_ROOT/smoke-executed"
export SMOKE_EXECUTED
printf '%s\n' '#!/bin/sh' 'printf ausgeführt > "$SMOKE_EXECUTED"' 'echo "fremd"' > "$SMOKE_BUNDLE"
if verify_trusted_build_cli "$SMOKE_SOURCE" "$SMOKE_BUNDLE" 1.2.4 >/dev/null 2>&1; then
  echo "✗ Build-Smoke-Test führt eine nicht zur Quelle passende CLI aus" >&2
  exit 1
fi
[ ! -e "$SMOKE_EXECUTED" ]

printf '%s\n' '#!/bin/sh' 'if then' > "$SMOKE_SOURCE"
cp "$SMOKE_SOURCE" "$SMOKE_BUNDLE"
chmod +x "$SMOKE_SOURCE" "$SMOKE_BUNDLE"
if verify_trusted_build_cli "$SMOKE_SOURCE" "$SMOKE_BUNDLE" 1.2.4 >/dev/null 2>&1; then
  echo "✗ Build-Smoke-Test akzeptiert einen Syntaxfehler" >&2
  exit 1
fi

printf '%s\n' '#!/bin/sh' 'exit 7' > "$SMOKE_SOURCE"
cp "$SMOKE_SOURCE" "$SMOKE_BUNDLE"
chmod +x "$SMOKE_SOURCE" "$SMOKE_BUNDLE"
if verify_trusted_build_cli "$SMOKE_SOURCE" "$SMOKE_BUNDLE" 1.2.4 >/dev/null 2>&1; then
  echo "✗ Build-Smoke-Test übersieht eine nicht ausführbare CLI" >&2
  exit 1
fi
echo "✓ Lokaler Build bindet die CLI an die Quelle und führt --version aus"
