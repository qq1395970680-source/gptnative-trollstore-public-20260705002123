#!/usr/bin/env python3
"""Validate native surface and status-safe-area background handling."""

from __future__ import annotations

import re
import sys
from pathlib import Path


PROJECT_ROOT = Path(__file__).resolve().parent.parent
SOURCE_PATH = PROJECT_ROOT / "Sources" / "ChatGPTWebView.swift"


REQUIRED_SNIPPETS = {
    "pure white light surface": "static let light = UIColor.white",
    "ChatGPT dark surface": "static let dark = UIColor(red: 33.0 / 255.0, green: 33.0 / 255.0, blue: 33.0 / 255.0, alpha: 1)",
    "window surface configurator": "private struct WindowSurfaceConfigurator: UIViewRepresentable",
    "status surface cover storage": "private weak var statusSurfaceCover: UIView?",
    "status surface cover id": 'newCover.accessibilityIdentifier = "gpt-native-status-surface-cover"',
    "status surface cover noninteractive": "newCover.isUserInteractionEnabled = false",
    "status surface cover above app content": "newCover.layer.zPosition = CGFloat.greatestFiniteMagnitude",
    "status surface cover added to window": "window.addSubview(newCover)",
    "status surface uses safe-area height": "let topInset = max(window.safeAreaInsets.top, 0)",
    "status surface frame uses window bounds": "cover.frame = CGRect(x: 0, y: 0, width: window.bounds.width, height: topInset)",
    "window background applied": "window?.backgroundColor = surface",
    "root view background applied": "window?.rootViewController?.view.backgroundColor = surface",
    "ancestor backgrounds applied": "while let view = ancestor",
    "root SwiftUI surface ignores top and bottom": ".ignoresSafeArea(.container, edges: [.top, .bottom])",
    "web container stays below status bar": ".ignoresSafeArea(.container, edges: .bottom)",
    "top safe area overlay": "private var topSafeAreaSurface: some View",
    "top overlay reads safe inset": ".frame(height: proxy.safeAreaInsets.top)",
    "top overlay noninteractive": ".allowsHitTesting(false)",
    "web scroll surface": "webView.scrollView.backgroundColor = ChatGPTSurface.dynamic",
    "web view surface": "webView.backgroundColor = ChatGPTSurface.dynamic",
    "web under-page surface": "webView.underPageBackgroundColor = ChatGPTSurface.dynamic",
}

REQUIRED_PATTERNS = {
    "window cover updater called from applySurface": r"func applySurface\(\)[\s\S]*?updateStatusSurfaceCover\(surface\)",
    "layout refresh reapplies surface": r"override func layoutSubviews\(\)[\s\S]*?applySurface\(\)",
    "top safe-area surface ignores top edge": r"private var topSafeAreaSurface[\s\S]*?ignoresSafeArea\(\.container, edges: \.top\)",
    "launch overlay uses native surface": r"private var launchOverlay[\s\S]*?\.background\(Color\(uiColor: ChatGPTSurface\.dynamic\)\)",
    "connection error uses native surface": r"private func connectionError[\s\S]*?\.background\(Color\(uiColor: ChatGPTSurface\.dynamic\)\)",
}

FORBIDDEN_SNIPPETS = {
    "web container ignoring top safe area": ".ignoresSafeArea(.container, edges: [.top, .bottom])\n\n            topSafeAreaSurface",
}


def fail(message: str) -> None:
    raise SystemExit(f"verify_native_surface_config: {message}")


def main() -> int:
    if not SOURCE_PATH.is_file():
        fail(f"missing source file: {SOURCE_PATH}")

    source = SOURCE_PATH.read_text(encoding="utf-8")

    missing = [name for name, snippet in REQUIRED_SNIPPETS.items() if snippet not in source]
    if missing:
        fail("missing required surface settings: " + ", ".join(missing))

    missing_patterns = [name for name, pattern in REQUIRED_PATTERNS.items() if not re.search(pattern, source)]
    if missing_patterns:
        fail("missing required surface patterns: " + ", ".join(missing_patterns))

    forbidden = [name for name, snippet in FORBIDDEN_SNIPPETS.items() if snippet in source]
    if forbidden:
        fail("forbidden surface regression present: " + ", ".join(forbidden))

    print("native surface config checks ok")
    return 0


if __name__ == "__main__":
    sys.exit(main())
