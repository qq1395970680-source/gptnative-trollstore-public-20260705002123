#!/usr/bin/env python3
"""Run all local verification gates for GPTNative."""

from __future__ import annotations

import argparse
import subprocess
import sys
from pathlib import Path


PROJECT_ROOT = Path(__file__).resolve().parent.parent
DEFAULT_IPA_CANDIDATES = [
    PROJECT_ROOT / "build" / "GPTNative.ipa",
    PROJECT_ROOT.parent.parent / "outputs" / "GPTNative.ipa",
]


def run(command: list[str]) -> None:
    print("+ " + " ".join(command), flush=True)
    subprocess.run(command, cwd=PROJECT_ROOT, check=True)


def default_ipa_path() -> Path:
    for candidate in DEFAULT_IPA_CANDIDATES:
        if candidate.is_file():
            return candidate

    return DEFAULT_IPA_CANDIDATES[0]


def main() -> int:
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument(
        "--ipa",
        default=str(default_ipa_path()),
        help="IPA path for the packaged-IPA check. Defaults to build/GPTNative.ipa, then the workspace outputs IPA.",
    )
    args = parser.parse_args()
    ipa_path = Path(args.ipa)
    if not ipa_path.is_absolute():
        ipa_path = (Path.cwd() / ipa_path).resolve()

    run(["node", "Scripts/verify_image_save_bridge.js"])
    run(["node", "Scripts/verify_page_appearance_bridge.js"])
    run([sys.executable, "Scripts/verify_native_performance_config.py"])
    run([sys.executable, "Scripts/verify_network_error_messages.py"])
    run([sys.executable, "Scripts/verify_packaged_ipa.py", str(ipa_path)])
    print("all verification gates ok")
    return 0


if __name__ == "__main__":
    sys.exit(main())
