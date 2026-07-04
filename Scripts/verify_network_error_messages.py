#!/usr/bin/env python3
"""Validate native network/SSL error guidance strings."""

from __future__ import annotations

import sys
from pathlib import Path


PROJECT_ROOT = Path(__file__).resolve().parent.parent
SOURCE_PATH = PROJECT_ROOT / "Sources" / "ChatGPTWebView.swift"

REQUIRED_SNIPPETS = {
    "custom connection message function": "userFacingConnectionMessage(for error: NSError)",
    "ssl secure connection handling": "NSURLErrorSecureConnectionFailed",
    "certificate untrusted handling": "NSURLErrorServerCertificateUntrusted",
    "cellular/wifi clarification": "不是只能在 Wi-Fi 下使用",
    "proxy/node guidance": "节点/代理",
    "network timeout guidance": "连接 ChatGPT 超时或中断",
    "not connected guidance": "当前没有网络连接",
}


def fail(message: str) -> None:
    raise SystemExit(f"verify_network_error_messages: {message}")


def main() -> int:
    if not SOURCE_PATH.is_file():
        fail(f"missing source file: {SOURCE_PATH}")

    source = SOURCE_PATH.read_text(encoding="utf-8")
    missing = [name for name, snippet in REQUIRED_SNIPPETS.items() if snippet not in source]
    if missing:
        fail("missing network error guidance: " + ", ".join(missing))

    print("network error message checks ok")
    return 0


if __name__ == "__main__":
    sys.exit(main())
