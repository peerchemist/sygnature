#!/usr/bin/env python3
"""Regenerate platform icons from the approved SVG (requires rsvg-convert and Pillow)."""
import io
import json
from pathlib import Path
import subprocess
import xml.etree.ElementTree as ET

from PIL import Image

ROOT = Path(__file__).resolve().parent.parent
SVG = (ROOT / 'assets/branding/app-icon.svg').read_text()


def render(svg, size):
    return Image.open(io.BytesIO(subprocess.check_output(
        ['rsvg-convert', '-w', str(size), '-h', str(size)],
        input=svg.encode(),
    )))


def save(svg, path, size, opaque=False):
    image = render(svg, size)
    if opaque:
        image = image.convert('RGB')
    image.save(ROOT / path)


save(SVG, 'assets/branding/app-icon.png', 512)
# iOS applies its own corner mask and requires an opaque square.
square = SVG.replace('x="64" y="64" width="896" height="896" rx="200"',
                     'width="1024" height="1024"')
for platform, source in [('macos', SVG), ('ios', square)]:
    folder = Path(platform) / 'Runner/Assets.xcassets/AppIcon.appiconset'
    catalog = json.loads((ROOT / folder / 'Contents.json').read_text())
    for entry in catalog['images']:
        size = round(float(entry['size'].split('x')[0]) * float(entry['scale'][:-1]))
        save(source, folder / entry['filename'], size, opaque=platform == 'ios')

for density, size in [('mdpi', 48), ('hdpi', 72), ('xhdpi', 96), ('xxhdpi', 144), ('xxxhdpi', 192)]:
    save(SVG, f'android/app/src/main/res/mipmap-{density}/ic_launcher.png', size)

render(SVG, 256).save(ROOT / 'windows/runner/resources/app_icon.ico',
                     sizes=[(n, n) for n in [16, 24, 32, 48, 64, 128, 256]])

# Android masks the background itself; keep the S within its adaptive safe area.
res = ROOT / 'android/app/src/main/res'
paths = ET.fromstring(SVG).findall('.//{http://www.w3.org/2000/svg}path')
vector = ('<vector xmlns:android="http://schemas.android.com/apk/res/android" '
          'android:width="108dp" android:height="108dp" '
          'android:viewportWidth="108" android:viewportHeight="108">\n'
          '  <group android:scaleX="0.1" android:scaleY="0.1" '
          'android:translateX="-8.75" android:translateY="-3.8">\n')
for path in paths:
    vector += f'    <path android:fillColor="#171717" android:pathData="{path.attrib["d"]}"/>\n'
vector += '  </group>\n</vector>\n'
(res / 'drawable/ic_launcher_foreground.xml').write_text(vector)
(res / 'values/icon_colors.xml').write_text(
    '<resources>\n    <color name="ic_launcher_background">#DCE9DF</color>\n</resources>\n')
for version in [26, 33]:
    folder = res / f'mipmap-anydpi-v{version}'
    folder.mkdir(exist_ok=True)
    monochrome = ('    <monochrome android:drawable="@drawable/ic_launcher_foreground"/>\n'
                  if version == 33 else '')
    (folder / 'ic_launcher.xml').write_text(
        '<adaptive-icon xmlns:android="http://schemas.android.com/apk/res/android">\n'
        '    <background android:drawable="@color/ic_launcher_background"/>\n'
        '    <foreground android:drawable="@drawable/ic_launcher_foreground"/>\n'
        + monochrome + '</adaptive-icon>\n')
