#!/usr/bin/env bash
# Gemeinsame Developer-ID- und Notarisierungsfunktionen für install-app.sh und
# sign-and-release.sh. Die aufrufenden Skripte besitzen ihre Ablauflogik und
# Traps; dieser Baustein hält Profilprüfung, Signaturidentität und App-Ticket in
# genau einer Implementierung.

NOTARY_APP_ZIP_DIR=""

# Developer-ID-Vorgaben für beide Einstiegspunkte. install-app.sh und
# sign-and-release.sh signieren dasselbe Bundle und müssen deshalb dieselbe
# Team-ID und dieselbe Identität benutzen; zweimal hingeschrieben signiert der
# eine Weg irgendwann mit einem anderen Zertifikat als der andere. Über
# APPLE_TEAM_ID und CODESIGN_IDENTITY bleibt beides für einen anderen Account
# oder eine CI überschreibbar. Setzt TEAM_ID und IDENTITY.
resolve_signing_identity() {
  TEAM_ID="${APPLE_TEAM_ID:-9QSWKSR4NQ}"
  IDENTITY="${CODESIGN_IDENTITY:-Developer ID Application: Daniel Mueller ($TEAM_ID)}"
}

resolve_notary_profile() {
  local project_root="$1"

  NOTARY_PROFILE="${NOTARY_PROFILE:-}"
  if [ -z "$NOTARY_PROFILE" ]; then
    NOTARY_PROFILE="$(git -C "$project_root" config --local --get mdClip.notaryProfile 2>/dev/null || true)"
  fi
  if [ -z "$NOTARY_PROFILE" ]; then
    echo "FEHLER: Kein Notary-Profil bekannt." >&2
    echo "Entweder NOTARY_PROFILE setzen oder einmalig fuer diesen Clone:" >&2
    echo "  git config --local mdClip.notaryProfile <profil>" >&2
    return 2
  fi
}

# BEGIN NOTARY_PROFILE_CHECK
notary_profile_works() {
  local profile="$1"
  local attempt output
  for attempt in 1 2 3 4 5; do
    if output="$(xcrun notarytool history --keychain-profile "$profile" 2>&1)"; then
      return 0
    fi
    if ! grep -Fq 'No Keychain password item found' <<<"$output"; then
      printf '%s\n' "$output" >&2
      return 1
    fi
    if [ "$attempt" -lt 5 ]; then
      sleep 3
    fi
  done
  printf '%s\n' "$output" >&2
  return 1
}
# END NOTARY_PROFILE_CHECK

verify_notary_profile() {
  local profile="$1"
  local team_id="$2"

  if notary_profile_works "$profile"; then
    return 0
  fi
  echo "FEHLER: notarytool-Schlüsselbund-Profil '$profile' konnte nicht geprüft werden." >&2
  echo "Über SSH kann der Login-Schlüsselbund gesperrt sein; dann lokal erneut versuchen." >&2
  echo "Neu einrichten (Passwort interaktiv eingeben, nie als Argument):" >&2
  echo "  xcrun notarytool store-credentials \"$profile\" \\" >&2
  echo "    --apple-id \"<deine-apple-id>\" \\" >&2
  echo "    --team-id  \"$team_id\"" >&2
  return 1
}

require_signing_identity() {
  local identity="$1"
  local identities

  identities="$(security find-identity -v -p codesigning)" || return $?
  if grep -Fq "$identity" <<<"$identities"; then
    return 0
  fi
  echo "FEHLER: Signing-Identität nicht gefunden: $identity" >&2
  echo "Verfügbare Identitäten:" >&2
  printf '%s\n' "$identities" >&2
  return 1
}

cleanup_notary_archive() {
  if [ -n "$NOTARY_APP_ZIP_DIR" ] && [ -d "$NOTARY_APP_ZIP_DIR" ]; then
    rm -rf "$NOTARY_APP_ZIP_DIR"
  fi
  NOTARY_APP_ZIP_DIR=""
}

notarize_app_bundle() {
  local app="$1"
  local profile="$2"
  local app_zip status

  NOTARY_APP_ZIP_DIR="$(mktemp -d)"
  app_zip="$NOTARY_APP_ZIP_DIR/md-clip.zip"
  ditto -c -k --keepParent "$app" "$app_zip" || {
    status=$?
    cleanup_notary_archive
    return "$status"
  }
  xcrun notarytool submit "$app_zip" --keychain-profile "$profile" --wait || {
    status=$?
    cleanup_notary_archive
    return "$status"
  }
  cleanup_notary_archive

  xcrun stapler staple "$app"
  xcrun stapler validate "$app"
  spctl --assess --type execute -vv "$app" 2>&1 | tail -2
}
