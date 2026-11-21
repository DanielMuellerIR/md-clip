#!/usr/bin/env bash
# Release-Auswahl, Sparkle-Generator und Formatprüfung für den Appcast.

validate_release_tag() {
  local candidate="$1"
  case "$candidate" in
    *$'\n'*|*$'\r'*)
      echo "FEHLER: Release-Tag muss genau eine Zeile enthalten." >&2
      return 64
      ;;
  esac
  if [[ ! "$candidate" =~ ^v(0|[1-9][0-9]*)\.(0|[1-9][0-9]*)\.(0|[1-9][0-9]*)$ ]]; then
    echo "FEHLER: Ungueltiges stabiles Release-Tag: '$candidate'." >&2
    return 64
  fi
}

select_release_tag() {
  local requested_tag="$1"
  local latest_tag

  case "$GITHUB_EVENT_NAME" in
    workflow_dispatch)
      # Manuelle Eingaben werden validiert, aber niemals selbst an
      # spaetere Schritte weitergereicht.
      validate_release_tag "$requested_tag" || return $?
      ;;
    workflow_run)
      if [[ -n "$requested_tag" ]]; then
        echo "FEHLER: Automatischer Lauf erhielt unerwartet eine Tag-Eingabe." >&2
        return 64
      fi
      ;;
    *)
      echo "FEHLER: Unerwarteter Workflow-Ausloeser: $GITHUB_EVENT_NAME" >&2
      return 64
      ;;
  esac

  latest_tag="$(gh api "repos/${GITHUB_REPOSITORY}/releases/latest" --jq .tag_name)" || return $?
  validate_release_tag "$latest_tag" || return $?
  if [[ "$GITHUB_EVENT_NAME" == "workflow_dispatch" && "$requested_tag" != "$latest_tag" ]]; then
    echo "FEHLER: $requested_tag ist nicht das aktuelle stabile Release ($latest_tag)." >&2
    return 1
  fi

  # Erst nach allen Prüfungen schreiben, und ausschließlich den von
  # der API ermittelten Wert — nie die manuelle Eingabe.
  printf '%s\n' "RELEASE_TAG=$latest_tag" >> "$GITHUB_ENV"
}

run_appcast_generator() {
  local generator_output
  # Command-Substitution wartet auf die gesamte Pipeline und erfasst
  # stdout und stderr gemeinsam. Sparkle schreibt auch sicherheits-
  # relevante Warnungen auf stdout; eine asynchrone Prozess-
  # substitution koennte beim anschliessenden grep noch leer sein.
  if ! generator_output="$(printf '%s' "$sparkle_private_key" | "$@" 2>&1)"; then
    printf '%s\n' "$generator_output" >&2
    return 1
  fi
  printf '%s\n' "$generator_output" >&2
  if grep -Fq 'does not match key EdDSA' <<<"$generator_output"; then
    echo "FEHLER: SPARKLE_PRIVATE_KEY passt nicht zum öffentlichen Schlüssel der App." >&2
    return 1
  fi
}

validate_appcast() {
  local appcast_file="$1"
  local expected_version="$2"
  local expected_short_version="$3"
  local expected_enclosure_url="$4"
  local item_xpath='/*[local-name()="rss"]/*[local-name()="channel"]/*[local-name()="item"]'
  local enclosure_xpath="${item_xpath}/*[local-name()=\"enclosure\"]"
  local version_xpath="${item_xpath}/*[local-name()=\"version\"]"
  local short_version_xpath="${item_xpath}/*[local-name()=\"shortVersionString\"]"
  local item_count enclosure_count feed_version feed_short_version feed_url feed_signature

  xmllint --noout "$appcast_file" || return $?
  item_count="$(xmllint --xpath "count(${item_xpath})" "$appcast_file")" || return $?
  enclosure_count="$(xmllint --xpath "count(${enclosure_xpath})" "$appcast_file")" || return $?
  feed_version="$(xmllint --xpath "string(${version_xpath})" "$appcast_file")" || return $?
  feed_short_version="$(xmllint --xpath "string(${short_version_xpath})" "$appcast_file")" || return $?
  feed_url="$(xmllint --xpath "string(${enclosure_xpath}/@url)" "$appcast_file")" || return $?
  feed_signature="$(xmllint --xpath "string(${enclosure_xpath}/@*[local-name()=\"edSignature\"])" "$appcast_file")" || return $?

  if [[ "$item_count" != "1" || "$enclosure_count" != "1" ]]; then
    echo "FEHLER: Appcast braucht genau einen Eintrag mit genau einem Enclosure (gefunden: $item_count/$enclosure_count)." >&2
    return 1
  fi
  if [[ "$feed_version" != "$expected_version" || "$feed_short_version" != "$expected_short_version" ]]; then
    echo "FEHLER: Appcast-Versionen '$feed_version'/'$feed_short_version' passen nicht zu $expected_version." >&2
    return 1
  fi
  if [[ "$feed_url" != "$expected_enclosure_url" ]]; then
    echo "FEHLER: Appcast-URL '$feed_url' passt nicht zu '$expected_enclosure_url'." >&2
    return 1
  fi
  if [[ -z "$feed_signature" ]]; then
    echo "FEHLER: Appcast-Enclosure hat keine Sparkle-EdDSA-Signatur." >&2
    return 1
  fi
}
