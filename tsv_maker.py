#!/usr/bin/env python3
"""tsv_maker.py - build a manifest TSV (for check_tree.py / repack.sh) from a rootfs.

The manifest lists every entry of the ORIGINAL rootfs: type, mode, uid, gid, size/link target, path.
repack.sh uses it to prove that ubi_reader extracted the rootfs faithfully before anything is repacked.
Make a new one for every firmware version you want to repack.

Usage (run as root, otherwise owners cannot be read back correctly):
  # 1) from a rootfs directory that was already extracted with:  ubireader_extract_files -k -o DIR SYSTEM.UBI
  sudo ./tsv_maker.py /path/to/rootfs_dir -o manifest_X.tsv

  # 2) straight from SYSTEM.UBI (calls ubireader_extract_files for you into a temp dir)
  sudo env "PATH=$PATH" ./tsv_maker.py --ubi SYSTEM.UBI -o manifest_X.tsv

Line format (tab separated):  type  mode  uid  gid  size|target|-  /path
  type: f = file, d = directory, l = symlink      mode: 4-digit octal (permission bits only)
"""
import argparse, os, shutil, stat, subprocess, sys, tempfile

def find_root(base):
    """Locate the directory holding bin/ etc/ usr/ below an ubi_reader output folder."""
    for d, dirs, _ in os.walk(base):
        if d[len(base):].count(os.sep) > 5: dirs[:] = []; continue
        if all(x in dirs for x in ('bin', 'etc', 'usr')): return d
    return None

def walk(root, out, warn):
    entries = sorted(os.scandir(root), key=lambda e: e.name)
    for e in entries:
        path = e.path[len(root_base):]
        st = e.stat(follow_symlinks=False)
        if '\t' in path or '\n' in path: raise SystemExit('tab/newline in file name: %r' % path)
        perm = st.st_mode & 0o7777
        if stat.S_ISLNK(st.st_mode):
            out.append(('l', perm, st.st_uid, st.st_gid, os.readlink(e.path), path))
        elif stat.S_ISDIR(st.st_mode):
            out.append(('d', perm, st.st_uid, st.st_gid, '-', path))
            walk(e.path, out, warn)
        elif stat.S_ISREG(st.st_mode):
            out.append(('f', perm, st.st_uid, st.st_gid, str(st.st_size), path))
        else:
            warn.append(path)   # device node / fifo / socket: not representable in this format

def main():
    ap = argparse.ArgumentParser(description='Create a rootfs manifest TSV for check_tree.py')
    ap.add_argument('source', help='extracted rootfs directory, or SYSTEM.UBI with --ubi')
    ap.add_argument('--ubi', action='store_true', help='source is a UBIFS image: extract it with ubireader_extract_files first')
    ap.add_argument('-o', '--output', default='manifest.tsv')
    a = ap.parse_args()

    if os.geteuid() != 0:
        print('WARNING: not running as root - uid/gid in the manifest may be wrong. Use sudo.', file=sys.stderr)
    tmp = None; src = a.source.rstrip('/')
    try:
        if a.ubi:
            if not shutil.which('ubireader_extract_files'): raise SystemExit('ubireader_extract_files not found (see repack.sh header; check PATH)')
            tmp = tempfile.mkdtemp(prefix='tsvmaker_')
            subprocess.run(['ubireader_extract_files', '-k', '-o', tmp, a.source], check=True, stdout=subprocess.DEVNULL)
            src = find_root(tmp)
            if not src: raise SystemExit('could not locate the extracted rootfs under ' + tmp)
        elif not os.path.isdir(src):
            raise SystemExit('not a directory: ' + src)
        global root_base; root_base = src
        out, warn = [], []
        walk(src, out, warn)
        with open(a.output, 'w', encoding='utf-8', newline='\n') as f:
            for t, mode, uid, gid, val, path in out:
                f.write('\t'.join([t, '%04o' % mode, str(uid), str(gid), val, path]) + '\n')
        n = {k: sum(1 for e in out if e[0] == k) for k in 'fdl'}
        print('wrote %s: %d entries (%d files, %d dirs, %d symlinks)' % (a.output, len(out), n['f'], n['d'], n['l']))
        for w in warn: print('WARNING skipped special file: ' + w, file=sys.stderr)
        if warn: print('NOTE: special files exist in this rootfs; check_tree.py will report them as extra.', file=sys.stderr)
    finally:
        if tmp: shutil.rmtree(tmp, ignore_errors=True)

if __name__ == '__main__':
    main()
