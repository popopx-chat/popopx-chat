#!/bin/bash

# Builds mac2ios, runs scripts/ios/prepare.sh on ~/Downloads/pkg-ios-aarch64-swift-json.zip,
# and fails unless every object in apps/ios/Libraries/sim is marked for the iOS simulator and
# every object in both slices carries the deployment target as its minos.

set -euo pipefail

mac2ios_rev=4dcb77d5ea896d749381806dfab5358851b08951
tools=$(mktemp -d)
for f in mac2ios.c ar.h macho.h; do
  curl --proto '=https' --tlsv1.2 -sSfL -o "$tools/$f" "https://raw.githubusercontent.com/zw3rk/mobile-core-tools/$mac2ios_rev/$f"
done
cc -O2 -o "$tools/mac2ios" "$tools/mac2ios.c"

PATH="$tools:$PATH" scripts/ios/prepare.sh

for f in apps/ios/Libraries/sim/*.a; do
  echo "$f: $(du -h "$f" | cut -f1), $(lipo -info "$f")"
  platforms=$({ otool -l "$f" || true; } | awk '$1 == "platform" {print $2}' | sort | uniq -c)
  echo "${platforms:-  no LC_BUILD_VERSION found}"
  if echo "$platforms" | awk 'NF {print $2}' | grep -vE '^(7|IOSSIMULATOR)$' > /dev/null; then
    echo "error: $f has objects for a platform other than the iOS simulator"
    exit 1
  fi
done

# scripts/ios/prepare.sh pins every object's minos to the deployment target, because mac2ios
# leaves it at the host build's value and ld then warns once per object. Same default, so a
# silent regression here fails the job instead of shipping a noisy archive.
IOS_MINOS=${IOS_MINOS:-17.0}
for f in apps/ios/Libraries/ios/*.a apps/ios/Libraries/sim/*.a; do
  versions=$({ otool -l "$f" || true; } | awk '$1 == "minos" {print $2}' | sort | uniq -c | tr '\n' ' ')
  echo "$f minos: ${versions:-  no LC_BUILD_VERSION found}"
  if echo "$versions" | awk 'NF {print $2}' | grep -v "^${IOS_MINOS}$" > /dev/null; then
    echo "error: $f has objects whose minos is not ${IOS_MINOS}"
    exit 1
  fi
done
