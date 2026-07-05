#!/usr/bin/env python3
"""Validate the native long-press image menu wiring."""

from __future__ import annotations

import re
import sys
from pathlib import Path


PROJECT_ROOT = Path(__file__).resolve().parent.parent
SOURCE_PATH = PROJECT_ROOT / "Sources" / "ChatGPTWebView.swift"


REQUIRED_SNIPPETS = {
    "custom menu view": "private final class ImageSaveContextMenuView",
    "single save menu title": 'menuButton(title: "保存图片"',
    "batch save menu title": 'menuButton(title: "批量保存"',
    "menu save image callback": "var onSaveImage: (() -> Void)?",
    "menu save all callback": "var onSaveAll: (() -> Void)?",
    "short menu present animation": "withDuration: 0.16",
    "short menu dismiss animation": "UIView.animate(withDuration: 0.14",
    "long press recognizer storage": "private var imageLongPressRecognizer: UILongPressGestureRecognizer?",
    "long press recognizer install": "installImageLongPressRecognizer(on: webView)",
    "long press duration": "recognizer.minimumPressDuration = 0.42",
    "long press movement tolerance": "recognizer.allowableMovement = 18",
    "long press does not swallow web touches": "recognizer.cancelsTouchesInView = false",
    "gesture delegate": "recognizer.delegate = self",
    "simultaneous gestures allowed": "shouldRecognizeSimultaneouslyWith otherGestureRecognizer",
    "menu touch guard": "touchedView.isDescendant(of: menuView)",
    "point resolves through JS bridge": "window.__gptNativeImageAtPoint",
    "hit image resolves before presenting": "resolveHitImage(at: point, in: webView)",
    "native menu presentation": "presentImageActionMenu(for: contextImage, at: point, in: webView)",
    "menu added over webview": "webView.addSubview(menuView)",
    "menu present called": "menuView.present()",
    "single save calls bridge": "window.__gptNativeSaveURL",
    "batch save calls bridge": "window.__gptNativeSaveAll",
    "single save status": 'state?.showTransientMessage("正在保存图片...")',
    "save tool loading status": 'self?.state?.showTransientMessage("保存工具加载中")',
    "photo permission status": 'self.state?.showTransientMessage("需要相册权限")',
    "save success status": 'mode == "batch" ? nil : "已保存到相册"',
    "save failed status": 'self.state?.showTransientMessage("保存失败")',
}

REQUIRED_PATTERNS = {
    "long press begins before resolving image": r"@objc private func handleImageLongPress[\s\S]*?guard recognizer\.state == \.began[\s\S]*?resolveHitImage",
    "native menu has single action": r"menuView\.onSaveImage[\s\S]*?saveContextImage\(contextImage\.url",
    "native menu has batch action": r"menuView\.onSaveAll[\s\S]*?saveAllImages\(in: webView\)",
    "menu hides previous instance": r"private func presentImageActionMenu[\s\S]*?imageSaveContextMenuView\?\.dismiss\(animated: false\)",
    "menu stored weakly for touch guard": r"webView\.addSubview\(menuView\)[\s\S]*?imageSaveContextMenuView = menuView",
    "no spring animation in custom menu": r"ImageSaveContextMenuView[\s\S]*?UIView\.animate",
}

FORBIDDEN_SNIPPETS = {
    "spring menu animation": "usingSpringWithDamping",
    "long press swallowing web touches": "recognizer.cancelsTouchesInView = true",
    "visible persistent bottom save button": '.safeAreaInset(edge: .bottom',
    "legacy english save title": 'menuButton(title: "Save',
}


def fail(message: str) -> None:
    raise SystemExit(f"verify_native_image_menu_config: {message}")


def main() -> int:
    if not SOURCE_PATH.is_file():
        fail(f"missing source file: {SOURCE_PATH}")

    source = SOURCE_PATH.read_text(encoding="utf-8")

    missing = [name for name, snippet in REQUIRED_SNIPPETS.items() if snippet not in source]
    if missing:
        fail("missing required native image menu settings: " + ", ".join(missing))

    missing_patterns = [name for name, pattern in REQUIRED_PATTERNS.items() if not re.search(pattern, source)]
    if missing_patterns:
        fail("missing required native image menu patterns: " + ", ".join(missing_patterns))

    forbidden = [name for name, snippet in FORBIDDEN_SNIPPETS.items() if snippet in source]
    if forbidden:
        fail("forbidden native image menu regression present: " + ", ".join(forbidden))

    print("native image menu config checks ok")
    return 0


if __name__ == "__main__":
    sys.exit(main())
