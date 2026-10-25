"""Makes the share viewer's tab icon and home-screen icon from the app icon.

Run on a Mac after building the app, when md-preview/AppIcon.icon changes:
    python3 server/share-worker/viewer/icons/make-icons.py \\
        "<DerivedData>/Build/Products/Debug/Markdown Preview.app"
Needs Pillow. The images are committed, so the Worker build does not need
macOS or the app.

The macOS icon has a transparent margin around its rounded square; both
images are cropped to the square so the icon fills its space.
"""
import subprocess
import sys
import tempfile
from pathlib import Path

from PIL import Image

app = Path(sys.argv[1])
out = Path(__file__).parent
with tempfile.TemporaryDirectory() as scratch:
    iconset = Path(scratch) / "AppIcon.iconset"
    subprocess.run(["iconutil", "-c", "iconset", str(app / "Contents/Resources/AppIcon.icns"), "-o", str(iconset)],
                   check=True)
    icon = Image.open(iconset / "icon_128x128@2x.png").convert("RGBA")
square = icon.crop(icon.getchannel("A").point(lambda a: 255 if a > 8 else 0).getbbox())

# Tab icon: the rounded square on transparency, at 2x for sharp tabs.
square.resize((64, 64), Image.LANCZOS).save(out / "favicon.png", optimize=True)

# Home-screen icon: iOS draws its own rounded corners and paints any
# transparency black, so fill the corners with the icon's own background.
background = square.getpixel((square.width // 2, square.height // 12))
filled = Image.new("RGBA", square.size, background[:3] + (255,))
filled.alpha_composite(square)
# Inside the macOS edge and corner curve, which iOS would draw a second time.
inset = round(square.width * 0.06)
filled = filled.crop((inset, inset, square.width - inset, square.height - inset))
filled.convert("RGB").resize((180, 180), Image.LANCZOS).save(out / "apple-touch-icon.png", optimize=True)
