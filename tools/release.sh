#!/bin/sh
# Builds a release of the plugin into dist/:
#   polka-<version>.zip  — one folder, polka.koplugin/, ready for koreader/plugins
#   latest.json          — what the site's /api/plugin/latest serves to Kindles
# The version comes from polka.koplugin/_meta.lua, the notes from the first section of
# CHANGELOG.md (its bold lead-ins). Upload both files to a GitHub release tagged v<version>.
# Usage: tools/release.sh [koreader_min]   (default 2026.07)
set -e
cd "$(dirname "$0")/.."
KO_MIN="${1:-2026.07}"
VERSION=$(sed -n 's/^ *version = "\([0-9.]*\)".*/\1/p' polka.koplugin/_meta.lua)
[ -n "$VERSION" ] || { echo "no version in _meta.lua"; exit 1; }
[ ! -e polka.koplugin/polka_web_config.lua ] || { echo "polka_web_config.lua is in the folder: it holds a private key, remove it first"; exit 1; }
rm -rf dist && mkdir -p dist
ZIP="dist/polka-$VERSION.zip"
# a reproducible zip: sorted names, fixed times, no extra attributes
TZ=UTC find polka.koplugin -type f ! -name '.*' ! -name '*.orig' | LC_ALL=C sort > dist/files.txt
TZ=UTC touch -t 202601010000 $(cat dist/files.txt)
zip -q -X -D "$ZIP" -@ < dist/files.txt
rm dist/files.txt
SHA=$(sha256sum "$ZIP" | cut -d' ' -f1)
SIZE=$(wc -c < "$ZIP" | tr -d ' ')
python3 - "$VERSION" "$SHA" "$SIZE" "$KO_MIN" > dist/latest.json <<'PY'
import json, re, sys
version, sha, size, ko_min = sys.argv[1], sys.argv[2], int(sys.argv[3]), sys.argv[4]
text = open('CHANGELOG.md', encoding='utf-8').read()
m = re.search(r'^## ' + re.escape(version) + r'\s*$(.*?)(?=^## |\Z)', text, re.M | re.S)
notes = re.findall(r'^\*\*(.+?)\*\*', m.group(1), re.M) if m else []
notes = [n.rstrip('.').strip() for n in notes][:8]
print(json.dumps({'version': version, 'sha256': sha, 'size': size, 'notes': notes, 'koreader_min': ko_min}, ensure_ascii=False, indent=2))
PY
echo "$ZIP  $SIZE bytes  sha256 $SHA"
cat dist/latest.json
