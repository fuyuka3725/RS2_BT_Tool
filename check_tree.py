#!/usr/bin/env python3
"""Verification helper for repack.sh.
  check_tree.py manifest ROOT manifest.tsv   -> compare an extracted rootfs with the manifest
  check_tree.py overlay  ROOT bt_overlay.tar     -> confirm every overlay member is present in ROOT
"""
import os, sys, stat, tarfile

def manifest(root, mf):
    exp = {}
    for line in open(mf, encoding='utf-8'):
        t, mode, uid, gid, val, path = line.rstrip('\n').split('\t', 5)
        exp[path] = (t, int(mode, 8), int(uid), int(gid), val)
    bad = []
    for path, (t, mode, uid, gid, val) in exp.items():
        fp = root + path
        try:
            st = os.lstat(fp)
        except FileNotFoundError:
            bad.append('MISSING  ' + path); continue
        kind = 'l' if stat.S_ISLNK(st.st_mode) else 'd' if stat.S_ISDIR(st.st_mode) else 'f' if stat.S_ISREG(st.st_mode) else '?'
        if kind != t:
            bad.append('TYPE     %s (want %s got %s)' % (path, t, kind)); continue
        if t == 'l':
            if os.readlink(fp) != val: bad.append('LINK     %s -> %s (want %s)' % (path, os.readlink(fp), val))
            continue
        if (st.st_mode & 0o7777) != mode: bad.append('MODE     %s %04o (want %04o)' % (path, st.st_mode & 0o7777, mode))
        if (st.st_uid, st.st_gid) != (uid, gid): bad.append('OWNER    %s %d:%d (want %d:%d)' % (path, st.st_uid, st.st_gid, uid, gid))
        if t == 'f' and st.st_size != int(val): bad.append('SIZE     %s %d (want %s)' % (path, st.st_size, val))
    extra = 0
    for d, dirs, files in os.walk(root):
        for n in dirs + files:
            if (os.path.join(d, n)[len(root):]) not in exp: extra += 1
    print('manifest entries: %d, problems: %d, extra files not in manifest: %d' % (len(exp), len(bad), extra))
    for b in bad[:25]: print('  ' + b)
    if len(bad) > 25: print('  ... (%d more)' % (len(bad) - 25))
    return 1 if (bad or extra) else 0

def overlay(root, tarpath):
    bad = 0; n = 0
    with tarfile.open(tarpath) as tf:
        for m in tf:
            n += 1; fp = os.path.join(root, m.name)
            if m.issym():
                ok = os.path.islink(fp) and os.readlink(fp) == m.linkname
            else:
                ok = os.path.isfile(fp) and os.path.getsize(fp) == m.size and (os.stat(fp).st_mode & 0o7777) == m.mode
                if ok:
                    ok = tf.extractfile(m).read() == open(fp, 'rb').read()
            if not ok: bad += 1; print('  BAD  ' + m.name)
    print('overlay members: %d, bad: %d' % (n, bad))
    return 1 if bad else 0

if __name__ == '__main__':
    cmd, root, arg = sys.argv[1:4]
    root = root.rstrip('/')
    sys.exit(manifest(root, arg) if cmd == 'manifest' else overlay(root, arg))
