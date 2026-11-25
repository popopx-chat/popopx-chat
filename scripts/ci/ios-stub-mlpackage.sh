#!/bin/sh

# Places a minimal valid CoreML model package where the app target expects
# POPOPXAntiSpyDetector.mlpackage, but only when nothing is there yet.
#
# The pretrained model is built offline by scripts/setup_pretrained_coreml.py and stays out of
# git (apps/ios/.gitignore), while project.pbxproj keeps it in the Sources phase, so a clean
# checkout otherwise fails CoreML code generation with
# "coremlc: error: Model does not exist at ...".
#
# The fixture is a 1x1x1 Float32 identity model. Nothing in the app links against generated
# model code: PopopxCameraGuardEngine loads the compiled resource by name through
# MLModel(contentsOf:), so a stub that only satisfies the compiler is enough. An existing
# model, real or already stubbed, is never overwritten.
# Run from repo root on macOS.

set -eu

SRC=scripts/ci/fixtures/POPOPXAntiSpyDetector.mlpackage
DEST=apps/ios/Shared/Features/SecureEphemeral/POPOPXAntiSpyDetector.mlpackage

if [ -e "$DEST" ]; then
    echo "$DEST already present"
    exit 0
fi

if [ ! -d "$SRC" ]; then
    echo "Error: stub fixture not found at $SRC" >&2
    exit 1
fi

mkdir -p "$(dirname "$DEST")"
cp -R "$SRC" "$DEST"
echo "$DEST"
