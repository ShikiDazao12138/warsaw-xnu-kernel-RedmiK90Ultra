#!/usr/bin/env python3
"""Generate a POSIX mode manifest for the small 'redwood' APFS volume.

mkapfs.py takes st_mode from the host filesystem unless a manifest overrides it.
On Windows/NTFS Git Bash reports every regular file as 0666 and every directory
as 0777, and `chmod` does not change what Python's os.stat sees. An image built
there therefore has no executable bit anywhere: stage0 mounts /dev/md1 fine,
but execve("/redwood/sbin/init") fails with EACCES ("Permission denied") and
stage0 calls reboot(RB_HALT), which looks like a kernel shutdown.

This mirrors the modes a macOS build would have produced naturally:
  - directories               40755
  - programs (bin/sbin/lib,
    any Mach-O, etc/rc*)       100755
  - everything else            100644
Manifest lines are: mode(octal, with type bits) TAB uid TAB gid TAB path TAB.
"""
import os
import stat
import sys

MAGICS = (
    b'\xcf\xfa\xed\xfe', b'\xfe\xed\xfa\xcf',  # MH_MAGIC_64
    b'\xce\xfa\xed\xfe', b'\xfe\xed\xfa\xce',  # MH_MAGIC
    b'\xca\xfe\xba\xbe', b'\xbe\xba\xfe\xca',  # FAT
    b'\xca\xfe\xba\xbf', b'\xbf\xba\xfe\xca',  # FAT_64
)


def is_macho(path):
    try:
        with open(path, 'rb') as f:
            return f.read(4) in MAGICS
    except OSError:
        return False


def executable(rel, path):
    parts = rel.split('/')
    if parts[0] in ('bin', 'sbin', 'lib'):
        return True
    if rel in ('etc/rc', 'etc/rc.jobs'):
        return True
    return is_macho(path)


def main():
    if len(sys.argv) != 3:
        sys.exit('usage: make-root-manifest.py ROOTDIR OUTPUT.manifest')
    root, out = sys.argv[1], sys.argv[2]
    rows = []
    for dirpath, dirnames, filenames in os.walk(root):
        dirnames.sort()
        filenames.sort()
        for name in dirnames + filenames:
            full = os.path.join(dirpath, name)
            rel = os.path.relpath(full, root).replace('\\', '/')
            st = os.lstat(full)
            if stat.S_ISDIR(st.st_mode):
                mode = '40755'
            elif stat.S_ISLNK(st.st_mode):
                mode = '120777'
                target = os.fsencode(os.readlink(full)).decode('utf-8', 'surrogateescape')
                rows.append((rel, '%s\t0\t0\t%s\t%s' % (mode, rel, target)))
                continue
            elif stat.S_ISREG(st.st_mode):
                mode = '100755' if executable(rel, full) else '100644'
            else:
                continue
            rows.append((rel, '%s\t0\t0\t%s\t' % (mode, rel)))
    rows.sort(key=lambda x: x[0])
    with open(out, 'w', newline='\n', encoding='utf-8', errors='surrogateescape') as f:
        for _, line in rows:
            f.write(line + '\n')
    nx = sum(1 for _, line in rows if line.startswith('100755'))
    print('%s: %d entries, %d executable files' % (out, len(rows), nx))
    for _, line in rows:
        if line.startswith('100755') and ('/sbin/' in line or '/bin/' in line or '/etc/rc' in line):
            print('  ' + line.split('\t')[3])


if __name__ == '__main__':
    main()
