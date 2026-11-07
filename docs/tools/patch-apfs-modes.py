#!/usr/bin/env python3
"""Fix POSIX modes inside an APFS image that mkapfs.py built on Windows.

mkapfs.py takes st_mode from the host filesystem unless a manifest overrides it.
On Windows/NTFS Git Bash reports regular files as 0666 and directories as 0777,
and chmod does not change what Python's os.stat sees. Files that build.sh adds
to sysroot but that are absent from system.manifest (sbin/launchd.ios, the
Cryptexes, staged system apps) therefore land in the system volume with no
execute bit. iOS launchd cannot be exec'd and init(reboots) instead.

This patches the j_inode_val_t.mode field of those inodes in place and
recomputes each affected 4096-byte object block's Fletcher-64 checksum.
A sidecar file holds the original bytes of every changed block so the patch
can be reverted.

usage:
  patch-apfs-modes.py IMAGE SLT MANIFEST [--apply] [--revert]
  SLT is `7z l -slt IMAGE` output (paths, modes, iNode, Parent iNode).
Without --apply it only reports what it would change.
"""
import argparse
import collections
import os
import struct
import sys

sys.path.insert(0, os.path.join(os.path.dirname(os.path.abspath(__file__)), '..', '..', '..'))
BS = 4096
MODE_AT = 80                    # offset of j_inode_val_t.mode inside the value
PHYSICAL = 0x40000000
# APFS storage is in the high bits; both virtual and physical b-tree nodes
# carry a Fletcher-64 checksum in the first eight bytes of their block.
VALID_TYPES = {0x2, 0x3, PHYSICAL | 0x2, PHYSICAL | 0x3}

MAGICS = (b'\xcf\xfa\xed\xfe', b'\xfe\xed\xfa\xcf', b'\xce\xfa\xed\xfe',
          b'\xfe\xed\xfa\xce', b'\xca\xfe\xba\xbe', b'\xbe\xba\xfe\xca',
          b'\xca\xfe\xba\xbf', b'\xbf\xba\xfe\xca')


def fletcher64(block):
    words = struct.unpack_from('<%dI' % ((len(block) - 8) // 4), block, 8)
    s1 = s2 = 0
    for w in words:
        s1 = (s1 + w) % 0xffffffff
        s2 = (s2 + s1) % 0xffffffff
    c1 = 0xffffffff - ((s1 + s2) % 0xffffffff)
    c2 = 0xffffffff - ((s1 + c1) % 0xffffffff)
    return (c2 << 32) | c1


def parse_slt(path):
    """-> list of dicts: path, mode, ino, parent, link"""
    out = []
    cur = {}
    for raw in open(path, 'r', encoding='utf-8', errors='replace'):
        line = raw.rstrip('\r\n')
        if line.startswith('Path = '):
            if cur.get('path') and cur.get('ino'):
                out.append(cur)
            cur = {'path': line[7:].replace('\\', '/'), 'mode': '', 'ino': 0,
                   'parent': 0, 'link': ''}
        elif line.startswith('Mode = ') and cur:
            cur['mode'] = line[7:]
        elif line.startswith('iNode = ') and cur:
            cur['ino'] = int(line[8:])
        elif line.startswith('Parent iNode = ') and cur:
            cur['parent'] = int(line[15:])
        elif line.startswith('Symbolic Link = ') and cur:
            cur['link'] = line[16:]
    if cur.get('path') and cur.get('ino'):
        out.append(cur)
    return out


def mode_of(m):
    """7-Zip mode string -> st_mode, and the corrected st_mode."""
    if m.startswith('d'):
        return 0o040777, 0o040755
    if m.startswith('l'):
        return 0o120666, 0o120777
    if m.startswith('-r--'):
        return 0o100444, 0o100444
    if m.startswith('-rw-rw-rw-'):
        # Windows-derived files. An extra x bit on a data file is harmless;
        # missing x on a Mach-O breaks execve. Grant it to all of them.
        return 0o100666, 0o100755
    return None


def main():
    ap = argparse.ArgumentParser()
    ap.add_argument('image')
    ap.add_argument('slt')
    ap.add_argument('manifest')
    ap.add_argument('--apply', action='store_true')
    ap.add_argument('--revert', action='store_true')
    args = ap.parse_args()
    bak = args.image + '.modebak'

    if args.revert:
        if not os.path.isfile(bak):
            sys.exit('no block backup: ' + bak)
        with open(bak, 'rb') as f, open(args.image, 'r+b') as img:
            while True:
                head = f.read(12)
                if not head:
                    break
                n, = struct.unpack('<Q', head[:8])
                length, = struct.unpack('<I', head[8:12])
                img.seek(n * BS)
                img.write(f.read(length))
        print('reverted from', bak)
        return

    manifest = set()
    for line in open(args.manifest, 'r', encoding='utf-8', errors='replace'):
        f = line.rstrip('\n').split('\t')
        if len(f) >= 4 and f[3]:
            manifest.add(f[3])

    entries = parse_slt(args.slt)
    targets = []
    for e in entries:
        if e['path'] in manifest or not e['ino'] or not e['parent']:
            continue
        m = mode_of(e['mode'])
        if m is None:
            continue
        old, new = m
        if old != new:
            targets.append((e['parent'], e['ino'], old, new, e['path']))
    print('slt entries: %d, manifest: %d, inode modes to fix: %d'
          % (len(entries), len(manifest), len(targets)))
    if not targets:
        return

    # Locate j_inode_val_t by its private_id (offset 8 in the value); the
    # parent_id at offset 0 is not always what 7-Zip reports, but the mode
    # field at +80 is a strong enough check against accidental matches.
    by_ino = {i: (old, new, path, p) for p, i, old, new, path in targets}
    found = collections.defaultdict(list)   # block -> [(offset, old, new, path)]
    size = os.path.getsize(args.image)
    nblocks = size // BS
    with open(args.image, 'rb') as img:
        for bn in range(nblocks):
            b = img.read(BS)
            if len(b) < BS:
                break
            otype, = struct.unpack_from('<I', b, 24)
            if otype not in VALID_TYPES:
                continue
            # APFS record values are byte-aligned, not word-aligned (e.g.
            # sbin/launchd.ios lands at block offset 1841).
            for off in range(64, BS - 88):
                oid, = struct.unpack_from('<Q', b, off)
                hit = by_ino.get(oid)
                if hit is None:
                    continue
                voff = off - 8
                old, new, path, expected_parent = hit
                parent, = struct.unpack_from('<Q', b, voff)
                if parent != expected_parent:
                    continue        # not this inode record, just data that matched
                cur, = struct.unpack_from('<H', b, voff + MODE_AT)
                if cur == old:
                    found[bn].append((voff, old, new, path))

    total = sum(len(v) for v in found.values())
    print('matched %d/%d inode records in %d object blocks'
          % (total, len(targets), len(found)))
    dup = [(p, n) for p, n in collections.Counter(
        path for v in found.values() for _, _, _, path in v).items() if n > 1]
    if dup:
        print('  patched more than once:', dup[:10])
    # report a few unmatched paths
    got = collections.Counter(path for v in found.values() for _, _, _, path in v)
    absent = [t[4] for t in targets if got[t[4]] == 0]
    if absent:
        print('  %d not located, first 10:' % len(absent))
        for p in absent[:10]:
            print('    ', p)
    if not args.apply:
        print('(dry run: pass --apply to write)')
        return

    with open(args.image, 'r+b') as img, open(bak, 'wb') as backup:
        for bn in sorted(found):
            img.seek(bn * BS)
            b = bytearray(img.read(BS))
            stored, = struct.unpack_from('<Q', b, 0)
            if stored != fletcher64(bytes(b)):
                print('  !! block %d checksum mismatch before patch, refuse' % bn)
                continue
            backup.write(struct.pack('<QI', bn, BS))
            backup.write(bytes(b))
            for off, old, new, path in found[bn]:
                struct.pack_into('<H', b, off + MODE_AT, new)
            struct.pack_into('<Q', b, 0, fletcher64(bytes(b)))
            img.seek(bn * BS)
            img.write(b)
    print('patched %d inodes in %d blocks; block backup: %s'
          % (total, len(found), bak))


if __name__ == '__main__':
    main()
