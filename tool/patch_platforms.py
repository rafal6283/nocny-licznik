#!/usr/bin/env python3
"""Poprawki nakładane na katalogi wygenerowane przez `flutter create`.

Idempotentne — można uruchamiać wielokrotnie.
"""
import json
import os
import plistlib
import re
import sys
from pathlib import Path

ROOT = Path(__file__).resolve().parent.parent
APP_NAME = "Bąkometr"


def log(msg):
    print(f"[patch] {msg}")


def icon_source():
    try:
        from PIL import Image  # noqa
    except ImportError:
        log("brak Pillow — pomijam ikony")
        return None
    p = ROOT / "assets" / "icon.png"
    return p if p.exists() else None


def resize(src, dst, px):
    from PIL import Image

    im = Image.open(src).convert("RGB").resize((px, px), Image.LANCZOS)
    dst.parent.mkdir(parents=True, exist_ok=True)
    im.save(dst)


# ----------------------------------------------------------------- Android
def patch_android():
    app = ROOT / "android" / "app"
    if not app.exists():
        return
    gradle = app / "build.gradle.kts"
    kts = gradle.exists()
    if not kts:
        gradle = app / "build.gradle"
    g = gradle.read_text()
    g = re.sub(r"minSdk\s*=\s*flutter\.minSdkVersion", "minSdk = 26", g)
    g = re.sub(r"minSdkVersion\s+flutter\.minSdkVersion", "minSdkVersion 26", g)

    if os.environ.get("BAKOMETR_KEYSTORE") and "BAKOMETR_KEYSTORE" not in g:
        if kts:
            block = '''    signingConfigs {
        create("release") {
            storeFile = file(System.getenv("BAKOMETR_KEYSTORE"))
            storePassword = System.getenv("BAKOMETR_STORE_PASS")
            keyAlias = System.getenv("BAKOMETR_KEY_ALIAS")
            keyPassword = System.getenv("BAKOMETR_KEY_PASS")
        }
    }

    buildTypes {'''
            g = g.replace("    buildTypes {", block, 1)
            g = g.replace('signingConfig = signingConfigs.getByName("debug")',
                          'signingConfig = signingConfigs.getByName("release")')
        else:
            block = '''    signingConfigs {
        release {
            storeFile file(System.getenv("BAKOMETR_KEYSTORE"))
            storePassword System.getenv("BAKOMETR_STORE_PASS")
            keyAlias System.getenv("BAKOMETR_KEY_ALIAS")
            keyPassword System.getenv("BAKOMETR_KEY_PASS")
        }
    }

    buildTypes {'''
            g = g.replace("    buildTypes {", block, 1)
            g = g.replace("signingConfig = signingConfigs.debug", "signingConfig = signingConfigs.release")
            g = g.replace("signingConfig signingConfigs.debug", "signingConfig signingConfigs.release")
        log("podpis wydania: własny klucz")
    gradle.write_text(g)
    log(f"{gradle.name}: minSdk 26")

    # Starsze pluginy (np. tflite_flutter) mają inny cel JVM dla Javy i Kotlina —
    # nowe wersje Kotlina traktują to jako błąd; obniżamy do ostrzeżenia.
    props = ROOT / "android" / "gradle.properties"
    pt = props.read_text() if props.exists() else ""
    if "kotlin.jvm.target.validation.mode" not in pt:
        props.write_text(pt.rstrip("\n") + "\nkotlin.jvm.target.validation.mode=warning\n")
        log("gradle.properties: walidacja celu JVM jako ostrzeżenie")

    manifest = app / "src" / "main" / "AndroidManifest.xml"
    m = manifest.read_text()
    m = re.sub(r'android:label="[^"]*"', f'android:label="{APP_NAME}"', m, count=1)
    manifest.write_text(m)
    log("AndroidManifest: nazwa aplikacji")

    src = icon_source()
    if src:
        sizes = {"mdpi": 48, "hdpi": 72, "xhdpi": 96, "xxhdpi": 144, "xxxhdpi": 192}
        for d, px in sizes.items():
            resize(src, app / "src" / "main" / "res" / f"mipmap-{d}" / "ic_launcher.png", px)
        log("ikony Androida")


# --------------------------------------------------------------------- iOS
def patch_ios():
    runner = ROOT / "ios" / "Runner"
    if not runner.exists():
        return
    plist_path = runner / "Info.plist"
    with open(plist_path, "rb") as f:
        pl = plistlib.load(f)
    pl["CFBundleDisplayName"] = APP_NAME
    pl["NSMicrophoneUsageDescription"] = (
        "Bąkometr nasłuchuje w nocy, żeby rozpoznać wiatry, chrapanie, mówienie i kaszel. "
        "Dźwięk jest analizowany na telefonie i nigdzie nie jest wysyłany.")
    pl["NSCameraUsageDescription"] = (
        "iPhone nie udostępnia czujnika światła, więc Bąkometr na chwilę włącza przednią kamerę, "
        "żeby oszacować jasność w sypialni. Żadne zdjęcia nie są zapisywane.")
    modes = set(pl.get("UIBackgroundModes", []))
    modes.add("audio")
    pl["UIBackgroundModes"] = sorted(modes)
    with open(plist_path, "wb") as f:
        plistlib.dump(pl, f)
    log("Info.plist: uprawnienia i tryb audio w tle")

    podfile = ROOT / "ios" / "Podfile"
    if podfile.exists():
        p = podfile.read_text()
        p = re.sub(r"^#?\s*platform :ios, '[0-9.]+'", "platform :ios, '13.0'", p, flags=re.M)
        podfile.write_text(p)
        log("Podfile: iOS 13")

    src = icon_source()
    iconset = runner / "Assets.xcassets" / "AppIcon.appiconset"
    contents = iconset / "Contents.json"
    if src and contents.exists():
        data = json.loads(contents.read_text())
        for img in data.get("images", []):
            fn = img.get("filename")
            if not fn:
                continue
            base = float(img["size"].split("x")[0])
            scale = int(img.get("scale", "1x").rstrip("x"))
            resize(src, iconset / fn, int(round(base * scale)))
        log("ikony iOS")


if __name__ == "__main__":
    only = sys.argv[1:] or ["android", "ios"]
    if "android" in only:
        patch_android()
    if "ios" in only:
        patch_ios()
