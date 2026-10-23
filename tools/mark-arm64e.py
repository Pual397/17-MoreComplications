#!/usr/bin/env python3
"""
Mark a Mach-O binary as arm64e by setting cpusubtype = CPU_SUBTYPE_ARM64E (2).

Why this exists: the Linux toolchain used to build this package (Ubuntu's
ld64.lld 18) emits arm64 for BOTH slices, so a real arm64e slice cannot be
produced here. iOS refuses to load an arm64 image into an arm64e process
(dyld: "have 'arm64', need 'arm64e'"), which is what broke the preference
bundle in Settings.

The instructions themselves are plain arm64, which an arm64e CPU executes
fine; only the header tag is wrong. This script retags the header (and the
fat-arch entry, when present). It is a workaround, not a real arm64e build --
re-sign afterwards, the code signature covers these header fields.

Usage: mark-arm64e.py <macho-file> [...]
"""
import struct
import sys

CPU_TYPE_ARM64 = 0x0100000C
CPU_SUBTYPE_ARM64E = 2

MH_MAGIC_64 = 0xFEEDFACF
FAT_MAGIC = 0xCAFEBABE
FAT_MAGIC_64 = 0xCAFEBABF


def patch_slice(data, mach_offset):
    magic = struct.unpack_from('<I', data, mach_offset)[0]
    if magic != MH_MAGIC_64:
        raise ValueError('not a 64-bit Mach-O at offset %d (magic 0x%x)' % (mach_offset, magic))
    cputype = struct.unpack_from('<i', data, mach_offset + 4)[0]
    cpusub = struct.unpack_from('<I', data, mach_offset + 8)[0]
    if cputype != CPU_TYPE_ARM64:
        raise ValueError('slice is not arm64 (cputype 0x%x)' % cputype)
    struct.pack_into('<I', data, mach_offset + 8, CPU_SUBTYPE_ARM64E)
    return cputype, cpusub


def patch(path):
    with open(path, 'rb') as handle:
        data = bytearray(handle.read())

    magic_be = struct.unpack_from('>I', data, 0)[0]
    magic_le = struct.unpack_from('<I', data, 0)[0]
    before = []

    if magic_be in (FAT_MAGIC, FAT_MAGIC_64):
        count = struct.unpack_from('>I', data, 4)[0]
        entry = 20 if magic_be == FAT_MAGIC else 32
        for index in range(count):
            base = 8 + index * entry
            # fat_arch fields are big-endian
            cputype, cpusub, offset = struct.unpack_from('>iII', data, base)
            if cputype != CPU_TYPE_ARM64:
                continue
            before.append(('fat[%d]' % index, cpusub))
            struct.pack_into('>I', data, base + 4, CPU_SUBTYPE_ARM64E)
            patch_slice(data, offset)
    elif magic_le == MH_MAGIC_64:
        before.append(('thin', struct.unpack_from('<I', data, 8)[0]))
        patch_slice(data, 0)
    else:
        raise ValueError('unknown file type (magic 0x%x / 0x%x)' % (magic_be, magic_le))

    with open(path, 'wb') as handle:
        handle.write(data)

    for where, old in before:
        print('%-40s %-10s cpusubtype 0x%x -> 0x%x' % (path, where, old, CPU_SUBTYPE_ARM64E))


if __name__ == '__main__':
    if len(sys.argv) < 2:
        sys.exit('usage: mark-arm64e.py <macho-file> [...]')
    for argument in sys.argv[1:]:
        patch(argument)
