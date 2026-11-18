#!/usr/bin/env python3
"""Measure WCAG 2.1 contrast for the popopx dual-mode palette in
apps/ios/Shared/Theme/PopopxTheme.swift, and print the table that
apps/ios/Docs/popopx-brand-spec.md quotes.

Re-derive with:  python3 Docs/contrast_check.py
Text rows must reach 4.5 (AA); rows marked NONTEXT are UI-component checks
against 3.0 (WCAG 1.4.11) and are printed separately.
"""

def chan(c):
    c = c / 255.0
    return c / 12.92 if c <= 0.04045 else ((c + 0.055) / 1.055) ** 2.4

def lum(hexstr):
    h = hexstr.lstrip("#")
    r, g, b = (int(h[i:i + 2], 16) for i in (0, 2, 4))
    return 0.2126 * chan(r) + 0.7152 * chan(g) + 0.0722 * chan(b)

def ratio(fg, bg):
    a, b = lum(fg), lum(bg)
    hi, lo = (a, b) if a >= b else (b, a)
    return (hi + 0.05) / (lo + 0.05)

def grade(r, need):
    if r >= 7.0:
        return "AAA"
    if r >= need:
        return "AA"
    if r >= 3.0:
        return "AA-large only"
    return "FAIL"

TEXT = [
    # (mode, foreground, background, role)
    ("L", "#FFFFFF", "#5856D6", "onBrand on brand (primary CTA)"),
    ("L", "#FFFFFF", "#D70015", "onDanger on dangerFill (destructive CTA)"),
    ("L", "#00251F", "#00A896", "onMesh on mesh (mesh CTA / hop chip)"),
    ("L", "#111114", "#FFFFFF", "label on card"),
    ("L", "#111114", "#F2F2F7", "label on base"),
    ("L", "#5A5A66", "#FFFFFF", "labelSecondary on card"),
    ("L", "#5A5A66", "#F2F2F7", "labelSecondary on base"),
    ("L", "#8A8A94", "#FFFFFF", "labelHint on card (disabled/placeholder)"),
    ("L", "#D70015", "#FFFFFF", "dangerInk on card"),
    ("L", "#5856D6", "#FFFFFF", "brand as text on card"),
    ("D", "#0A0A1F", "#7D7AFF", "onBrand on brand (primary CTA)"),
    ("D", "#0A0A1F", "#FF453A", "onDanger on dangerFill (destructive CTA)"),
    ("D", "#00211C", "#00D2B8", "onMesh on mesh (mesh CTA / hop chip)"),
    ("D", "#F4F4F6", "#1C1C1E", "label on card"),
    ("D", "#F4F4F6", "#000000", "label on base"),
    ("D", "#F4F4F6", "#2C2C2E", "label on cardHigh (sheet/toast)"),
    ("D", "#A6A6B0", "#1C1C1E", "labelSecondary on card"),
    ("D", "#A6A6B0", "#2C2C2E", "labelSecondary on cardHigh"),
    ("D", "#7C7C88", "#1C1C1E", "labelHint on card (disabled/placeholder)"),
    ("D", "#FF453A", "#1C1C1E", "dangerInk on card"),
    ("D", "#00D2B8", "#1C1C1E", "meshInk on card"),
    ("D", "#7D7AFF", "#1C1C1E", "brand as text on card"),
    ("L", "#07240F", "#34C759", "onSuccess on success (success flash CTA)"),
    ("D", "#071A0C", "#30D158", "onSuccess on success (success flash CTA)"),
    ("L", "#1E7A34", "#FFFFFF", "successInk on card (tick / icon)"),
    ("L", "#1E7A34", "#F2F2F7", "successInk on base"),
    ("D", "#30D158", "#1C1C1E", "successInk on card (tick / icon)"),
    ("D", "#30D158", "#2C2C2E", "successInk on cardHigh (toast)"),
    ("L", "#111114", "#E3E4EA", "neutral icon badge ink on its fill"),
    ("D", "#F4F4F6", "#38383B", "neutral icon badge ink on its fill"),
]

NONTEXT = [
    ("L", "#5856D6", "#FFFFFF", "brand fill / stroke on card"),
    ("L", "#5856D6", "#F2F2F7", "brand as UI on base"),
    ("D", "#7D7AFF", "#000000", "brand fill on base"),
    ("L", "#00A896", "#FFFFFF", "mesh fill alone on card (see rule: needs ink)"),
    ("L", "#00705F", "#FFFFFF", "meshInk stroke on card"),
    ("D", "#00D2B8", "#1C1C1E", "mesh as UI on card"),
    ("D", "#00D2B8", "#000000", "mesh as UI on base"),
    ("L", "#FF3B30", "#FFFFFF", "danger icon on card"),
    ("D", "#FF453A", "#1C1C1E", "danger icon on card"),
    ("L", "#34C759", "#FFFFFF", "success fill alone on card (see rule: needs ink)"),
    ("L", "#1E7A34", "#FFFFFF", "successInk stroke on card"),
    ("D", "#30D158", "#000000", "success as UI on base"),
]

print("TEXT (AA target 4.5:1)   [L = light mode, D = dark mode]")
for mode, fg, bg, role in TEXT:
    r = ratio(fg, bg)
    print("  %s %-40s %s on %s  %5.2f  %s" % (mode, role, fg, bg, r, grade(r, 4.5)))

print("\nNON-TEXT UI components (target 3.0:1)")
for mode, fg, bg, role in NONTEXT:
    r = ratio(fg, bg)
    print("  %s %-40s %s on %s  %5.2f  %s" % (mode, role, fg, bg, r, grade(r, 3.0)))

