#!/usr/bin/env bash
# Kleine, sourcebare Helfer für verifizierte Release-Artefakte.

sha256_matches() {
  local path="$1"
  local expected="$2"
  [ -f "$path" ] && [ "$(shasum -a 256 "$path" | awk '{print $1}')" = "$expected" ]
}

download_verified() {
  local url="$1"
  local expected_sha256="$2"
  local destination="$3"
  local temporary=""

  if sha256_matches "$destination" "$expected_sha256"; then
    return 0
  fi

  temporary=$(mktemp "${destination}.download.XXXXXX")
  if ! curl -fsSL --output "$temporary" "$url"; then
    rm -f "$temporary"
    return 1
  fi
  if ! sha256_matches "$temporary" "$expected_sha256"; then
    echo "FEHLER: SHA-256-Prüfung fehlgeschlagen für $url" >&2
    rm -f "$temporary"
    return 1
  fi

  mv -f "$temporary" "$destination"
}

verify_pandoc_version() {
  local binary="$1"
  local expected_version="$2"
  local actual_version=""

  [ -x "$binary" ] || return 1
  actual_version=$("$binary" --version 2>/dev/null | head -1 | awk '{print $2}')
  [ "$actual_version" = "$expected_version" ]
}
