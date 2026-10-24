#!/usr/bin/env python3
"""Self-hosted fallback fonts for Flutter web (no runtime requests to Google).

CanvasKit/skwasm download Noto fallback fonts (emoji, CJK, symbols, other
scripts) and Roboto from `fontFallbackBaseUrl` (default
https://fonts.gstatic.com/s/). web/flutter_bootstrap.js points it at
fonts/fallback/ instead, and this script keeps that folder in sync with the
installed Flutter SDK's font list:

  tool/fetch_fallback_fonts.py           # download missing files (once / after a Flutter upgrade)
  tool/fetch_fallback_fonts.py --check   # exit 1 if any is missing (build_web.sh runs this)

Fonts: Noto (SIL Open Font License 1.1), Roboto (Apache 2.0 / OFL), see
web/fonts/fallback/NOTICE.txt.
"""
import os
import re
import shutil
import subprocess
import sys
import urllib.request

ROOT = os.path.dirname(os.path.dirname(os.path.abspath(__file__)))
DEST = os.path.join(ROOT, 'web', 'fonts', 'fallback')
GSTATIC = 'https://fonts.gstatic.com/s/'


def sdk_engine_dir():
    flutter = shutil.which('flutter')
    if not flutter:
        sys.exit('flutter not on PATH')
    sdk = os.path.dirname(os.path.dirname(os.path.realpath(flutter)))
    d = os.path.join(sdk, 'bin', 'cache', 'flutter_web_sdk', 'lib', '_engine', 'engine')
    if not os.path.isdir(d):
        subprocess.run([flutter, 'precache', '--web'], check=True)
    return d


def font_paths():
    d = sdk_engine_dir()
    paths = set()
    pat = re.compile(r"[a-z0-9]+/v[0-9]+/[A-Za-z0-9_.-]+\.woff2?")
    for rel in ('font_fallback_data.dart', 'canvaskit/fonts.dart', 'skwasm/skwasm_impl/font_collection.dart'):
        p = os.path.join(d, rel)
        if os.path.exists(p):
            paths.update(pat.findall(open(p, encoding='utf-8').read()))
    if len(paths) < 100:
        sys.exit(f'found only {len(paths)} fallback fonts in the Flutter SDK; has the engine layout changed?')
    return sorted(paths)


def main():
    check = '--check' in sys.argv
    missing = [p for p in font_paths() if not os.path.isfile(os.path.join(DEST, p))]
    if check:
        if missing:
            print(f'{len(missing)} fallback font(s) missing in web/fonts/fallback (e.g. {missing[0]}).', file=sys.stderr)
            print('Run tool/fetch_fallback_fonts.py once (Flutter was upgraded?).', file=sys.stderr)
            sys.exit(1)
        return
    for p in missing:
        if not re.fullmatch(r"[a-z0-9]+/v[0-9]+/[A-Za-z0-9_.-]+\.woff2?", p) or '..' in p:
            sys.exit(f'unexpected font path {p!r}')
        out = os.path.join(DEST, p)
        os.makedirs(os.path.dirname(out), exist_ok=True)
        with urllib.request.urlopen(GSTATIC + p, timeout=60) as r:
            data = r.read()
        if data[:4] not in (b'wOF2', b'wOFF'):
            sys.exit(f'{p}: not a WOFF/WOFF2 file')
        with open(out + '.part', 'wb') as f:
            f.write(data)
        os.replace(out + '.part', out)
    print(f'{len(missing)} downloaded; web/fonts/fallback is complete.')


if __name__ == '__main__':
    main()
