#!/bin/bash

set -euo pipefail

cd "$(dirname "$0")/../.."

case "${1:-}" in
  badge-web)
    (cd apps/popopx-badge-service/web && npm ci && npm test)
    ;;
  ci-scripts)
    python3 scripts/ci/test_packages_release.py
    ;;
  mcp)
    (cd packages/popopx-chat-client/types/typescript && npm install --no-audit --no-fund && npx tsc)
    (cd packages/popopx-chat-nodejs && npm install --ignore-scripts --no-save --no-audit --no-fund ../popopx-chat-client/types/typescript && npx tsc && cp src/simplex.* dist)
    # Test the native backend this job built instead of the one published in popopx-chat-libs.
    # An override naming a missing path raises instead of falling back (libs.ts resolve*), so
    # each one is exported only when the artifact it points at exists.
    nodejs_dir=$PWD/packages/popopx-chat-nodejs
    if [ -f "$nodejs_dir/build/Release/popopx.node" ]; then
      export POPOPX_ADDON_PATH="$nodejs_dir/build/Release/popopx.node"
    fi
    for libs_dir in release-libs/popopx-chat-libs-linux-*/libs; do
      if [ -d "$libs_dir" ]; then
        export POPOPX_LIBS_DIR="$PWD/$libs_dir"
        break
      fi
    done
    cd packages/popopx-chat-mcp
    npm ci --no-audit --no-fund
    npm install --no-save --no-audit --no-fund ../popopx-chat-nodejs ../popopx-chat-client/types/typescript
    npx tsc
    npx tsc -p test/tsconfig.json --noEmit
    npm test
    npm run test:e2e
    ;;
  *)
    echo "usage: $0 badge-web | ci-scripts | mcp" >&2
    exit 1
    ;;
esac
