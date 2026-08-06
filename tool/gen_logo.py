#!/usr/bin/env python3
"""生成「字在」logo / App 图标（几何极简：平蓝圆角方块 + 45° 白色笔触带）。

输出：
- android/app/src/main/res/mipmap-*/ic_launcher.png
- macos/Runner/Assets.xcassets/AppIcon.appiconset/app_icon_*.png
- windows/runner/resources/app_icon.ico
- assets/logo.png（应用内品牌标，256px）
"""
import os
from PIL import Image, ImageDraw

ROOT = os.getcwd()  # 从仓库根运行

BLUE = (10, 132, 255)  # 0A84FF 平色（无渐变，极简）
WHITE = (255, 255, 255)


def render(size: int) -> Image.Image:
    img = Image.new("RGBA", (size, size), (0, 0, 0, 0))
    radius = int(size * 0.224)  # Apple 图标圆角比

    # 圆角方块底（平蓝）
    d = ImageDraw.Draw(img)
    d.rounded_rectangle([0, 0, size - 1, size - 1], radius=radius, fill=BLUE)

    # 45° 白色笔触带（胶囊形，从左下到右上）
    band_len = int(size * 0.82)
    band_h = max(1, int(size * 0.20))
    band = Image.new("RGBA", (band_len, band_h), (0, 0, 0, 0))
    ImageDraw.Draw(band).rounded_rectangle(
        [0, 0, band_len - 1, band_h - 1], radius=band_h // 2, fill=WHITE)
    band = band.rotate(45, expand=True, resample=Image.Resampling.BICUBIC)
    img.alpha_composite(band,
                        ((size - band.width) // 2, (size - band.height) // 2))
    return img


def main():
    android = {
        "mdpi": 48, "hdpi": 72, "xhdpi": 96, "xxhdpi": 144, "xxxhdpi": 192,
    }
    for density, px in android.items():
        path = os.path.join(ROOT, "android", "app", "src", "main", "res",
                            f"mipmap-{density}", "ic_launcher.png")
        render(px).save(path)
        print("android", path)

    mac = {16: "app_icon_16.png", 32: "app_icon_32.png", 64: "app_icon_64.png",
           128: "app_icon_128.png", 256: "app_icon_256.png",
           512: "app_icon_512.png", 1024: "app_icon_1024.png"}
    mac_dir = os.path.join(ROOT, "macos", "Runner", "Assets.xcassets",
                           "AppIcon.appiconset")
    for px, name in mac.items():
        render(px).save(os.path.join(mac_dir, name))
        print("macos", name)

    win = os.path.join(ROOT, "windows", "runner", "resources", "app_icon.ico")
    render(256).save(win, format="ICO",
                     sizes=[(16, 16), (24, 24), (32, 32), (48, 48),
                            (64, 64), (128, 128), (256, 256)])
    print("windows", win)

    logo_dir = os.path.join(ROOT, "assets")
    os.makedirs(logo_dir, exist_ok=True)
    render(256).save(os.path.join(logo_dir, "logo.png"))
    print("asset", os.path.join(logo_dir, "logo.png"))


if __name__ == "__main__":
    main()
