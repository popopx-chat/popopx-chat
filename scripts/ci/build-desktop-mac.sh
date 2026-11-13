#!/bin/bash

set -e

# The identity and team id name whoever's certificate signs this build, so they are configuration from the
# CI secrets and not a string in this repository. Missing means "we cannot sign", reported here, not by codesign.
: "${APPLE_POPOPX_SIGNING_IDENTITY:?APPLE_POPOPX_SIGNING_IDENTITY is not set - e.g. Developer ID Application: <entity> (<team id>)}"
# Ruled: our Apple team is PDBA6XRBQT - the same id as DEVELOPMENT_TEAM in the project and the keychain
# access group in KeyChain.swift. It is an identifier, not a secret, so it is the default; the secret wins.
APPLE_POPOPX_NOTARIZATION_TEAM_ID="${APPLE_POPOPX_NOTARIZATION_TEAM_ID:-PDBA6XRBQT}"

trap "rm apps/multiplatform/local.properties 2> /dev/null || true; rm local.properties 2> /dev/null || true; rm /tmp/popopx.keychain" EXIT
echo "desktop.mac.signing.identity=$APPLE_POPOPX_SIGNING_IDENTITY" >> apps/multiplatform/local.properties
echo "desktop.mac.signing.keychain=/tmp/popopx.keychain" >> apps/multiplatform/local.properties
echo "desktop.mac.notarization.apple_id=$APPLE_POPOPX_NOTARIZATION_APPLE_ID" >> apps/multiplatform/local.properties
echo "desktop.mac.notarization.password=$APPLE_POPOPX_NOTARIZATION_PASSWORD" >> apps/multiplatform/local.properties
echo "desktop.mac.notarization.team_id=$APPLE_POPOPX_NOTARIZATION_TEAM_ID" >> apps/multiplatform/local.properties
echo "$APPLE_POPOPX_SIGNING_KEYCHAIN" | base64 --decode -o /tmp/popopx.keychain

security unlock-keychain -p "" /tmp/popopx.keychain
# Adding keychain to the list of keychains.
# Otherwise, it can find cert but exits while signing with "error: The specified item could not be found in the keychain."
security list-keychains -s `security list-keychains | xargs` /tmp/popopx.keychain
scripts/desktop/build-lib-mac.sh
cd apps/multiplatform
if [ -n "${ASSETS_DIR:-}" ]; then
  set -- -Ppopopx.assets.dir="$ASSETS_DIR"
else
  set --
fi
./gradlew "$@" packageDmg
./gradlew "$@" notarizeDmg
