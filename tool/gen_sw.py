#!/usr/bin/env python3
"""Fills the precache list and cache version into build/web/sw.js."""
import hashlib
import json
import os
import sys

root = sys.argv[1] if len(sys.argv) > 1 else 'build/web'
SKIP_SUFFIX = ('.symbols', '.map')
SKIP_FILES = {'sw.js', 'flutter_service_worker.js', '.last_build_id', '_headers', '_redirects'}
# Not precached (fetched + cached on first use): Chrome-only/WASM renderer
# variants and splash images (iOS reads those at install time anyway).
# Fallback fonts (~22 MB, only a few are ever needed) too; Roboto, the
# default text font, is precached so text renders offline.
LAZY_PREFIXES = ('canvaskit/chromium/', 'canvaskit/skwasm', 'canvaskit/wimp', 'canvaskit/webparagraph/', 'splash/',
                 'fonts/fallback/')
EAGER = ('fonts/fallback/roboto/',)

files = []
digest = hashlib.sha256()
for dirpath, _, names in os.walk(root):
    for n in sorted(names):
        rel = os.path.relpath(os.path.join(dirpath, n), root).replace(os.sep, '/')
        if n in SKIP_FILES or rel.endswith(SKIP_SUFFIX):
            continue
        with open(os.path.join(root, rel), 'rb') as f:
            data = f.read()
        digest.update(rel.encode() + b'\0' + hashlib.sha256(data).digest())
        if rel == 'fonts/fallback/NOTICE.txt':
            continue
        if not rel.startswith(LAZY_PREFIXES) or rel.startswith(EAGER):
            files.append(rel)
files.sort()
if 'index.html' in files:
    files.remove('index.html')
precache = ['./', 'index.html'] + files
sw_path = os.path.join(root, 'sw.js')
src = open(sw_path).read()
digest.update(b'sw.js\0' + hashlib.sha256(src.encode()).digest())  # template changes bump the version too
version = digest.hexdigest()[:16]
if '__PRECACHE__' not in src:
    sys.exit('sw.js already processed or missing placeholders')
src = src.replace("const CACHE_VERSION = '__CACHE_VERSION__';", 'const CACHE_VERSION = %s;' % json.dumps(version))
src = src.replace('const PRECACHE = __PRECACHE__;', 'const PRECACHE = %s;' % json.dumps(precache, indent=2))
if '__CACHE_VERSION__' in src or '__PRECACHE__' in src:
    sys.exit('gen_sw.py: placeholders not replaced in sw.js')
open(sw_path, 'w').write(src)
size = sum(os.path.getsize(os.path.join(root, p)) for p in precache if p != './')
print(f'sw.js: version {version}, {len(precache)} precached files, {size / 1e6:.1f} MB')
