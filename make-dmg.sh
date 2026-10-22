#!/bin/zsh
# Packs dist/Clementine.app into dist/Clementine.dmg with an Applications shortcut.
set -euo pipefail
cd "$(dirname "$0")"
./build-app.sh >/dev/null
STAGE=$(mktemp -d)
cp -R dist/Clementine.app "$STAGE/"
ln -s /Applications "$STAGE/Applications"
rm -f dist/Clementine.dmg
hdiutil create -quiet -volname Clementine -srcfolder "$STAGE" -ov -format UDZO dist/Clementine.dmg
rm -rf "$STAGE"
echo "$PWD/dist/Clementine.dmg"
