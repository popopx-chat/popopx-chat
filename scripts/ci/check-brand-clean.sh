#!/usr/bin/env bash
# scripts/ci/check-brand-clean.sh
# Brand compliance gate: ensures no 'simplex' branding remains in our codebase
# except where legally required (AGPL-3.0) or technically necessary (wire protocol,
# backward compatibility, upstream references).
#
# Exits 0 if clean, 1 if violations found.

set -euo pipefail

REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
cd "$REPO_ROOT"

# Single-pass grep for 'simplex' (case-insensitive) across all source files,
# then filter out B-class (legal) and C-class (compatibility) exceptions.

grep -rnI -i "simplex" \
  --include="*.hs" --include="*.swift" --include="*.kt" --include="*.java" \
  --include="*.ts" --include="*.js" --include="*.py" --include="*.sh" \
  --include="*.yml" --include="*.yaml" --include="*.json" --include="*.md" \
  --include="*.toml" --include="*.xml" --include="*.plist" --include="*.nix" \
  --include="*.cabal" --include="*.css" --include="*.html" --include="*.gradle.kts" \
  --exclude-dir=.git --exclude-dir=.venv_coreml --exclude-dir=dist-newstyle \
  --exclude-dir=node_modules --exclude-dir=DerivedData --exclude-dir=.build \
  --exclude-dir=_build --exclude-dir=bots --exclude-dir=licences \
  --exclude="LICENSE" --exclude="FORK.md" --exclude="CHANGELOG.md" \
  --exclude="PRIVACY.md" --exclude="PRIVACY-POPOPX.md" \
  --exclude="TRADEMARK.md" --exclude="TRADEMARK-POPOPX.md" \
  --exclude="AGPL-COMPLIANCE.md" \
  --exclude="NODE-PACKAGES-POPOPX.md" \
  --exclude="check-brand-clean.sh" \
  . 2>/dev/null | \
grep -v '\.strings:' | \
grep -v '\.xliff:' | \
grep -v '\.lproj/' | \
grep -viE 'copyright.*simplex|simplex.*copyright' | \
grep -v 'uses:.*simplex-chat/' | \
grep -v 'github\.com/simplex-chat/' | \
grep -v 'raw\.githubusercontent\.com/simplex-chat/' | \
grep -v 'simplex-chat/cla' | \
grep -v 'simplex-chat/simplex-chat' | \
grep -vE '\.simplex\.im|simplex\.im:' | \
grep -vE 'badges\.simplex\.chat|simplex\.domains|simplex\.chat/blog|simplex\.chat/contact|simplex\.chat/invitation' | \
grep -vE 'OTSimplex|operatorTag.*"simplex"|simplex_domain_v1|SimpleXCallMediaKey|"SimpleX badge"' | \
grep -vE 'm20260603_simplex|down_m20260603_simplex|simplex_is_valid_text|simplexonflux|20260603_simplex_name' | \
grep -vE 'simplexchat:|simplex:/|simplex://|legacyAppLinkScheme|LEGACY_BADGE_LINK' | \
grep -vE 'SIMPLEX_ASSETS|SIMPLEX_LIBS_DIR|SIMPLEX_ADDON_PATH|SIMPLEX_DOMAINS' | \
grep -vE 'libsimplex\.(so|dylib|dll)' | \
grep -vE 'android:scheme="simplexchat"|android:host=".*simplex\.im"' | \
grep -v 'simplex-chat/WebRTC' | \
grep -viE '^\./[^:]+:[0-9]+:\s*(--|//|#|\*)' | \
grep -vE '"SimpleX Messaging Protocol"|"SimpleX Chat Ltd"|"SimpleX network"|"SimpleX approach"|"SimpleX Platform"' | \
grep -v 'SimpleX Messaging Protocol\|SimpleX Chat Ltd\|SimpleX network\|SimpleX approach\|SimpleX Platform' | \
grep -v 'contentModerationPostLink\|simplex-network-large-groups' | \
grep -v 'Ask SimpleX Team\|SimpleX news' | \
grep -vE '"/simplex"|highlight "/simplex"|ConnectSimplex' | \
grep -vE '"SimpleX Chat"|"SimpleX"' | \
grep -vE '^\./README\.md:' | \
grep -viE '^\./[^:]+\.cabal:[0-9]+:.*(author|copyright|homepage):' | \
grep -v 'simplex-chat badge sign\|simplex-chat badge \.\.\.' | \
grep -v 'install\.sh.*simplex-chat' | \
grep -vE '^\./tests/tmp/' | \
grep -vE '^\./tests/MarkdownTests\.hs:' | \
grep -vE '^\./tests/ChatTests/.*linkPreview' | \
grep -vE '^\./tests/ProtocolTests\.hs:.*\\?"SimpleX Chat\\?"' | \
grep -vE '^\./tests/ChatTests/Direct\.hs:.*\(simplex\)' | \
grep -vE 'simplex-cors\.conf|slSimplexScheme|simplexLinkFormat' | \
grep -vE 'SimpleX Broadcast bot|simplex-badges-test' | \
grep -vE '^\./install\.sh:.*\.simplex/' | \
grep -vE '^\./install\.sh:.*SimpleX Chat database' | \
grep -vE '^\./media-logos/README\.md:' | \
grep -vE '^\./scripts/prices/' | \
grep -vE '^\./scripts/ci/desktop-linux/release-app\.sh:.*/opt/simplex|simplex-desktop-ubuntu' | \
grep -vE '^\./packages/' | \
grep -vE '^\./scripts/flatpak/.*metainfo\.xml:.*<(p|li|image)>' | \
grep -vE '^\./scripts/(android|popopx-chat-reproduce-builds-android)' | \
grep -vE '^\./scripts/ci/android/' | \
grep -vE 'server_operator_tag = .simplex.' | \
grep -vE 'x-scheme-handler/simplexchat' | \
grep -vE '^\./scripts/desktop/build-lib-.*\.sh:.*lib:simplex-chat' | \
grep -vE '^\./scripts/ios/(download-libs|export-localizations|import-localizations)' | \
grep -vE '^\./scripts/ios/(localizations|test_localizations)\.py:' | \
grep -vE '^\./scripts/ci/preset-domain-invariant\.py:' | \
grep -vE '^\./apps/ios/(spec|Docs|safe_prompt.*\.md|product/views|POPOPX\.xcodeproj/xcuserdata)' | \
grep -vE '^\./apps/multiplatform/spec/' | \
grep -vE '\.xcschememanagement\.plist:' | \
grep -vE 'chat\.simplex\.app\.views' | \
grep -vE '^\./src/Popopx/Chat/Help\.hs:.*/simplex incognito' | \
grep -vE '^\./src/Popopx/Chat/protocol\.md:' | \
grep -vE '^\./\.github/.*uses: simplex-chat/' | \
grep -vE '^\./\.github/workflows/cla\.yml:' | \
grep -vE '^\./\.github/release_body\.md:' | \
grep -vE '^\./\.github/CODEOWNERS:' | \
grep -vE "^\./\.github/workflows/build\.yml:.*!= 'simplex-chat/simplex-chat'" | \
grep -vE '^\./\.github/workflows/desktop-linux\.yml:.*(UI_CONFIG_DIR|UI_WINDOW_RE|app/simplex|app/opt/simplex)' | \
grep -vE '^\./\.github/workflows/android-emu\.yml:.*simplex-aarch64\.apk' | \
grep -vE 'ASSETS_LICENSE\.md:' | \
grep -vE '^\./apps/ios/.*\.md:' | \
grep -vE '^\./apps/multiplatform/(product|README)\.md:' | \
grep -vE '^\./apps/multiplatform/.*/build/' | \
grep -vE '^\./apps/multiplatform/release/' | \
grep -vE '^\./apps/ios/POPOPX--iOS--Info\.plist:' | \
grep -vE '^\./apps/multiplatform/common/src/commonMain/moko-resources/' | \
grep -vE '^\./apps/multiplatform/desktop/build\.gradle\.kts:.*simplexchat' | \
grep -vE '^\./apps/multiplatform/desktop/src/jvmMain/resources/distribute/.*\.xml:.*simplex-desktop' | \
grep -vE '^\./apps/ios/Shared/Features/AddFriend/PopopxAddFriendView\.swift:.*simplex\.chat' | \
grep -vE '^\./apps/ios/Shared/Views/Chat/ChatItem/FramedItemView\.swift:.*chaT@simplex\.chat' | \
grep -vE '^\./apps/ios/Shared/Views/UserSettings/UserAddressLearnMore\.swift:.*simplex-contact-addresses' | \
grep -vE '^\./apps/ios/Shared/ContentView\.swift:.*simplexchat' | \
grep -vE '^\./apps/ios/POPOPX Snapshots/SnapshotTests\.swift:.*"SimpleX Chat|stun:simplex\.im' | \
grep -vE '^\./apps/multiplatform/common/src/commonMain/kotlin/chat/popopx/common/views/usersettings/UserAddressLearnMore\.kt:.*simplex-contact-addresses' | \
grep -vE '^\./apps/multiplatform/common/src/desktopTest/kotlin/chat/popopx/app/ServerOperatorsWireTest\.kt:' | \
grep -vE '^\./apps/multiplatform/product/.*\.md:' | \
grep -vE '^\./apps/ios/Shared/Model/AppAPITypes\.swift:.*case simplex|\.simplex:|operatorTag: \.simplex' | \
grep -vE '^\./apps/multiplatform/common/src/commonMain/kotlin/chat/popopx/common/model/PopopxAPI\.kt:.*SIMPLEX|simplex\.im' \
> /tmp/brand-violations.txt || true

violations=$(wc -l < /tmp/brand-violations.txt | tr -d ' ')

if [ "$violations" -gt 0 ]; then
  echo "❌ BRAND COMPLIANCE FAILED: $violations violation(s) found"
  echo ""
  echo "Violations:"
  cat /tmp/brand-violations.txt
  echo ""
  echo "Please rename them to 'popopx' or update exclusion patterns in this script."
  rm -f /tmp/brand-violations.txt
  exit 1
else
  total=$(grep -rnI -i "simplex" \
    --include="*.hs" --include="*.swift" --include="*.kt" --include="*.java" \
    --include="*.ts" --include="*.js" --include="*.py" --include="*.sh" \
    --include="*.yml" --include="*.yaml" --include="*.json" --include="*.md" \
    --include="*.toml" --include="*.xml" --include="*.plist" --include="*.nix" \
    --include="*.cabal" --include="*.css" --include="*.html" --include="*.gradle.kts" \
    --exclude-dir=.git --exclude-dir=.venv_coreml --exclude-dir=dist-newstyle \
    --exclude-dir=node_modules --exclude-dir=DerivedData --exclude-dir=.build \
    --exclude-dir=_build --exclude-dir=bots --exclude-dir=licences \
    . 2>/dev/null | wc -l | tr -d ' ')
  echo "✅ Brand compliance check passed."
  echo "   ($total total 'simplex' references found, all covered by exclusion patterns)"
  rm -f /tmp/brand-violations.txt
  exit 0
fi
