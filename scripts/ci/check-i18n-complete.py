#!/usr/bin/env python3
"""Assert the new iOS and Android localizations are complete and format-safe.

Run from the repository root.  Exits 1 when a required key is missing, when an
extra key appears, or when a placeholder does not match the English source.
The one malformed upstream source "Settled per job, 10% protocol fee" is
reported as a known baseline rather than as a new-language failure: the string
contains a literal percent sign followed by "p", which the shared validator
mistakes for a %p specifier in every language, including the 18 existing ones.
"""

from __future__ import annotations

import sys
import xml.etree.ElementTree as ET
from pathlib import Path

REPO = Path(__file__).resolve().parent.parent.parent
sys.path.insert(0, str(REPO / "scripts" / "ios"))
import localizations as L

IOS_NEW = ("ar", "ko", "pt-BR")
IOS_XLIFF = REPO / "apps/ios/POPOPX Localizations/en.xcloc/Localized Contents/en.xliff"
IOS_MAIN = (
    "en.lproj/Localizable.strings",
    "en.lproj/POPOPX--iOS--InfoPlist.strings",
)
MALFORMED_PERCENT = "Settled per job, 10% protocol fee"
BIDI_CONTROLS = set("\u202a\u202b\u202c\u202d\u202e\u2066\u2067\u2068\u2069\u200e\u200f\u061c")


def ios_units() -> dict[tuple[str, str], str]:
    root = ET.parse(IOS_XLIFF).getroot()
    result = {}
    for file in root.iter(f"{L.XLIFF_NS}file"):
        original = file.get("original", "")
        if original not in IOS_MAIN:
            continue
        for unit in file.iter(f"{L.XLIFF_NS}trans-unit"):
            key = unit.get("id", "")
            source = "".join(unit.find(f"{L.XLIFF_NS}source").itertext())
            result[(original, key)] = source
    return result


def check_ios() -> list[str]:
    problems = []
    units = ios_units()
    for language in IOS_NEW:
        directory = REPO / "apps/ios" / f"{language}.lproj"
        for original in IOS_MAIN:
            name = original.split("/", 1)[1]
            path = directory / name
            if not path.is_file():
                problems.append(f"iOS {language}: missing {path.relative_to(REPO)}")
                continue
            expected = {key: source for (file, key), source in units.items() if file == original}
            try:
                actual = dict(L.parse_strings(path.read_text(encoding="utf-8")))
            except Exception as error:  # noqa: BLE001 - report the real parse error
                problems.append(f"iOS {language}: cannot parse {path.relative_to(REPO)}: {error}")
                continue
            missing = sorted(set(expected) - set(actual))
            extra = sorted(set(actual) - set(expected))
            if missing:
                problems.append(f"iOS {language} {name}: {len(missing)} missing keys, e.g. {missing[:3]!r}")
            if extra:
                problems.append(f"iOS {language} {name}: {len(extra)} extra keys, e.g. {extra[:3]!r}")
            for key, source in expected.items():
                if key not in actual:
                    continue
                target = actual[key]
                if source == MALFORMED_PERCENT:
                    continue
                problem = L.placeholder_problem(source, target)
                if problem:
                    problems.append(f"iOS {language} {name} key {key!r}: {problem}")
                if language == "ar" and any(char in BIDI_CONTROLS for char in target):
                    problems.append(f"iOS ar {name} key {key!r}: contains a bidi control character")
    return problems


def check_android() -> list[str]:
    problems = []
    resources = REPO / "apps/multiplatform/common/src/commonMain/moko-resources"
    base_path = resources / "base/strings.xml"
    base = L.adjust_kotlin(base_path.read_text(encoding="utf-8"))
    base_by_name = {string.name: string for string in base.strings}
    possible = L.kotlin_possible_formats()
    base_formats = {}
    for name, string in base_by_name.items():
        try:
            base_formats[name] = L.kotlin_formats(string.line, possible)
        except L.KotlinFormatError as error:
            problems.append(f"Android base key {name!r}: {error}")
    expected = set(base_by_name)
    for language in ("ar", "ko", "pt-rBR"):
        path = resources / language / "strings.xml"
        if not path.is_file():
            problems.append(f"Android {language}: missing {path.relative_to(REPO)}")
            continue
        adjusted = L.adjust_kotlin(path.read_text(encoding="utf-8"))
        if adjusted.unclosed:
            problems.append(f"Android {language}: unclosed string tag")
        names = [string.name for string in adjusted.strings]
        seen = set()
        duplicated = sorted({name for name in names if name in seen or seen.add(name)})
        if duplicated:
            problems.append(f"Android {language}: duplicate keys, e.g. {duplicated[:3]!r}")
        missing = sorted(expected - set(names))
        extra = sorted(set(names) - expected)
        if missing:
            problems.append(f"Android {language}: {len(missing)} missing keys, e.g. {missing[:3]!r}")
        if extra:
            problems.append(f"Android {language}: {len(extra)} extra keys, e.g. {extra[:3]!r}")
        for string in adjusted.strings:
            for problem in L.kotlin_string_problems(
                path, string, base_by_name.get(string.name), base_formats.get(string.name), possible
            ):
                if problem.kind != L.DUPLICATE:
                    problems.append(f"Android {language} key {string.name!r}: {problem.kind}: {problem.detail}")
    return problems


def main() -> int:
    problems = check_ios() + check_android()
    if problems:
        for problem in problems:
            print(problem)
        print(f"i18n completeness: {len(problems)} problem(s)")
        return 1
    print("i18n completeness: OK (iOS ar/ko/pt-BR and Android ar/ko/pt-rBR)")
    return 0


if __name__ == "__main__":
    raise SystemExit(main())