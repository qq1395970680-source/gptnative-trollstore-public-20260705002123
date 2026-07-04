#!/usr/bin/env python3
"""Validate native WKWebView and menu settings related to smoothness."""

from __future__ import annotations

import sys
from pathlib import Path


PROJECT_ROOT = Path(__file__).resolve().parent.parent
SOURCE_PATH = PROJECT_ROOT / "Sources" / "ChatGPTWebView.swift"

REQUIRED_SNIPPETS = {
    "vertical scroll indicator hidden": "webView.scrollView.showsVerticalScrollIndicator = false",
    "horizontal scroll indicator hidden": "webView.scrollView.showsHorizontalScrollIndicator = false",
    "interactive keyboard dismissal": "webView.scrollView.keyboardDismissMode = .interactive",
    "touch delivery without delay": "webView.scrollView.delaysContentTouches = false",
    "touch cancellation enabled": "webView.scrollView.canCancelContentTouches = true",
    "fast scroll deceleration": "webView.scrollView.decelerationRate = .fast",
    "horizontal bounce disabled": "webView.scrollView.alwaysBounceHorizontal = false",
    "web view async drawing": "webView.layer.drawsAsynchronously = true",
    "scroll view async drawing": "webView.scrollView.layer.drawsAsynchronously = true",
    "link preview disabled": "webView.allowsLinkPreview = false",
    "custom menu short present duration": "withDuration: 0.16",
    "custom menu short dismiss duration": "UIView.animate(withDuration: 0.14",
    "custom menu non-spring present": "options: [.curveEaseOut, .allowUserInteraction, .beginFromCurrentState]",
    "long press not swallowing touches": "recognizer.cancelsTouchesInView = false",
    "long press movement tolerance": "recognizer.allowableMovement = 18",
}

FORBIDDEN_SNIPPETS = {
    "springy menu animation": "usingSpringWithDamping",
    "normal scroll deceleration": "webView.scrollView.decelerationRate = .normal",
    "visible vertical indicator": "webView.scrollView.showsVerticalScrollIndicator = true",
    "visible horizontal indicator": "webView.scrollView.showsHorizontalScrollIndicator = true",
}


def fail(message: str) -> None:
    raise SystemExit(f"verify_native_performance_config: {message}")


def main() -> int:
    if not SOURCE_PATH.is_file():
        fail(f"missing source file: {SOURCE_PATH}")

    source = SOURCE_PATH.read_text(encoding="utf-8")
    missing = [name for name, snippet in REQUIRED_SNIPPETS.items() if snippet not in source]
    if missing:
        fail("missing required smoothness settings: " + ", ".join(missing))

    forbidden = [name for name, snippet in FORBIDDEN_SNIPPETS.items() if snippet in source]
    if forbidden:
        fail("forbidden regression settings present: " + ", ".join(forbidden))

    print("native performance config checks ok")
    return 0


if __name__ == "__main__":
    sys.exit(main())
