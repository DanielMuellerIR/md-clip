#!/usr/bin/env bash
# Vom Wrapper-Testrunner im isolierten Testverzeichnis geladen.
TEST_SCRIPT="${BASH_SOURCE[0]}"
# --- Appcast: Tooling und Release-Tag bleiben getrennte Vertrauenszonen. ---
APPCAST_REQUEST_WORKFLOW="$PROJECT_ROOT/.github/workflows/request-appcast.yml"
grep -Fq 'workflow_run:' "$APPCAST_WORKFLOW"
grep -Fq "github.ref_name == github.event.repository.default_branch" "$APPCAST_WORKFLOW"
grep -Fq 'release:' "$APPCAST_REQUEST_WORKFLOW"
grep -Fq 'types: [released]' "$APPCAST_REQUEST_WORKFLOW"
grep -Fq 'permissions:' "$APPCAST_REQUEST_WORKFLOW"
grep -Fq 'contents: read' "$APPCAST_REQUEST_WORKFLOW"
if grep -Fq 'types: [published]' "$APPCAST_REQUEST_WORKFLOW" \
   || grep -Fq 'github.event.release.prerelease' "$APPCAST_REQUEST_WORKFLOW"; then
  echo "✗ Release-Dispatcher kann weiterhin bei einem Prerelease erfolgreich laufen" >&2
  exit 1
fi
if grep -Eq 'SPARKLE_PRIVATE_KEY|environment:|pages: write|id-token: write' "$APPCAST_REQUEST_WORKFLOW"; then
  echo "✗ Unprivilegierter Release-Dispatcher besitzt Secret- oder Deployment-Zugriff" >&2
  exit 1
fi
if grep -Fq 'release:' "$APPCAST_WORKFLOW"; then
  echo "✗ Privilegierter Appcast-Workflow wird weiterhin aus dem Release-Tag geladen" >&2
  exit 1
fi
TOOLING_SHA="92bbe437f0a45e38f132614436c58d65ff014717"
grep -Fq "ref: $TOOLING_SHA" "$APPCAST_WORKFLOW"
grep -Fq "!= \"$TOOLING_SHA\"" "$APPCAST_WORKFLOW"
if grep -Fq 'TOOLING_REVISION' "$APPCAST_WORKFLOW"; then
  echo "✗ Tooling-SHA bleibt über die Umgebung überschreibbar" >&2
  exit 1
fi
if grep -Fq 'APPCAST_WORK: ${{ runner.temp }}' "$APPCAST_WORKFLOW"; then
  echo "✗ runner.temp steht im jobweiten env und macht den Workflow ungültig" >&2
  exit 1
fi
grep -Fq 'APPCAST_WORK=$RUNNER_TEMP/md-clip-appcast' "$APPCAST_WORKFLOW"
grep -Fq 'path: ${{ runner.temp }}/md-clip-appcast/site' "$APPCAST_WORKFLOW"
if [ "$(grep -Fc -- '-R "$GITHUB_REPOSITORY"' "$APPCAST_WORKFLOW")" -ne 3 ]; then
  echo "✗ Release-Abfragen sind nicht alle explizit an das Repository gebunden" >&2
  exit 1
fi

# Die Tag-Auswahl läuft mit einer gh-Attrappe und darf genau eine validierte
# Zeile aus der API an GITHUB_ENV übergeben.
APPCAST_HELPER="$PROJECT_ROOT/wrappers/appcast.sh"
# shellcheck source=../../wrappers/appcast.sh
source "$APPCAST_HELPER"

TAG_FAKE_BIN="$TEST_ROOT/tag-fake-bin"
mkdir -p "$TAG_FAKE_BIN"
cat > "$TAG_FAKE_BIN/gh" <<'SH'
#!/bin/sh
printf '%s\n' "$MD_CLIP_FAKE_LATEST_TAG"
SH
chmod +x "$TAG_FAKE_BIN/gh"
PATH="$TAG_FAKE_BIN:$PATH"
export PATH
export GITHUB_REPOSITORY="DanielMuellerIR/md-clip"
export GITHUB_ENV="$TEST_ROOT/github-env"
export MD_CLIP_FAKE_LATEST_TAG="v1.2.2"

: > "$GITHUB_ENV"
GITHUB_EVENT_NAME="workflow_dispatch"
export GITHUB_EVENT_NAME
select_release_tag "v1.2.2"
[ "$(cat "$GITHUB_ENV")" = "RELEASE_TAG=v1.2.2" ]

expect_tag_rejected_without_env() {
  local label="$1"
  local requested_tag="$2"
  : > "$GITHUB_ENV"
  if select_release_tag "$requested_tag" \
    >"$TEST_ROOT/tag-${label}.out" 2>"$TEST_ROOT/tag-${label}.err"; then
    echo "✗ Release-Tag-Auswahl akzeptiert $label" >&2
    exit 1
  fi
  if [ -s "$GITHUB_ENV" ]; then
    echo "✗ Release-Tag-Auswahl schreibt vor der Ablehnung von $label in GITHUB_ENV" >&2
    exit 1
  fi
}

expect_tag_rejected_without_env \
  "Tooling-Newline-Injection" \
  $'v1.2.2\nTOOLING_REVISION=refs/tags/angreifer'
expect_tag_rejected_without_env \
  "Release-Tag-Newline-Injection" \
  $'v1.2.2\nRELEASE_TAG=v9.9.9'
expect_tag_rejected_without_env "ungueltiges Tagformat" "refs/tags/v1.2.2"
expect_tag_rejected_without_env "altes stabiles Tag" "v1.2.1"

GITHUB_EVENT_NAME="workflow_run"
export GITHUB_EVENT_NAME
MD_CLIP_FAKE_LATEST_TAG=$'v1.2.2\nTOOLING_REVISION=refs/tags/angreifer'
export MD_CLIP_FAKE_LATEST_TAG
expect_tag_rejected_without_env "mehrzeiliges API-Tag" ""
MD_CLIP_FAKE_LATEST_TAG="v1.2.2"
export MD_CLIP_FAKE_LATEST_TAG
: > "$GITHUB_ENV"
select_release_tag ""
[ "$(cat "$GITHUB_ENV")" = "RELEASE_TAG=v1.2.2" ]
echo "✓ Release-Tag-Auswahl blockiert Newline-Überschreibungen vor GITHUB_ENV"

workflow_step_line() {
  local name="$1"
  local matches count
  matches=$(grep -nF -- "- name: $name" "$APPCAST_WORKFLOW" || true)
  count=$(printf '%s\n' "$matches" | awk 'NF { count++ } END { print count + 0 }')
  if [ "$count" -ne 1 ]; then
    echo "✗ Appcast-Workflow braucht genau einen Schritt '$name' (gefunden: $count)" >&2
    return 1
  fi
  printf '%s\n' "$matches" | head -1 | cut -d: -f1
}
TAG_SELECTION_LINE=$(workflow_step_line 'Select current stable release')
TOOLING_CHECKOUT_LINE=$(workflow_step_line 'Check out trusted appcast tooling')
RELEASE_CHECKOUT_LINE=$(workflow_step_line 'Check out release data')
SECRET_STEP_LINE=$(workflow_step_line 'Generate and verify signed appcast')
if [ -z "$TOOLING_CHECKOUT_LINE" ] || [ -z "$RELEASE_CHECKOUT_LINE" ] || [ -z "$SECRET_STEP_LINE" ] \
   || [ "$TOOLING_CHECKOUT_LINE" -ge "$TAG_SELECTION_LINE" ] \
   || [ "$TAG_SELECTION_LINE" -ge "$RELEASE_CHECKOUT_LINE" ] \
   || [ "$RELEASE_CHECKOUT_LINE" -ge "$SECRET_STEP_LINE" ]; then
  echo "✗ Appcast-Workflow trennt Tooling, Release-Daten und Secret nicht in dieser Reihenfolge" >&2
  exit 1
fi

FETCH_BLOCK=$(sed -n '/- name: Fetch pinned Sparkle tool without secret/,/- name: Generate and verify signed appcast/p' "$APPCAST_WORKFLOW")
grep -Fq 'tooling/wrappers/build-app-bundled.sh' <<<"$FETCH_BLOCK"
grep -Fq 'source tooling/wrappers/verified-cache.sh' <<<"$FETCH_BLOCK"
grep -Fq 'swiftc tooling/helpers/verify-sparkle-signature.swift' <<<"$FETCH_BLOCK"
if grep -Eq 'release-source/(wrappers|\.github)|source release-source' <<<"$FETCH_BLOCK"; then
  echo "✗ Appcast-Tooling stammt weiterhin aus dem Release-Tag" >&2
  exit 1
fi

SIGNING_BLOCK=$(sed -n '/- name: Generate and verify signed appcast/,/- name: Upload Pages artifact/p' "$APPCAST_WORKFLOW")
grep -Fq 'source tooling/wrappers/appcast.sh' <<<"$SIGNING_BLOCK"
grep -Fq '"$APPCAST_WORK/sparkle-dist/bin/generate_appcast"' <<<"$SIGNING_BLOCK"
if grep -Fq 'release-source/wrappers' <<<"$SIGNING_BLOCK"; then
  echo "✗ Signierschritt führt ein Werkzeug aus dem Release-Tag aus" >&2
  exit 1
fi
echo "✓ Appcast-Tooling kommt fest gepinnt aus einer vom Release-Tag getrennten Revision"

# Der echte Generator-Runner muss stdout und stderr vollständig abwarten. Eine
# Sparkle-Warnung darf auch dann nicht entkommen, wenn sie verspätet auf stdout
# erscheint und der Generator selbst mit Erfolg endet.
sparkle_private_key="synthetic-test-key"
cat > "$TEST_ROOT/generator-warning" <<'SH'
#!/bin/sh
cat >/dev/null
sleep 0.1
echo 'does not match key EdDSA'
exit 0
SH
cat > "$TEST_ROOT/generator-ok" <<'SH'
#!/bin/sh
cat >/dev/null
echo 'generated'
SH
chmod +x "$TEST_ROOT/generator-warning" "$TEST_ROOT/generator-ok"
if run_appcast_generator "$TEST_ROOT/generator-warning" >/dev/null 2>&1; then
  echo "✗ Generator-Runner übersieht eine verzögerte Schlüsselwarnung auf stdout" >&2
  exit 1
fi
run_appcast_generator "$TEST_ROOT/generator-ok" >/dev/null 2>&1
echo "✓ Appcast wartet auf stdout und stderr des Generators und prüft beide"

# Prüfe beide Versionsfelder am Item. Wenn xmllint verfügbar ist, werden
# dieselben XPath-Ausdrücke zusätzlich gegen ein echtes XML ausgeführt.
grep -Fq 'local version_xpath="${item_xpath}/*[local-name()=\"version\"]"' "$APPCAST_HELPER"
grep -Fq 'local short_version_xpath="${item_xpath}/*[local-name()=\"shortVersionString\"]"' "$APPCAST_HELPER"
if command -v xmllint >/dev/null 2>&1; then
  APPCAST_REAL="$TEST_ROOT/appcast-real.xml"
  cat > "$APPCAST_REAL" <<'XML'
<rss xmlns:sparkle="http://www.andymatuschak.org/xml-namespaces/sparkle" version="2.0">
  <channel>
    <item>
      <sparkle:version>1.2.2</sparkle:version>
      <sparkle:shortVersionString>1.2.2</sparkle:shortVersionString>
      <enclosure url="https://github.com/DanielMuellerIR/md-clip/releases/download/v1.2.2/md-clip-1.2.2.dmg" sparkle:edSignature="synthetic-signature"/>
    </item>
  </channel>
</rss>
XML
  validate_appcast \
    "$APPCAST_REAL" \
    1.2.2 \
    1.2.2 \
    "https://github.com/DanielMuellerIR/md-clip/releases/download/v1.2.2/md-clip-1.2.2.dmg"
else
  echo "⚠ Reale Appcast-XPath-Prüfung übersprungen: xmllint fehlt auf $(uname -s)." >&2
fi

APPCAST_FAKE_BIN="$TEST_ROOT/appcast-fake-bin"
mkdir -p "$APPCAST_FAKE_BIN"
cat > "$APPCAST_FAKE_BIN/xmllint" <<'SH'
#!/bin/sh
if [ "$1" = "--noout" ]; then
  [ "${MD_CLIP_XML_VALID:-1}" = "1" ]
  exit
fi
expression="$2"
case "$expression" in
  'count('*'local-name()="item"'*'local-name()="enclosure"'*) printf '%s' "$MD_CLIP_XML_ENCLOSURES" ;;
  'count('*'local-name()="item"'*) printf '%s' "$MD_CLIP_XML_ITEMS" ;;
  *'local-name()="edSignature"'*) printf '%s' "$MD_CLIP_XML_SIGNATURE" ;;
  *'local-name()="shortVersionString"'*) printf '%s' "$MD_CLIP_XML_SHORT_VERSION" ;;
  *'local-name()="version"'*) printf '%s' "$MD_CLIP_XML_VERSION" ;;
  *'/@url)'*) printf '%s' "$MD_CLIP_XML_URL" ;;
  *) echo "unbekannter XPath: $expression" >&2; exit 64 ;;
esac
SH
chmod +x "$APPCAST_FAKE_BIN/xmllint"
PATH="$APPCAST_FAKE_BIN:$PATH"
export PATH

APPCAST_DUMMY="$TEST_ROOT/appcast.xml"
EXPECTED_APPCAST_URL="https://github.com/DanielMuellerIR/md-clip/releases/download/v1.2.2/md-clip-1.2.2.dmg"
: > "$APPCAST_DUMMY"
export MD_CLIP_XML_VALID=1
export MD_CLIP_XML_ITEMS=1
export MD_CLIP_XML_ENCLOSURES=1
export MD_CLIP_XML_VERSION=1.2.2
export MD_CLIP_XML_SHORT_VERSION=1.2.2
export MD_CLIP_XML_URL="$EXPECTED_APPCAST_URL"
export MD_CLIP_XML_SIGNATURE="synthetic-signature"
validate_appcast "$APPCAST_DUMMY" 1.2.2 1.2.2 "$EXPECTED_APPCAST_URL"

expect_appcast_rejected() {
  local label="$1"
  if validate_appcast "$APPCAST_DUMMY" 1.2.2 1.2.2 "$EXPECTED_APPCAST_URL" \
    >"$TEST_ROOT/appcast-${label}.out" 2>"$TEST_ROOT/appcast-${label}.err"; then
    echo "✗ Appcast-Validator akzeptiert $label" >&2
    exit 1
  fi
}

MD_CLIP_XML_ITEMS=2
expect_appcast_rejected "mehrere Einträge"
MD_CLIP_XML_ITEMS=1
MD_CLIP_XML_ENCLOSURES=2
expect_appcast_rejected "mehrere Enclosures"
MD_CLIP_XML_ENCLOSURES=1
MD_CLIP_XML_VERSION=1.2.1
expect_appcast_rejected "falsche Build-Version"
MD_CLIP_XML_VERSION=1.2.2
MD_CLIP_XML_SHORT_VERSION=1.2.1
expect_appcast_rejected "falsche Kurzversion"
MD_CLIP_XML_SHORT_VERSION=1.2.2
MD_CLIP_XML_URL="https://invalid.example/md-clip-1.2.2.dmg"
expect_appcast_rejected "falsche Enclosure-URL"
MD_CLIP_XML_URL="$EXPECTED_APPCAST_URL"
MD_CLIP_XML_SIGNATURE=""
expect_appcast_rejected "fehlende EdDSA-Signatur"
MD_CLIP_XML_SIGNATURE="synthetic-signature"
echo "✓ Appcast verlangt genau einen passenden, signierten Release-Eintrag"

grep -Fq "does not match key EdDSA" "$APPCAST_HELPER"
grep -Fq "SPARKLE_PRIVATE_KEY passt nicht zum öffentlichen Schlüssel" "$APPCAST_HELPER"
grep -Fq -- "-c 'Print :SUPublicEDKey'" <<<"$SIGNING_BLOCK"
grep -Fq '"$APPCAST_WORK/verify-sparkle-signature"' <<<"$SIGNING_BLOCK"
grep -Fq '"$public_key" "$feed_signature" "${dmgs[0]}"' <<<"$SIGNING_BLOCK"
echo "✓ Appcast prüft die Signatur gegen den Schlüssel im Release-Bundle"
