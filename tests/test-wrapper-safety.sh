#!/usr/bin/env bash
# Sicherheitsregressionen für Launcher, Release, Appcast und Bundle-Prüfung.

set -euo pipefail

TESTS_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=lib/test-helpers.sh
source "$TESTS_DIR/lib/test-helpers.sh"
init_test_environment "$TESTS_DIR"

# --- Die Diagnose des Harness selbst. ---
# Fast sechzig Zusicherungen in dieser Datei sind stumme `grep -Fq`-Verträge:
# Schlägt einer fehl, beendet `set -e` den Lauf, ohne etwas zu sagen. Erst der
# ERR-Trap aus lib/test-helpers.sh nennt Datei, Zeile und Wortlaut. Faellt er
# aus, sieht man wieder nur einen nackten Exit-Code — deshalb wird er hier als
# Erstes geprüft.
REPORT_PROBE="$TEST_ROOT/report-probe.sh"
cat > "$REPORT_PROBE" <<'SH'
#!/usr/bin/env bash
set -euo pipefail
source "$1/lib/test-helpers.sh"
init_test_environment "$1"
false
SH
chmod +x "$REPORT_PROBE"
set +e
"$REPORT_PROBE" "$TESTS_DIR" \
  > "$TEST_ROOT/report-probe.out" 2> "$TEST_ROOT/report-probe.err"
REPORT_PROBE_STATUS=$?
set -e
if [ "$REPORT_PROBE_STATUS" -eq 0 ]; then
  echo "✗ Eine gescheiterte Zusicherung beendet den Testlauf nicht" >&2
  exit 1
fi
if ! grep -Fq 'report-probe.sh:5 fehlgeschlagen' "$TEST_ROOT/report-probe.err" \
  || ! grep -Fxq '    false' "$TEST_ROOT/report-probe.err"; then
  echo "✗ Gescheiterte Zusicherungen nennen nicht mehr Datei, Zeile und Wortlaut" >&2
  cat "$TEST_ROOT/report-probe.err" >&2
  exit 1
fi
echo "✓ Gescheiterte Zusicherungen nennen Datei, Zeile und Wortlaut"

# Gemeinsame Attrappen und Funktionen bleiben in derselben isolierten Shell.
# Die Reihenfolge erhält den bestehenden Vertrag der Prüfabschnitte.
for suite in launcher release helpers appcast bundle; do
  source "$TESTS_DIR/wrappers/$suite.sh"
done
