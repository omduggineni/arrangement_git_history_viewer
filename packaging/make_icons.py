"""Generate the app icon for each platform from packaging/icon-source.png.

icon-source.png is the full-bleed square artwork (exported from the icon's
slide). Each platform expects a different shape, so it's cut out separately:

  icon.icns                   macOS: Apple's icon grid -- an 824px rounded
                              square (185px corners) centred on a 1024px
                              canvas, with a soft drop shadow in the margin.
  icon-macos.png              The same, as a PNG for the dock icon at runtime.
  icon.ico                    Windows: a rounded square that nearly fills the
                              canvas (Windows doesn't mask icons itself).
  arrangement-diff-viewer.png Linux (AppImage), and the web favicon: the same
                              rounded square as Windows.

The outputs are committed, so this only needs rerunning when the artwork
changes (on macOS, since it uses iconutil for the .icns):
  .venv/bin/python packaging/make_icons.py
"""

import subprocess
import tempfile
from pathlib import Path

from PIL import Image, ImageChops, ImageDraw, ImageFilter

HERE = Path(__file__).resolve().parent
SOURCE = HERE / "icon-source.png"

CANVAS = 1024
SUPERSAMPLE = 4  # draw the mask larger, then downscale, for smooth edges


def _rounded_mask(size: int, box: tuple[int, int, int, int], radius: int) -> Image.Image:
    big = size * SUPERSAMPLE
    mask = Image.new("L", (big, big), 0)
    ImageDraw.Draw(mask).rounded_rectangle([v * SUPERSAMPLE for v in box], radius=radius * SUPERSAMPLE, fill=255)
    return mask.resize((size, size), Image.LANCZOS)


def _cut_out(art: Image.Image, mask: Image.Image, box: tuple[int, int, int, int]) -> Image.Image:
    left, top, right, bottom = box
    out = Image.new("RGBA", mask.size, (0, 0, 0, 0))
    out.paste(art.resize((right - left, bottom - top), Image.LANCZOS), (left, top))
    out.putalpha(ImageChops.multiply(out.getchannel("A"), mask))
    return out


def macos_icon(art: Image.Image) -> Image.Image:
    box = (100, 100, 924, 924)
    mask = _rounded_mask(CANVAS, box, radius=185)
    shape = _cut_out(art, mask, box)
    # Apple's template: a black shadow, 28px blur, offset 12px down, ~30% opacity.
    shadow_alpha = Image.new("L", mask.size, 0)
    shadow_alpha.paste(mask.point(lambda a: a * 0.3), (0, 12))
    shadow = Image.new("RGBA", mask.size, (0, 0, 0, 0))
    shadow.putalpha(shadow_alpha.filter(ImageFilter.GaussianBlur(28)))
    return Image.alpha_composite(shadow, shape)


def rounded_icon(art: Image.Image) -> Image.Image:
    margin = CANVAS // 32
    box = (margin, margin, CANVAS - margin, CANVAS - margin)
    return _cut_out(art, _rounded_mask(CANVAS, box, radius=CANVAS // 10), box)


def main() -> None:
    art = Image.open(SOURCE).convert("RGBA")

    mac = macos_icon(art)
    mac.save(HERE / "icon-macos.png")
    # Pillow's ICNS writer skips the small @1x sizes, so build it with iconutil.
    with tempfile.TemporaryDirectory() as tmp:
        iconset = Path(tmp) / "icon.iconset"
        iconset.mkdir()
        for size in (16, 32, 128, 256, 512):
            mac.resize((size, size), Image.LANCZOS).save(iconset / f"icon_{size}x{size}.png")
            mac.resize((size * 2, size * 2), Image.LANCZOS).save(iconset / f"icon_{size}x{size}@2x.png")
        subprocess.run(["iconutil", "-c", "icns", "-o", str(HERE / "icon.icns"), str(iconset)], check=True)

    rounded = rounded_icon(art)
    rounded.save(HERE / "arrangement-diff-viewer.png")
    rounded.save(HERE / "icon.ico", sizes=[(s, s) for s in (16, 24, 32, 48, 64, 128, 256)])


if __name__ == "__main__":
    main()
