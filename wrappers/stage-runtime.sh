#!/usr/bin/env bash
# Stellt die Laufzeitdateien für App-Build und isolierte Tests bereit.

stage_runtime() {
  local project="$1" bin_dir="$2" lib_dir="${3:-$2}"
  local resource
  mkdir -p "$bin_dir" "$lib_dir" || return
  cp "$project/bin/md-clip" "$bin_dir/md-clip" || return
  for resource in platform.sh doctor.sh conversion-report.sh pipeline.sh \
    tidy-markdown.pl pandoc-filter.lua preprocess-html.pl conversion-support.pl; do
    cp "$project/lib/$resource" "$lib_dir/$resource" || return
  done
}

if [ "${BASH_SOURCE[0]}" = "$0" ]; then
  stage_runtime "$@"
fi
