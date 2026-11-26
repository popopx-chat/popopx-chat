#!/usr/bin/env bash
# scripts/ci/check-smp-links.sh
# Automated compliance gate: prevents bare popopx.im domain URLs from entering the codebase.
#
# The POPOPX infrastructure uses subdomain-specific addresses (smp1.popopx.im, relay1.popopx.im,
# xftp1.popopx.im, ntf1.popopx.im, stun1.popopx.im, etc.) with full contact/group/channel paths
# (/a#..., /g#..., /r#...) and key parameters (?c=...). A bare https://popopx.im or http://popopx.im
# URL has no A record and will fail to resolve, breaking deep links and contact connections.
#
# This script scans src/, apps/, .github/ and the root documents for violations and exits 1 if any
# are found.
# Legitimate uses (domain suffix matching like ".popopx.im", configuration arrays like
# serverDomains = ["popopx.im"], and comments/documentation) are excluded.

set -euo pipefail

REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
cd "$REPO_ROOT"

# File extensions to scan
EXTENSIONS=("swift" "kt" "hs" "ts" "js" "py" "md" "json" "yml" "yaml")

# Build find pattern for extensions: -name needs one test per extension, ORed.
# A comma-joined single pattern ("*.a,*.b") matches nothing, so `find` returns no
# files and the scan silently reports zero violations.
FIND_ARGS=()
for ext in "${EXTENSIONS[@]}"; do
  if [ ${#FIND_ARGS[@]} -eq 0 ]; then
    FIND_ARGS+=(-name "*.$ext")
  else
    FIND_ARGS+=(-o -name "*.$ext")
  fi
done

# Directories to scan
SCAN_DIRS=("src" "apps" ".github")

# Root documents, scanned by name: they sit outside SCAN_DIRS, and README.md/PRIVACY.md carry the
# published addresses, so the no-bare-domain rule has to cover them too.
SCAN_FILES=("README.md" "README.zh-Hans.md" "PRIVACY.md" "PRIVACY-POPOPX.md")

# Temporary file for violations
VIOLATIONS=$(mktemp)
trap 'rm -f "$VIOLATIONS"' EXIT

violation_count=0

check_file() {
  local file="$1"

  # Search for bare popopx.im URLs (https://popopx.im or http://popopx.im not followed by subdomain)
  # Pattern matches: https://popopx.im or http://popopx.im at end of string or followed by / or ? or #
  # but NOT followed by a subdomain pattern like smp1., relay1., xftp1., ntf1., stun1., etc.
  if grep -nE 'https?://popopx\.im(/|\?|#|$)' "$file" > /dev/null 2>&1; then
    # Found a potential violation - extract the lines
    while IFS=: read -r line_num line_content; do
      # Skip if it's in a comment explaining the rule
      if [[ "$line_content" == *"bare popopx.im"* ]] || \
         [[ "$line_content" == *"naked popopx.im"* ]] || \
         [[ "$line_content" == *"domain suffix"* ]]; then
        continue
      fi

      # Skip if it's a legitimate configuration value (serverDomains, admittedHostnameSuffixes, etc.)
      if [[ "$line_content" == *'serverDomains'* ]] || \
         [[ "$line_content" == *'admittedHostnameSuffixes'* ]] || \
         [[ "$line_content" == *'domains:'* ]] || \
         [[ "$line_content" == *'presetDomains'* ]]; then
        continue
      fi

      # This is a violation
      echo "$file:$line_num:$line_content" >> "$VIOLATIONS"
      violation_count=$((violation_count + 1))
    done < <(grep -nE 'https?://popopx\.im(/|\?|#|$)' "$file" 2>/dev/null || true)
  fi
}

for dir in "${SCAN_DIRS[@]}"; do
  if [ ! -d "$dir" ]; then
    continue
  fi

  # Find files matching extensions, excluding build artifacts
  while IFS= read -r -d '' file; do
    # Skip build artifacts and dependencies
    if [[ "$file" == *"/node_modules/"* ]] || \
       [[ "$file" == *"/.build/"* ]] || \
       [[ "$file" == *"/dist-newstyle/"* ]] || \
       [[ "$file" == *"/DerivedData/"* ]] || \
       [[ "$file" == *"/build/"* ]]; then
      continue
    fi

    check_file "$file"
  done < <(find "$dir" -type f \( "${FIND_ARGS[@]}" \) -print0 2>/dev/null)
done

for file in "${SCAN_FILES[@]}"; do
  if [ -f "$file" ]; then
    check_file "$file"
  fi
done

# Report results
if [ $violation_count -gt 0 ]; then
  echo "❌ BARE POPOPX.IM URL VIOLATIONS FOUND: $violation_count"
  echo ""
  echo "The following files contain bare 'https://popopx.im' or 'http://popopx.im' URLs"
  echo "without proper subdomain (smp1., relay1., xftp1., ntf1., stun1., etc.) and path parameters."
  echo "These URLs will fail to resolve because popopx.im has no A record."
  echo ""
  echo "Violations:"
  cat "$VIOLATIONS"
  echo ""
  echo "Fix: Replace bare 'https://popopx.im' with full SMP address like:"
  echo "  'https://smp1.popopx.im/a#<contact-key>?c=<public-key>'"
  echo ""
  exit 1
else
  echo "✅ No bare popopx.im URL violations found."
  echo "All popopx.im references use proper subdomain addresses."
  exit 0
fi
