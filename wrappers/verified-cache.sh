#!/usr/bin/env bash
# Kleine, sourcebare Helfer für verifizierte Release-Artefakte.

# SHA-256 einer Datei, als reine Hex-Kette.
#
# Zwei Werkzeuge, weil keines auf beiden Systemen sicher da ist: macOS bringt
# `shasum` mit, aber kein `sha256sum`. Auf Debian und Ubuntu ist es umgekehrt —
# dort steckt `shasum` im vollen `perl`-Paket, das auf einem schlanken System
# (Container, Server) fehlt, während `sha256sum` aus den coreutils immer da ist.
sha256_of() {
  local path="$1"
  if command -v shasum >/dev/null 2>&1; then
    shasum -a 256 "$path" | awk '{print $1}'
  else
    sha256sum "$path" | awk '{print $1}'
  fi
}

sha256_matches() {
  local path="$1"
  local expected="$2"
  [ -f "$path" ] && [ "$(sha256_of "$path")" = "$expected" ]
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
