#!/usr/bin/env bash
# Regressionen der Inhaltsfehler aus den wiedergefundenen Reviews.
set -euo pipefail
ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
source "$ROOT/lib/pipeline.sh"
TEST_ROOT=$(mktemp -d "${TMPDIR:-/tmp}/md-clip-review.XXXXXX")
trap 'rm -rf "$TEST_ROOT"' EXIT
trap 'exit 130' INT
trap 'exit 143' TERM
failed=0
check() {
  local name="$1" actual="$2" expected="$3"
  printf '%s' "$actual" > "$TEST_ROOT/actual"
  printf '%s' "$expected" > "$TEST_ROOT/expected"
  if cmp -s "$TEST_ROOT/actual" "$TEST_ROOT/expected"; then
    printf '✓ %s\n' "$name"
  else
    printf '✗ %s\n' "$name" >&2
    diff -u "$TEST_ROOT/expected" "$TEST_ROOT/actual" >&2 || true
    failed=$((failed + 1))
  fi
}
# Der Wächter erhält auch Schluss-LFs trotz Shell-Command-Substitution.
tidy() { printf '%s' "$1" | tidy_markdown gfm; printf '@'; }
code=$'    \\# keep\\\n    \\- keep\n'
check quote_then_code "$(tidy $'> -   item\n\n'"$code")" $'> -   item\n\n'"$code"'@'
check outer_list_quote_return "$(tidy $'- outer\n\n  > -   inner\n\n      \\# keep\\\n      \\- keep\n')" $'- outer\n\n  > -   inner\n\n      \\# keep\\\n      \\- keep\n@'
check quoted_fence_then_code "$(tidy $'> ```\n> \\- quoted\n> ```\n\n'"$code")" $'> ```\n> \\- quoted\n> ```\n\n'"$code"'@'
check fence_literal_quote "$(tidy $'```\n> - item\n\\- keep\n```\n')" $'```\n> - item\n\\- keep\n```\n@'
check claude_attribute_order "$(printf '%s' '<pre><code><div style="x" data-line="1">one</div><div class="x" data-line="2">two</div></code></pre>' | convert_html gfm)" $'    one\n    two'
check claude_existing_order "$(printf '%s' '<pre><code><div data-line="1" class="x">one</div><div data-line="2">two</div></code></pre>' | convert_html gfm)" $'    one\n    two'
check claude_unrelated_div "$(printf '%s' '<div data-lineage="1">one</div>' | preprocess_claude_desktop)" '<div>one</div>'
classroom() { printf '%s' "<a href=\"https://example.test/doc\"><img src=\"https://classroom.google.com/webthumbnail/x\">$1</a>" | preprocess_google_classroom; }
expected='<ul><li><a href="https://example.test/doc">Title</a></li></ul>'
check classroom_following_attribute "$(classroom '<div class="mvRF3b" dir="auto">Title</div>')" "$expected"
check classroom_existing_title "$(classroom '<div class="mvRF3b">Title</div>')" "$expected"
check classroom_class_token "$(classroom '<div dir="auto" class=" other mvRF3b more ">Title</div>')" "$expected"
check classroom_wrong_class "$(classroom '<div class="xmvRF3b">Title</div>')" '<a href="https://example.test/doc"></a>'
# Der vollständige Code-Inhalt muss nach HTML-Konvertierung und erneutem
# Parsen erhalten bleiben, auch wenn eine Liste vor einem eigenen Zitat steht.
html=$'<ul><li>item</li></ul><blockquote><p>quote</p></blockquote><pre><code>&#92;- keep\nx&#92;\nnext\n</code></pre>'
for format in gfm markdown commonmark; do
  actual=$(printf '%s' "$html" | "$ROOT/bin/md-clip" --stdin --from html --to "$format" --quiet | pandoc -f "$format" -t native)
  expected=$(printf '%s' "$html" | pandoc -f html -t native)
  check "outer_list_standalone_quote_code_$format" "$actual" "$expected"
done
[ "$failed" -eq 0 ]
