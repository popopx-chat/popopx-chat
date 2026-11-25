#!/bin/sh

set -e

# the binaries folder should be in ~/Downloads folder
rm -rf ./apps/ios/Libraries/mac ./apps/ios/Libraries/ios ./apps/ios/Libraries/sim
mkdir -p ./apps/ios/Libraries/mac ./apps/ios/Libraries/ios ./apps/ios/Libraries/sim
unzip -o ~/Downloads/pkg-ios-aarch64-swift-json.zip -d ./apps/ios/Libraries/mac
chmod +w ./apps/ios/Libraries/mac/*
cp ./apps/ios/Libraries/mac/* ./apps/ios/Libraries/ios
cp ./apps/ios/Libraries/mac/* ./apps/ios/Libraries/sim
for f in ./apps/ios/Libraries/ios/*; do mac2ios $f; done | wc -l
for f in ./apps/ios/Libraries/sim/*; do mac2ios -s $f; done | wc -l

# mac2ios rewrites LC_BUILD_VERSION's platform only: minos and sdk keep the host build's
# values, so every object claims the macOS SDK version and ld warns once per object while
# linking against a lower deployment target. Keep this in step with IPHONEOS_DEPLOYMENT_TARGET.
IOS_MINOS=${IOS_MINOS:-17.0}
python3 ./scripts/ios/set-minos.py "$IOS_MINOS" ./apps/ios/Libraries/ios/*.a ./apps/ios/Libraries/sim/*.a
