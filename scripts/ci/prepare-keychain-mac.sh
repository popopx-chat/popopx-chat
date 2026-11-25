#!/bin/bash

# Nothing in CI calls this script: it builds the local keychain whose base64 is what
# APPLE_POPOPX_SIGNING_KEYCHAIN holds for the CI runs. The file names follow whichever identity is
# configured, so no signing identity is named in this repository.
: "${APPLE_POPOPX_SIGNING_IDENTITY:?APPLE_POPOPX_SIGNING_IDENTITY is not set - e.g. Developer ID Application: <entity> (<team id>)}"
: "${APPLE_POPOPX_SIGNING_P12:?APPLE_POPOPX_SIGNING_P12 is not set - the exported private key to import}"
: "${APPLE_POPOPX_SIGNING_PEM:?APPLE_POPOPX_SIGNING_PEM is not set - the exported public key to import}"

keychain=popopx.keychain

security create-keychain -p "" "$keychain"
security set-keychain-settings -u "$keychain"
security add-certificates -k "$keychain" "$APPLE_POPOPX_SIGNING_IDENTITY.cer"
# Apple's own intermediate certificate: the name is Apple's, not the signer's.
security add-certificates -k "$keychain" "Developer ID Certification Authority.cer"
# Private key with access from any app
security import "$APPLE_POPOPX_SIGNING_P12" -P "" -k "$keychain" -A
# Public key
security import "$APPLE_POPOPX_SIGNING_PEM" -k "$keychain"
