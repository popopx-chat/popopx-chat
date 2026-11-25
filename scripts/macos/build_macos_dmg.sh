#!/bin/bash
#
#  build_macos_dmg.sh
#  POPOPX Chat macOS release pipeline
#
#  Copyright © 2026 POPOPX Chat. All rights reserved.
#  SPDX-License-Identifier: AGPL-3.0-only
#
# Builds a universal (arm64 + x86_64) POPOPX.app, embeds the tor daemon that PopopxTorKit launches
# as Contents/Helpers/tor, signs and notarizes the bundle, and publishes it as
# dist/POPOPX-macOS-Universal.dmg together with dist/SHA256SUMS.
#
# This script never edits project.pbxproj: the macOS target and its scheme are created by hand in
# Xcode, and here the project is only read. If the requested scheme does not exist the build stops
# with the list of schemes it did find, because a log line that claims success while producing no
# artifact is worse than no build at all.
#
# Every knob is an environment variable, so one command line works on a laptop and in CI. The signing
# and notarization variables keep the names used by scripts/ci/sign-libs-mac.sh and
# scripts/ci/build-desktop-mac.sh, so the existing CI secrets apply unchanged.

set -euo pipefail

# The script lives in scripts/macos, so the repository root is two directories above it. Resolved
# from $0, which lets the script be invoked from any working directory.
abs_dir() {
  (cd "$(dirname "$1")" && pwd -P)
}
REPO_ROOT="$(dirname "$(dirname "$(abs_dir "$0")")")"

# ---------- configuration ----------
PROJECT_PATH="${POPOPX_MACOS_PROJECT:-$REPO_ROOT/apps/ios/POPOPX.xcodeproj}"
SCHEME="${POPOPX_MACOS_SCHEME:-POPOPXChat-macOS}"
CONFIGURATION="${POPOPX_MACOS_CONFIGURATION:-Release}"
DERIVED_DATA="${POPOPX_MACOS_DERIVED_DATA:-$REPO_ROOT/dist/macos-derived}"
OUT_DIR="${POPOPX_MACOS_OUT_DIR:-$REPO_ROOT/dist}"
APP_NAME="${POPOPX_MACOS_APP_NAME:-POPOPX.app}"
DMG_NAME="${POPOPX_MACOS_DMG_NAME:-POPOPX-macOS-Universal.dmg}"
VOL_NAME="${POPOPX_MACOS_VOLUME_NAME:-POPOPX macOS Universal}"
ENTITLEMENTS="${POPOPX_MACOS_ENTITLEMENTS:-}"
# Where PopopxTorKit looks for the daemon at runtime (TorBinaryLocator.bundleRelativePath); keep in sync.
TOR_REL_PATH="Contents/Helpers/tor"
# Where the helper's licence text is installed inside the bundle. The licence has to travel with the
# binary it describes, so it is read out of the same verified asset rather than written into this
# repository for a version this repository does not pin.
TOR_LICENSE_REL_PATH="Contents/Resources/licences/tor/LICENSE"

# The identity and team name whoever's certificate signs this build, so they are configuration from
# the CI secrets and not strings in this repository. An empty identity means "we cannot sign", and
# the artifact is then an ad-hoc test build that must never be published.
SIGNING_IDENTITY="${APPLE_POPOPX_SIGNING_IDENTITY:-}"
SIGNING_KEYCHAIN_B64="${APPLE_POPOPX_SIGNING_KEYCHAIN:-}"
NOTARIZATION_TEAM="${APPLE_POPOPX_NOTARIZATION_TEAM_ID:-PDBA6XRBQT}"
NOTARIZATION_APPLE_ID="${APPLE_POPOPX_NOTARIZATION_APPLE_ID:-}"
NOTARIZATION_PASSWORD="${APPLE_POPOPX_NOTARIZATION_PASSWORD:-}"

usage() {
  cat <<'EOF'
usage: scripts/macos/build_macos_dmg.sh [--dry-run] [--help]

Build, sign, notarize and package the POPOPX macOS app as a universal DMG in dist/.

environment variables:
  POPOPX_MACOS_PROJECT        Xcode project holding the macOS target
                              (default: apps/ios/POPOPX.xcodeproj)
  POPOPX_MACOS_SCHEME         macOS scheme to build (default: POPOPXChat-macOS). This repository has
                              no macOS target yet, so until one is added in Xcode the script stops
                              and prints the schemes the project actually has.
  POPOPX_MACOS_CONFIGURATION  build configuration (default: Release)
  POPOPX_MACOS_DERIVED_DATA   derived data directory (default: dist/macos-derived)
  POPOPX_MACOS_OUT_DIR        artifact directory, gitignored (default: dist)
  POPOPX_MACOS_APP_NAME       bundle name inside the DMG (default: POPOPX.app)
  POPOPX_MACOS_DMG_NAME       DMG file name (default: POPOPX-macOS-Universal.dmg)
  POPOPX_MACOS_VOLUME_NAME    DMG volume name (default: "POPOPX macOS Universal")
  POPOPX_MACOS_ENTITLEMENTS   .entitlements file passed to codesign for the bundle (optional; the
                              embedded tor is signed without entitlements, since a sandbox would
                              forbid the DataDirectory writes the daemon needs)
  POPOPX_TOR_LOCAL            path to a tor binary to embed as-is - a developer fallback, e.g. a
                              locally built tor, or Homebrew's /opt/homebrew/opt/tor/bin/tor on
                              Apple Silicon and /usr/local/opt/tor/bin/tor on Intel. Nothing is
                              picked up from PATH unless this variable names it explicitly.
  POPOPX_TOR_URL              URL of the tor asset to embed (a bare binary, a .zip, or a
                              .tar.gz/.tgz containing a file named "tor"). Required for a release.
  POPOPX_TOR_SHA256           SHA-256 of that asset. Required together with POPOPX_TOR_URL: the
                              asset is pinned by digest and verified before anything downloaded is
                              extracted or executed. It is not stored in this repository, so it has
                              to come from the release you audited (the digest published next to the
                              asset, or from a tor you built yourself).
  POPOPX_TOR_LICENSE          Path to the licence text of the version being embedded. Optional: a
                              downloaded .tar.gz/.zip usually carries its own LICENSE, which this
                              script reads out of the same verified asset and installs at
                              Contents/Resources/licences/tor/LICENSE. Set this when the asset has no
                              LICENSE (a bare binary, or POPOPX_TOR_LOCAL) - a Developer ID build
                              stops without one, because the licence has to travel with the binary.
  APPLE_POPOPX_SIGNING_IDENTITY       codesign identity; unset means ad-hoc, local testing only
  APPLE_POPOPX_SIGNING_KEYCHAIN       base64 of the keychain holding that identity, as used by CI
  APPLE_POPOPX_NOTARIZATION_APPLE_ID  notarization credentials (required with an identity)
  APPLE_POPOPX_NOTARIZATION_PASSWORD  notarization credentials (required with an identity)
  APPLE_POPOPX_NOTARIZATION_TEAM_ID   notarization team id (default: the team id used by CI)

flags:
  --dry-run   check the environment and the tor asset inputs, and print the exact commands a real
              run would execute. Builds nothing, signs nothing, writes nothing, does not contact the
              network, and does not query the project (xcodebuild -list resolves the package graph).
              Scheme existence is therefore only verified by a real run.
  --help      show this text and exit

outputs:
  dist/POPOPX-macOS-Universal.dmg   universal, signed, notarized when an identity was supplied
  dist/SHA256SUMS                   "<digest>  <dmg file name>" from shasum -a 256
EOF
}

log() {
  printf '%s\n' "$*"
}

warn() {
  printf 'warning: %s\n' "$*" >&2
}

die() {
  printf 'error: %s\n' "$*" >&2
  exit 1
}

# Print a command the way it would be executed, quoted, so a dry run can be copied into a shell.
print_cmd() {
  local line="    " a
  for a in "$@"; do
    line="$line'${a}' "
  done
  printf '%s\n' "$line"
}

# Run a command that has side effects, or only print it under --dry-run.
run() {
  print_cmd "$@"
  if [ "$DRY_RUN" -eq 0 ]; then
    "$@"
  fi
}

lower() {
  printf '%s' "$1" | tr '[:upper:]' '[:lower:]'
}

# Does a "lipo -archs" list carry the given architecture? The arm64e and arm64v8 spellings count as
# arm64: they are the same instruction set the app's arm64 slice runs on.
arch_list_has() {
  local want="$1" a
  for a in $2; do
    case "$a" in
      "$want"*) return 0 ;;
    esac
  done
  return 1
}

archs_are_universal() {
  arch_list_has arm64 "$1" && arch_list_has x86_64 "$1"
}

DRY_RUN=0
while [ $# -gt 0 ]; do
  case "$1" in
    --dry-run) DRY_RUN=1 ;;
    -h | --help)
      usage
      exit 0
      ;;
    *)
      usage >&2
      die "unknown argument: $1"
      ;;
  esac
  shift
done

TMP="$(mktemp -d)"
KEYCHAIN_FILE=""
KEYCHAIN_CREATED=0
cleanup() {
  rm -rf "$TMP"
  # Only the keychain decoded from the secret is removed; a developer's own keychain, built by
  # scripts/ci/prepare-keychain-mac.sh, is not ours to delete.
  if [ "$KEYCHAIN_CREATED" -eq 1 ] && [ -n "$KEYCHAIN_FILE" ]; then
    rm -f "$KEYCHAIN_FILE"
  fi
}
trap cleanup EXIT

for tool in xcodebuild codesign hdiutil ditto shasum lipo file curl security xcrun install; do
  command -v "$tool" > /dev/null 2>&1 || die "required tool not found: $tool"
done
[ "$(uname -s)" = Darwin ] || die "macOS host required to build and sign a .app (uname -s: $(uname -s))"

if [ -n "$ENTITLEMENTS" ] && [ ! -f "$ENTITLEMENTS" ]; then
  die "POPOPX_MACOS_ENTITLEMENTS names no file: $ENTITLEMENTS"
fi

# ---------- scheme ----------
# The only Xcode project in this repository builds the iOS app, and its target list has no macOS
# product. Share the scheme in Xcode (Product > Scheme > Manage Schemes > Shared) so xcodebuild can
# see it: an autounsaved scheme is invisible to xcodebuild -list, here and in CI alike.
list_schemes() {
  xcodebuild -list -project "$1" 2> /dev/null | awk '
    /^[[:space:]]*Schemes:/ { in_schemes = 1; next }
    in_schemes && /^[[:space:]]*$/ { in_schemes = 0 }
    in_schemes { sub(/^[[:space:]]+/, ""); sub(/[[:space:]]+$/, ""); if (NF) print }'
}

if [ "$DRY_RUN" -eq 1 ]; then
  log "[dry-run] skipping the scheme check: xcodebuild -list resolves the package graph"
else
  [ -d "$PROJECT_PATH" ] || die "no Xcode project at $PROJECT_PATH - set POPOPX_MACOS_PROJECT"
  log "checking for scheme '$SCHEME' in $PROJECT_PATH"
  SCHEMES="$(list_schemes "$PROJECT_PATH")"
  [ -n "$SCHEMES" ] || die "xcodebuild -list returned no schemes for $PROJECT_PATH"
  if ! printf '%s\n' "$SCHEMES" | grep -Fxq "$SCHEME"; then
    printf 'error: no macOS scheme "%s" in %s\n' "$SCHEME" "$PROJECT_PATH" >&2
    printf 'schemes this project does have:\n' >&2
    printf '%s\n' "$SCHEMES" | sed 's/^/  /' >&2
    die "add the macOS target in Xcode by dragging the macOS sources into the project and create a scheme for it (this script must not edit project.pbxproj), share that scheme, then re-run as: POPOPX_MACOS_SCHEME='<that scheme name>' $0 - or point at another project with POPOPX_MACOS_PROJECT='<path>' $0"
  fi
  log "scheme found: $SCHEME"
fi

# ---------- tor asset ----------
# The helper is never committed to the repository: it is fetched, or taken from a local build, at
# packaging time, and pinned by digest, because it is the component carrying all of the app's
# outbound traffic.
TOR_SOURCE=""
TOR_LICENSE_SOURCE=""

# Compare case-insensitively, and over the basename only, so the digest matches what
# "shasum -a 256 tor" prints next to the published asset.
check_sha256() {
  local file="$1" expected actual dir name
  expected="$(lower "$2")"
  case "$expected" in
    *[!a-f0-9]*) die "not a hexadecimal sha256 digest: $2" ;;
    ?*) [ "${#expected}" -eq 64 ] || die "not a 64-character sha256 digest: $2" ;;
  esac
  dir="$(abs_dir "$file")"
  name="$(basename "$file")"
  actual="$(cd "$dir" && shasum -a 256 "$name" | cut -d' ' -f1 | tr '[:upper:]' '[:lower:]')"
  if [ "$actual" != "$expected" ]; then
    printf 'error: sha256 mismatch for %s\n' "$name" >&2
    printf '  expected: %s\n' "$expected" >&2
    printf '  actual:   %s\n' "$actual" >&2
    die "refusing to use this asset; if upstream republished the file, re-derive the digest from the release you are trusting and re-run"
  fi
  log "sha256 verified for $name: $actual"
}

# A helper that is not universal cannot serve both slices of the app. Warn, and say what breaks:
# an arm64-only tor cannot be executed at all on an Intel Mac, so the app reports the daemon as
# unusable there instead of routing - and a DMG published like that is a broken release.
report_tor_archs() {
  local archs
  archs="$(lipo -archs "$1" 2> /dev/null || true)"
  if [ -z "$archs" ]; then
    warn "cannot read architectures from $1 (file says: $(file -b "$1" 2> /dev/null || echo unreadable))"
    return
  fi
  log "tor architectures: $archs"
  if archs_are_universal "$archs"; then
    return
  fi
  arch_list_has arm64 "$archs" || warn "LIMITATION: the embedded tor ($archs) has no arm64 slice, so it will not run natively on Apple Silicon"
  arch_list_has x86_64 "$archs" || warn "LIMITATION: the embedded tor ($archs) has no x86_64 slice, so on an Intel Mac the app cannot start the daemon at all"
  warn "LIMITATION: publishing this DMG ships a helper that fails on part of the universal app; use a universal tor (or POPOPX_TOR_LOCAL pointing at one)"
}

# The licence text inside an extracted asset. Only the names a source tarball actually uses are
# looked for, and only near the top of the tree, so a stray "license" string in a test fixture cannot
# become the notice we publish for the daemon.
find_license_in() {
  find "$1" -maxdepth 3 -type f \
    \( -name 'LICENSE' -o -name 'LICENSE.TXT' -o -name 'LICENCE' -o -name 'COPYING' \) -print -quit
}

extract_tor() {
  local archive="$1" out="$TMP/extract" found
  mkdir -p "$out"
  case "$archive" in
    *.tar.gz | *.tgz)
      run tar -xzf "$archive" -C "$out"
      ;;
    *.zip)
      run ditto -x -k "$archive" "$out"
      ;;
    *)
      # No known container: assume the URL served the executable itself.
      TOR_SOURCE="$archive"
      log "tor asset has no known archive extension; treating it as a bare binary"
      return
      ;;
  esac
  if [ "$DRY_RUN" -eq 1 ]; then
    TOR_SOURCE="$out/tor"
    log "[dry-run] would take the file named 'tor' out of the extracted asset, and its licence text with it"
    return
  fi
  found="$(find "$out" -type f -name tor -print -quit)"
  [ -n "$found" ] || die "the extracted asset contains no file named 'tor'"
  TOR_SOURCE="$found"
  log "tor source: $TOR_SOURCE"
  TOR_LICENSE_SOURCE="$(find_license_in "$out")"
  if [ -n "$TOR_LICENSE_SOURCE" ]; then
    log "tor licence text: $TOR_LICENSE_SOURCE (same asset as the binary)"
  else
    warn "the tor asset carries no licence file; the binary will be embedded without the notice that its licence requires"
  fi
}

resolve_tor_source() {
  if [ -n "${POPOPX_TOR_LOCAL:-}" ]; then
    [ -f "$POPOPX_TOR_LOCAL" ] || die "POPOPX_TOR_LOCAL names no file: $POPOPX_TOR_LOCAL"
    TOR_SOURCE="$POPOPX_TOR_LOCAL"
    log "tor source: local file $TOR_SOURCE"
    # A digest is optional here on purpose, because this is a developer fallback. If one is given it
    # is held to the same standard as a downloaded asset.
    if [ -n "${POPOPX_TOR_SHA256:-}" ]; then
      check_sha256 "$TOR_SOURCE" "$POPOPX_TOR_SHA256"
    fi
    return
  fi

  if [ -z "${POPOPX_TOR_URL:-}" ] || [ -z "${POPOPX_TOR_SHA256:-}" ]; then
    printf 'error: the embedded tor asset must be pinned by digest\n' >&2
    printf 'A release build needs both POPOPX_TOR_URL and POPOPX_TOR_SHA256.\n' >&2
    printf 'This script hardcodes neither: no tor macOS universal asset URL or digest has been\n' >&2
    printf 'verified for this repository, and an unverified constant silently ships whatever that URL\n' >&2
    printf 'happens to serve. Take the digest from the release you audited, or from a tor you built,\n' >&2
    printf 'then run:\n' >&2
    printf "  POPOPX_TOR_URL='https://<host>/<path>/tor-<version>.tar.gz' POPOPX_TOR_SHA256='<64 hex digits>' %s\n" "$0" >&2
    printf 'For a local test build instead, name one binary:\n' >&2
    printf '  POPOPX_TOR_LOCAL=/opt/homebrew/opt/tor/bin/tor %s --dry-run\n' "$0" >&2
    exit 1
  fi

  local download="$TMP/download" archive base
  base="$(basename "${POPOPX_TOR_URL%%\?*}")"
  [ -n "$base" ] || base="tor-asset"
  log "downloading $POPOPX_TOR_URL"
  run curl --tlsv1.2 --location --fail --silent --show-error --output "$download" "$POPOPX_TOR_URL"
  if [ "$DRY_RUN" -eq 1 ]; then
    log "[dry-run] would verify the digest of $base against POPOPX_TOR_SHA256, then extract it; no network request was made"
    return
  fi
  # Digest first, and never any execution: nothing that was just downloaded is unpacked, installed or
  # run until it matches the pinned value.
  archive="$TMP/$base"
  mv "$download" "$archive"
  check_sha256 "$archive" "$POPOPX_TOR_SHA256"
  extract_tor "$archive"
}

resolve_tor_source
# An explicit licence file wins over the archive scan: it is how a POPOPX_TOR_LOCAL build, or an asset
# whose notice is named something this script does not look for, still gets a licence into the bundle.
if [ -n "${POPOPX_TOR_LICENSE:-}" ]; then
  [ -f "$POPOPX_TOR_LICENSE" ] || die "POPOPX_TOR_LICENSE names no file: $POPOPX_TOR_LICENSE"
  TOR_LICENSE_SOURCE="$POPOPX_TOR_LICENSE"
  log "tor licence text: $TOR_LICENSE_SOURCE (POPOPX_TOR_LICENSE)"
fi
if [ "$DRY_RUN" -eq 1 ]; then
  if [ -n "$TOR_SOURCE" ] && [ -f "$TOR_SOURCE" ]; then
    report_tor_archs "$TOR_SOURCE"
  else
    log "[dry-run] architecture report for tor skipped: the real run fetches and verifies it first"
  fi
else
  [ -n "$TOR_SOURCE" ] && [ -f "$TOR_SOURCE" ] || die "no tor binary resolved to embed"
  report_tor_archs "$TOR_SOURCE"
fi

# ---------- build ----------
run xcodebuild -project "$PROJECT_PATH" -scheme "$SCHEME" -configuration "$CONFIGURATION" \
  -destination 'generic/platform=macOS' ARCHS="arm64 x86_64" ONLY_ACTIVE_ARCH=NO \
  -derivedDataPath "$DERIVED_DATA" build

APP_PATH="$DERIVED_DATA/Build/Products/$CONFIGURATION/$APP_NAME"
if [ "$DRY_RUN" -eq 0 ]; then
  # The generic macOS destination names the products directory after the configuration; match either
  # spelling rather than guessing one.
  found=""
  for d in "$DERIVED_DATA/Build/Products/$CONFIGURATION"*; do
    if [ -d "$d/$APP_NAME" ]; then
      found="$d/$APP_NAME"
      break
    fi
  done
  [ -n "$found" ] || die "the build produced no $APP_NAME under $DERIVED_DATA/Build/Products"
  APP_PATH="$found"
fi
log "app: $APP_PATH"

# ---------- universal proof ----------
# Measured on the Mach-O that is about to be signed, never inferred from the ARCHS we passed in:
# xcodebuild accepts that setting and can still hand back a thin binary.
if [ "$DRY_RUN" -eq 1 ]; then
  log "[dry-run] would read CFBundleExecutable and run lipo -archs on $APP_PATH/Contents/MacOS/<executable>,"
  log "[dry-run] failing unless both arm64 and x86_64 are present, and warning about any thin nested library"
else
  exe="$(/usr/libexec/PlistBuddy -c 'Print :CFBundleExecutable' "$APP_PATH/Contents/Info.plist" 2> /dev/null || true)"
  [ -n "$exe" ] || die "no CFBundleExecutable in $APP_PATH/Contents/Info.plist"
  [ -f "$APP_PATH/Contents/MacOS/$exe" ] || die "no executable at $APP_PATH/Contents/MacOS/$exe"
  app_archs="$(lipo -archs "$APP_PATH/Contents/MacOS/$exe" 2> /dev/null || true)"
  log "built Mach-O $exe architectures: ${app_archs:-unreadable}"
  arch_list_has arm64 "${app_archs:-}" ||
    die "the built $APP_NAME has no arm64 slice (lipo -archs: ${app_archs:-unreadable}); a universal DMG needs arm64 and x86_64"
  arch_list_has x86_64 "${app_archs:-}" ||
    die "the built $APP_NAME has no x86_64 slice (lipo -archs: ${app_archs:-unreadable}); a universal DMG needs arm64 and x86_64"
  # Nested libraries have to carry both slices too, or one architecture fails at load time. The core
  # is shipped as dylibs, so this is a real risk rather than a theoretical one.
  while IFS= read -r nested; do
    nested_archs="$(lipo -archs "$nested" 2> /dev/null || true)"
    archs_are_universal "${nested_archs:-}" || warn "nested library is not universal: $nested (${nested_archs:-unreadable})"
  done < <(find "$APP_PATH/Contents" -type f \( -name '*.dylib' -o -name '*.so' \) -print)
fi

# ---------- embed tor ----------
run mkdir -p "$APP_PATH/Contents/Helpers"
run install -m 0755 "$TOR_SOURCE" "$APP_PATH/$TOR_REL_PATH"
# The licence is installed here, before the bundle is signed, so it is sealed together with the binary
# whose notice it is. A build signed for publication and shipped without it would be a redistribution
# that dropped the conditions it redistributes under, so that case stops the build rather than warning
# past it; an ad-hoc test bundle only gets told.
if [ -n "$TOR_LICENSE_SOURCE" ]; then
  run mkdir -p "$(dirname "$APP_PATH/$TOR_LICENSE_REL_PATH")"
  run install -m 0644 "$TOR_LICENSE_SOURCE" "$APP_PATH/$TOR_LICENSE_REL_PATH"
elif [ "$DRY_RUN" -eq 1 ]; then
  log "[dry-run] licence step skipped: a real run installs the asset's own LICENSE, or POPOPX_TOR_LICENSE, to $TOR_LICENSE_REL_PATH"
elif [ -n "$SIGNING_IDENTITY" ]; then
  die "the tor asset carried no licence text, and a Developer ID build must not ship one without it - re-run with POPOPX_TOR_LICENSE='<path to the licence of the version you embedded>'"
else
  warn "no tor licence text was found in the asset: an ad-hoc test bundle is published nowhere, but a release of this binary must carry its licence (POPOPX_TOR_LICENSE, or an asset containing LICENSE)"
fi

# ---------- sign ----------
# Order matters: the helper is signed before the bundle that contains it, because a code directory
# sealed over an unsigned nested binary fails validation afterwards. There is no --deep anywhere: it
# signs whatever it finds, in an order nobody reviewed. Entitlements belong to the app only.
if [ -n "$SIGNING_IDENTITY" ]; then
  helper_sign_args=(--timestamp --options runtime --force --sign "$SIGNING_IDENTITY")
  app_sign_args=("${helper_sign_args[@]}")
  if [ -n "$ENTITLEMENTS" ]; then
    app_sign_args+=(--entitlements "$ENTITLEMENTS")
  fi
  if [ -n "$SIGNING_KEYCHAIN_B64" ]; then
    KEYCHAIN_FILE=/tmp/popopx.keychain
    KEYCHAIN_CREATED=1
    app_sign_args+=(--keychain "$KEYCHAIN_FILE")
    helper_sign_args+=(--keychain "$KEYCHAIN_FILE")
    if [ "$DRY_RUN" -eq 1 ]; then
      printf '%s\n' "    printf '%s' \"\$APPLE_POPOPX_SIGNING_KEYCHAIN\" | base64 --decode -o '$KEYCHAIN_FILE'"
      print_cmd security unlock-keychain -p "" "$KEYCHAIN_FILE"
      print_cmd security list-keychains -s '<existing keychain search list>' "$KEYCHAIN_FILE"
    else
      rm -f "$KEYCHAIN_FILE"
      # The secret is decoded without ever being echoed, so it cannot reach a build log.
      printf '%s' "$SIGNING_KEYCHAIN_B64" | base64 --decode -o "$KEYCHAIN_FILE"
      security unlock-keychain -p "" "$KEYCHAIN_FILE"
      # Adding the keychain to the search list; otherwise codesign finds the certificate but exits
      # with "error: The specified item could not be found in the keychain."
      # shellcheck disable=SC2046 # splitting the list is intentional, as in sign-libs-mac.sh
      security list-keychains -s $(security list-keychains | xargs) "$KEYCHAIN_FILE"
    fi
  fi
  log "signing with identity: $SIGNING_IDENTITY"
else
  helper_sign_args=(--force --sign -)
  app_sign_args=("${helper_sign_args[@]}")
  printf '%s\n' \
    '!! ======================================================================' \
    '!! APPLE_POPOPX_SIGNING_IDENTITY IS NOT SET' \
    '!! This artifact is signed ad-hoc (codesign -s -) and will NOT be notarized.' \
    '!! It is for local testing only: do not publish it, do not attach it to a' \
    '!! release, do not compare it against a published digest. Gatekeeper will' \
    '!! refuse it on any other Mac.' \
    '!! ======================================================================' >&2
  warn "ad-hoc signing: set APPLE_POPOPX_SIGNING_IDENTITY, APPLE_POPOPX_SIGNING_KEYCHAIN and the three APPLE_POPOPX_NOTARIZATION_* variables for a publishable build"
fi

run codesign "${helper_sign_args[@]}" "$APP_PATH/$TOR_REL_PATH"
run codesign "${app_sign_args[@]}" "$APP_PATH"
if [ "$DRY_RUN" -eq 0 ]; then
  print_cmd codesign --verify --strict --verbose=2 "$APP_PATH"
  codesign --verify --strict --verbose=2 "$APP_PATH" || die "codesign rejected $APP_PATH"
fi

# ---------- notarize ----------
# Only for a real signature: an ad-hoc build has no identity to submit under, and a submission that
# merely completed says nothing - the verdict is what has to be Accepted.
notarytool() {
  xcrun notarytool "$@" --apple-id "$NOTARIZATION_APPLE_ID" --password "$NOTARIZATION_PASSWORD" --team-id "$NOTARIZATION_TEAM"
}
if [ -z "$SIGNING_IDENTITY" ]; then
  log "skipping notarization: the artifact is ad-hoc signed, so there is no identity to submit under"
else
  [ -n "$NOTARIZATION_APPLE_ID" ] || die "APPLE_POPOPX_NOTARIZATION_APPLE_ID is not set - required to notarize a signed build"
  [ -n "$NOTARIZATION_PASSWORD" ] || die "APPLE_POPOPX_NOTARIZATION_PASSWORD is not set - required to notarize a signed build"
  SUBMIT_ZIP="$TMP/notarize.zip"
  if [ "$DRY_RUN" -eq 1 ]; then
    log "[dry-run] would notarize the bundle and staple the ticket into it:"
    print_cmd ditto -c -k --keepParent "$APP_PATH" "$SUBMIT_ZIP"
    print_cmd xcrun notarytool submit "$SUBMIT_ZIP" --wait --timeout 1h --output-format json \
      --apple-id '<APPLE_POPOPX_NOTARIZATION_APPLE_ID>' --password '<APPLE_POPOPX_NOTARIZATION_PASSWORD>' --team-id "$NOTARIZATION_TEAM"
    print_cmd xcrun stapler staple "$APP_PATH"
  else
    ditto -c -k --keepParent "$APP_PATH" "$SUBMIT_ZIP"
    log "submitting $APP_NAME for notarization and waiting for Apple's verdict"
    notarytool submit "$SUBMIT_ZIP" --wait --timeout 1h --output-format json > "$TMP/submission.json" || true
    cat "$TMP/submission.json"
    command -v python3 > /dev/null 2>&1 || die "python3 is required to read the notarytool submission result"
    if ! read -r submission_id status < <(python3 -c 'import json, sys; r = json.load(open(sys.argv[1])); print(r["id"], r["status"])' "$TMP/submission.json"); then
      die "could not read the notarytool submission result"
    fi
    if [ "${status:-}" != "Accepted" ]; then
      notarytool log "${submission_id:-}" || true
      die "notarization was not accepted (status: ${status:-unknown}, id: ${submission_id:-unknown}) - the notarytool log is above"
    fi
    log "notarization accepted (id: $submission_id)"
    run xcrun stapler staple "$APP_PATH"
    xcrun stapler validate "$APP_PATH" || die "stapler left no ticket in $APP_PATH"
  fi
fi

# ---------- dmg ----------
DMG_PATH="$OUT_DIR/$DMG_NAME"
STAGE="$TMP/dmg-stage"
if [ "$DRY_RUN" -eq 1 ]; then
  log "[dry-run] would stage the bundle next to an Applications shortcut and create the disk image:"
  print_cmd ditto "$APP_PATH" "$STAGE/$APP_NAME"
  print_cmd ln -s /Applications "$STAGE/Applications"
  print_cmd hdiutil create -volname "$VOL_NAME" -srcfolder "$STAGE" -ov -format UDZO "$DMG_PATH"
  print_cmd shasum -a 256 "$DMG_NAME"
else
  mkdir -p "$OUT_DIR"
  mkdir -p "$STAGE"
  # ditto, not cp: it preserves the sealed resources and the ACLs codesign just wrote.
  ditto "$APP_PATH" "$STAGE/$APP_NAME"
  ln -s /Applications "$STAGE/Applications"
  run hdiutil create -volname "$VOL_NAME" -srcfolder "$STAGE" -ov -format UDZO "$DMG_PATH"
  [ -f "$DMG_PATH" ] || die "hdiutil reported success but $DMG_PATH does not exist"

  # ---------- digests ----------
  # Written from inside the output directory so the recorded name is the file name alone: that is
  # what "shasum -a 256 -c SHA256SUMS" needs to verify a downloaded artifact.
  (cd "$OUT_DIR" && shasum -a 256 "$DMG_NAME" > SHA256SUMS)
  dmg_sha="$(cd "$OUT_DIR" && shasum -a 256 "$DMG_NAME" | cut -d' ' -f1)"
  log "wrote $OUT_DIR/SHA256SUMS"
  printf '%s\n' "artifact: $DMG_PATH"
  printf '%s\n' "sha256:   $dmg_sha"
  if [ -z "$SIGNING_IDENTITY" ]; then
    printf '%s\n' "status:   AD-HOC SIGNED, NOT NOTARIZED - local testing only, do not publish"
  else
    printf '%s\n' "status:   signed with Developer ID and notarized"
  fi
fi

if [ "$DRY_RUN" -eq 1 ]; then
  log "[dry-run] nothing was built, signed or written; the commands above are what a real run executes"
fi
