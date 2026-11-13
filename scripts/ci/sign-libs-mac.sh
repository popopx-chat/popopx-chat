#!/bin/bash

set -euo pipefail

libs=$1
team="${APPLE_POPOPX_NOTARIZATION_TEAM_ID:-PDBA6XRBQT}"
identity="${APPLE_POPOPX_SIGNING_IDENTITY:?APPLE_POPOPX_SIGNING_IDENTITY is not set - e.g. Developer ID Application: <entity> (<team id>)}"
keychain=/tmp/popopx.keychain
temp=$(mktemp -d)
trap 'rm -rf "$keychain" "$temp"' EXIT

notarytool() {
  xcrun notarytool "$@" --apple-id "$APPLE_POPOPX_NOTARIZATION_APPLE_ID" --password "$APPLE_POPOPX_NOTARIZATION_PASSWORD" --team-id "$team"
}

echo "$APPLE_POPOPX_SIGNING_KEYCHAIN" | base64 --decode -o "$keychain"
security unlock-keychain -p "" "$keychain"
security list-keychains -s $(security list-keychains | xargs) "$keychain"

for lib in "$libs"/*.dylib; do
  codesign --remove-signature "$lib"
  codesign --timestamp --options runtime --force --sign "$identity" --keychain "$keychain" "$lib"
done

ditto -c -k --keepParent "$libs" "$temp/libs.zip"
notarytool submit "$temp/libs.zip" --wait --timeout 1h --output-format json > "$temp/submission.json" || true
cat "$temp/submission.json"
read -r id status < <(python3 -c 'import json, sys; r = json.load(open(sys.argv[1])); print(r["id"], r["status"])' "$temp/submission.json")
notarytool log "$id"
if [ "$status" != Accepted ]; then
  exit 1
fi
