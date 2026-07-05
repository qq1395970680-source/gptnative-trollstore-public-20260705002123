#!/usr/bin/env python3
"""Validate that the packaged IPA executable contains the shipped behavior markers."""

from __future__ import annotations

import argparse
import plistlib
import sys
import zipfile
from pathlib import Path


REQUIRED_EXECUTABLE_MARKERS = {
    "image hit-test bridge": b"gptNativeImageAtPoint",
    "single image save bridge": b"gptNativeSaveURL",
    "batch image save bridge": b"gptNativeSaveAll",
    "page safe-area applier": b"gptNativeApplySafeArea",
    "drawer mask": b"gpt-native-drawer-mask",
    "top safe-area mask": b"gpt-native-top-surface-mask",
    "native status safe-area cover": b"gpt-native-status-surface-cover",
    "scrollbar hiding CSS": b"scrollbar-width",
    "composer clearance CSS variable": b"gpt-native-composer-clearance",
    "official ChatGPT host": b"chatgpt.com",
}


def fail(message: str) -> None:
    raise SystemExit(f"verify_packaged_behavior_markers: {message}")


def app_root_from_zip(names: list[str]) -> str:
    roots = sorted(
        {
            "/".join(name.split("/")[:2]) + "/"
            for name in names
            if name.startswith("Payload/")
            and len(name.split("/")) >= 3
            and name.split("/")[1].endswith(".app")
        }
    )
    if len(roots) != 1:
        fail(f"expected one Payload/*.app bundle, found {len(roots)}")
    return roots[0]


def validate(ipa_path: Path) -> None:
    if not ipa_path.is_file():
        fail(f"missing IPA: {ipa_path}")

    try:
        with zipfile.ZipFile(ipa_path, "r") as archive:
            names = archive.namelist()
            app_root = app_root_from_zip(names)
            plist_name = f"{app_root}Info.plist"
            if plist_name not in names:
                fail(f"missing {plist_name}")

            plist = plistlib.loads(archive.read(plist_name))
            executable = plist.get("CFBundleExecutable")
            if not executable:
                fail("CFBundleExecutable is missing")

            executable_name = f"{app_root}{executable}"
            if executable_name not in names:
                fail(f"missing executable {executable_name}")

            executable_data = archive.read(executable_name)
    except zipfile.BadZipFile as error:
        fail(f"invalid zip/ipa: {error}")

    missing = [
        name for name, marker in REQUIRED_EXECUTABLE_MARKERS.items()
        if marker not in executable_data
    ]
    if missing:
        fail("missing packaged behavior markers: " + ", ".join(missing))

    print(f"packaged behavior markers ok: {ipa_path}")


def main() -> int:
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("ipa", nargs="?", default="build/GPTNative.ipa", help="Path to the IPA to validate.")
    args = parser.parse_args()
    validate(Path(args.ipa))
    return 0


if __name__ == "__main__":
    sys.exit(main())
