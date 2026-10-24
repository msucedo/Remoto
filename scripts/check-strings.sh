#!/bin/zsh
# Fails if a key in the English strings is missing from the Spanish ones (or the reverse).
set -euo pipefail
ROOT="${0:A:h:h}"
keys() { plutil -convert json -o - "$1" | python3 -c 'import json,sys; print("\n".join(sorted(json.load(sys.stdin))))'; }
for f in Localizable.strings; do
  diff <(keys "$ROOT/Support/en.lproj/$f") <(keys "$ROOT/Support/es.lproj/$f") \
    && echo "$f: en and es match"
done
