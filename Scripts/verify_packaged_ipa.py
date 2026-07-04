#!/usr/bin/env python3
"""Validate the packaged TrollStore IPA before uploading it."""

from __future__ import annotations

import argparse
import plistlib
import sys
import zipfile
from pathlib import Path


REQUIRED_PLIST_VALUES = {
    "CFBundleDisplayName": "ChatGPT",
    "CFBundleName": "GPTNative",
    "CADisableMinimumFrameDurationOnPhone": True,
    "UIRequiresFullScreen": True,
    "LSRequiresIPhoneOS": True,
    "MinimumOSVersion": "16.0",
}


def fail(message: str) -> None:
    raise SystemExit(f"verify_packaged_ipa: {message}")


def app_root_from_zip(names: list[str]) -> str:
    app_roots = sorted(
        {
            "/".join(name.split("/")[:2]) + "/"
            for name in names
            if name.startswith("Payload/")
            and len(name.split("/")) >= 3
            and name.split("/")[1].endswith(".app")
        }
    )

    if not app_roots:
        fail("missing Payload/*.app bundle")

    if len(app_roots) != 1:
        fail(f"expected one app bundle, found {len(app_roots)}: {', '.join(app_roots)}")

    return app_roots[0]


def validate_ipa(ipa_path: Path) -> None:
    if not ipa_path.is_file():
        fail(f"missing IPA: {ipa_path}")

    if ipa_path.stat().st_size <= 0:
        fail(f"empty IPA: {ipa_path}")

    try:
        with zipfile.ZipFile(ipa_path, "r") as archive:
            bad_file = archive.testzip()
            if bad_file:
                fail(f"corrupt zip entry: {bad_file}")

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

            if archive.getinfo(executable_name).file_size <= 0:
                fail(f"empty executable {executable_name}")

            for key, expected in REQUIRED_PLIST_VALUES.items():
                actual = plist.get(key)
                if actual != expected:
                    fail(f"{key} expected {expected!r}, got {actual!r}")

            orientations = plist.get("UISupportedInterfaceOrientations") or []
            if orientations != ["UIInterfaceOrientationPortrait"]:
                fail(f"unexpected iPhone orientations: {orientations!r}")
    except zipfile.BadZipFile as error:
        fail(f"invalid zip/ipa: {error}")

    print(f"verify_packaged_ipa ok: {ipa_path}")


def main() -> int:
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("ipa", nargs="?", default="build/GPTNative.ipa", help="Path to the IPA to validate.")
    args = parser.parse_args()
    validate_ipa(Path(args.ipa))
    return 0


if __name__ == "__main__":
    sys.exit(main())
