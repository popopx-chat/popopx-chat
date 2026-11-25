#!/usr/bin/env python3
"""Rewrite the minimum-OS version of every object inside a static archive, in place.

mac2ios sets the platform of an iOS-ified macOS archive but leaves minos/sdk at the host
values, so a target whose deployment version is lower than the host SDK makes ld warn once
per object ("was built for newer 'iOS' version (27.0) than being linked (17.0)").

Members are patched where they stand rather than unpacked, because GHC archives hold flat,
duplicated member names (libHSpopopx-chat-...-ghc9.6.3.a has 312 duplicates): `ar -x` would
overwrite them and the rebuilt archive would quietly lose objects.
"""

import sys

MH_MAGIC = 0xFEEDFACE
MH_MAGIC_64 = 0xFEEDFACF
FAT_MAGIC = 0xCAFEBABE
LC_VERSION_MIN_IPHONEOS = 0x25
LC_VERSION_MIN_IPHONE_SIM = 0x26
LC_VERSION_MIN_MACOSX = 0x24
LC_VERSION_MIN_TVOS = 0x2F
LC_VERSION_MIN_WATCHOS = 0x30
LC_BUILD_VERSION = 0x32

# within the load command: LC_BUILD_VERSION carries minos at +12 and sdk at +16,
# the older LC_VERSION_MIN_<platform> carries version at +8 and sdk at +12
BUILD_VERSION_OFF = (12, 16)
VERSION_MIN_OFF = (8, 12)
VERSION_MIN_CMDS = {
    LC_VERSION_MIN_IPHONEOS,
    LC_VERSION_MIN_IPHONE_SIM,
    LC_VERSION_MIN_MACOSX,
    LC_VERSION_MIN_TVOS,
    LC_VERSION_MIN_WATCHOS,
}


def encode(version):
    major, minor, patch = (version.split(".") + ["0", "0"])[:3]
    return (int(major) << 16) | (int(minor) << 8) | int(patch)


def u32(data, at):
    return int.from_bytes(data[at : at + 4], "little")


def walk_object(data, at, words, edits, stats):
    """Collect the version fields of one Mach-O object starting at `at` into `edits`."""
    magic = u32(data, at)
    if magic == FAT_MAGIC:
        stats["fat"] += 1
        return
    if magic not in (MH_MAGIC, MH_MAGIC_64):
        stats["not_macho"] += 1
        return
    stats["objects"] += 1
    # mach_header and mach_header_64 both put ncmds at +16 and sizeofcmds at +20, and the
    # commands follow the header, whose size differs (24 / 32) between the two
    off, end = (24 if magic == MH_MAGIC else 32), (24 if magic == MH_MAGIC else 32) + u32(data, at + 20)
    for _ in range(u32(data, at + 16)):
        cmd, cmdsize = u32(data, at + off), u32(data, at + off + 4)
        if cmdsize < 8 or off + cmdsize > end:
            stats["bad_cmdsize"] += 1
            return
        fields = BUILD_VERSION_OFF if cmd == LC_BUILD_VERSION else VERSION_MIN_OFF if cmd in VERSION_MIN_CMDS else None
        if fields:
            for field, word in zip(fields, words):
                if u32(data, at + off + field) != word:
                    edits.append((at + off + field, word))
                stats["version_cmds"] += 1
        off += cmdsize


def patch_archive(path, words):
    with open(path, "rb+") as fh:
        data = bytearray(fh.read())
        if bytes(data[:8]) != b"!<arch>\n":
            raise SystemExit(f"{path}: not an ar archive")
        edits, stats = [], dict.fromkeys(
            ("objects", "version_cmds", "symdef", "fat", "not_macho", "bad_cmdsize"), 0
        )
        pos = 8
        while pos + 60 <= len(data):
            head = data[pos : pos + 60].decode("latin-1")
            if head[58:60] != "`\n":
                raise SystemExit(f"{path}: corrupt ar header at {pos}: {head[:16]!r}")
            name, size = head[0:16].rstrip(), int(head[48:58].strip() or 0)
            body = pos + 60
            if name.startswith("#1/"):  # BSD long name: the identifier precedes the payload
                span = int(name[3:])
                name = data[body : body + span].decode("latin-1").rstrip("\x00")
                body, size = body + span, size - span
            if name.startswith(("__.SYMDEF", "%.SYMDEF")):
                stats["symdef"] += 1
            else:
                before = stats["fat"] + stats["not_macho"]
                walk_object(data, body, words, edits, stats)
                if stats["fat"] + stats["not_macho"] > before:
                    print(f"{path}: {name}: not a thin 64-bit Mach-O, left alone", file=sys.stderr)
            pos = body + size + size % 2
        for at, word in edits:
            fh.seek(at)
            fh.write(word.to_bytes(4, "little"))
        print(
            f"{path}: size={len(data)} objects={stats['objects']} version_cmds={stats['version_cmds']} "
            f"fields_written={len(edits)} symdef={stats['symdef']} fat={stats['fat']} "
            f"not_macho={stats['not_macho']} bad_cmdsize={stats['bad_cmdsize']}"
        )
        return stats["fat"] + stats["not_macho"] + stats["bad_cmdsize"]


def main(argv):
    if len(argv) < 2:
        print("usage: set-minos.py <version> <archive> [archive ...]", file=sys.stderr)
        return 2
    problems = sum(patch_archive(path, (encode(argv[0]),) * 2) for path in argv[1:])
    return 1 if problems else 0


if __name__ == "__main__":
    sys.exit(main(sys.argv[1:]))
