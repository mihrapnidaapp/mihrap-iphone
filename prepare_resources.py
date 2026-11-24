"""Copy what the iPhone app bundles from the Android app (salahwin/android) into Mihrap/Resources:
all Android strings for the 10 languages (strings/<lang>.json), the fonts, the three home photos,
the app icon. Run after Android text or picture changes:  py -X utf8 prepare_resources.py
"""
from __future__ import annotations

import json
import re
import shutil
import xml.etree.ElementTree as ET
from pathlib import Path

from PIL import Image

HERE = Path(__file__).resolve().parent
SALAHWIN = HERE.parent / "salahwin"
RES = SALAHWIN / "android" / "app" / "src" / "main" / "res"
OUT = HERE / "Mihrap" / "Resources"
ASSETS = HERE / "Mihrap" / "Assets.xcassets"
LANG_DIRS = {"en": "values", "tr": "values-tr", "de": "values-de", "ar": "values-ar", "fa": "values-fa",
             "id": "values-in", "ms": "values-ms", "zh": "values-zh", "ur": "values-ur", "hi": "values-hi"}
FONTS = {  # Android font resources -> bundle
    RES / "font" / "scheherazade_new_regular.ttf": "ScheherazadeNew-Regular.ttf",
}
WEB_FONTS = HERE.parent / "mihrap-web" / "site" / "fonts"  # same files the Android app uses (Roboto, Droid Sans Mono, Noto Serif, Amiri)
HOME_PHOTOS = ["backgrounds/apk/azan_bg6.jpg", "backgrounds/apk/azan_bg2_land.jpg", "backgrounds/apk/azan_bg5_land.jpg"]


def android_unescape(value: str) -> str:
    value = value.strip()
    if len(value) >= 2 and value[0] == '"' and value[-1] == '"':
        value = value[1:-1]
    value = re.sub(r"\\u([0-9a-fA-F]{4})", lambda m: chr(int(m.group(1), 16)), value)
    return value.replace("\\'", "'").replace('\\"', '"').replace("\\n", "\n").replace("\\@", "@").replace("\\?", "?")


def strings() -> None:
    target = OUT / "strings"
    target.mkdir(parents=True, exist_ok=True)
    english = {}
    for lang, folder in LANG_DIRS.items():
        table = {}
        for path in sorted((RES / folder).glob("*.xml")):
            try:
                root = ET.parse(path).getroot()
            except ET.ParseError:
                continue
            for node in root.iter("string"):
                if node.get("translatable") == "false" and lang != "en":
                    continue
                table[node.get("name")] = android_unescape("".join(node.itertext()))
        if lang == "en":
            english = table
        else:
            for key, value in english.items():
                table.setdefault(key, value)
        (target / (lang + ".json")).write_text(json.dumps(table, ensure_ascii=False, indent=0, sort_keys=True), encoding="utf-8")
        print(lang, len(table), "strings")


def texts() -> None:
    """Screensaver texts (347 quotations + 99 Names, 10 languages): the same slim files the web version uses,
    built from the published shared screensaver package."""
    src = HERE.parent / "mihrap-web" / "site" / "mihrap" / "data" / "texts"
    target = OUT / "texts"
    target.mkdir(parents=True, exist_ok=True)
    for path in src.glob("*.json"):
        shutil.copyfile(path, target / path.name)


def fonts() -> None:
    target = OUT / "fonts"
    target.mkdir(parents=True, exist_ok=True)
    for src, name in FONTS.items():
        shutil.copyfile(src, target / name)
    for path in WEB_FONTS.glob("*.ttf"):
        if path.name.startswith("scheherazade"):
            continue
        shutil.copyfile(path, target / path.name)


def photos() -> None:
    target = OUT / "home"
    target.mkdir(parents=True, exist_ok=True)
    for i, rel in enumerate(HOME_PHOTOS):
        img = Image.open(SALAHWIN / rel).convert("RGB")
        if img.width > 2560:
            img = img.resize((2560, round(img.height * 2560 / img.width)), Image.LANCZOS)
        img.save(target / ("photo%d.jpg" % i), quality=88)


def icon() -> None:
    icon_dir = ASSETS / "AppIcon.appiconset"
    icon_dir.mkdir(parents=True, exist_ok=True)
    art = Image.open(RES / "drawable" / "ic_launcher_art.png").convert("RGBA")
    canvas = Image.new("RGBA", art.size, (7, 26, 48, 255))
    canvas.alpha_composite(art)
    canvas.convert("RGB").resize((1024, 1024), Image.LANCZOS).save(icon_dir / "icon-1024.png", optimize=True)
    (icon_dir / "Contents.json").write_text(json.dumps({
        "images": [{"filename": "icon-1024.png", "idiom": "universal", "platform": "ios", "size": "1024x1024"}],
        "info": {"author": "xcode", "version": 1}}, indent=2) + "\n", encoding="utf-8")
    (ASSETS / "Contents.json").write_text(json.dumps({"info": {"author": "xcode", "version": 1}}, indent=2) + "\n", encoding="utf-8")
    color = ASSETS / "LaunchBackground.colorset"
    color.mkdir(exist_ok=True)
    (color / "Contents.json").write_text(json.dumps({
        "colors": [{"idiom": "universal", "color": {"color-space": "srgb", "components": {
            "red": "0.027", "green": "0.102", "blue": "0.188", "alpha": "1.000"}}}],
        "info": {"author": "xcode", "version": 1}}, indent=2) + "\n", encoding="utf-8")


if __name__ == "__main__":
    strings()
    texts()
    fonts()
    photos()
    icon()
    size = sum(p.stat().st_size for p in OUT.rglob("*") if p.is_file())
    print("resources: %.1f MB" % (size / 1048576))
