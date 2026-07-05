#!/usr/bin/env python3
"""Validate release/build contract for the TrollStore IPA workflow."""

from __future__ import annotations

import re
import sys
from pathlib import Path


PROJECT_ROOT = Path(__file__).resolve().parent.parent


FILES = {
    "project": PROJECT_ROOT / "project.yml",
    "workflow": PROJECT_ROOT / ".github" / "workflows" / "build-trollstore-ipa.yml",
    "macos_build": PROJECT_ROOT / "Scripts" / "build_ipa_macos.sh",
    "package": PROJECT_ROOT / "Scripts" / "package_ipa.sh",
    "github_api_builder": PROJECT_ROOT / "Build-IPA-With-GitHubApi.ps1",
    "public_repo_builder": PROJECT_ROOT / "Build-IPA-With-GitHubApi-PublicRepo.ps1",
    "app_source": PROJECT_ROOT / "Sources" / "ChatGPTWebView.swift",
}


REQUIRED = {
    "project": {
        "iOS deployment target 16.0": 'deploymentTarget:\n    iOS: "16.0"',
        "iPhone OS target": 'IPHONEOS_DEPLOYMENT_TARGET: "16.0"',
        "iPhone only target family": 'TARGETED_DEVICE_FAMILY: "1"',
        "bundle display name": "CFBundleDisplayName: ChatGPT",
        "bundle name": "CFBundleName: GPTNative",
        "ProMotion unlock": "CADisableMinimumFrameDurationOnPhone: true",
        "requires iPhone OS": "LSRequiresIPhoneOS: true",
        "full screen": "UIRequiresFullScreen: true",
        "iPhone device family": "UIDeviceFamily:\n          - 1",
        "portrait only": "UISupportedInterfaceOrientations:\n          - UIInterfaceOrientationPortrait",
    },
    "workflow": {
        "GitHub macOS runner": "runs-on: macos-latest",
        "manual dispatch": "workflow_dispatch:",
        "image save gate": "Verify image save bridge",
        "native image menu gate": "Verify native image menu config",
        "page appearance gate": "Verify page appearance bridge",
        "native surface gate": "Verify native surface config",
        "native performance gate": "Verify native performance config",
        "network error gate": "Verify network error messages",
        "packaged IPA gate": "Verify packaged IPA",
        "xcodegen install": "brew install xcodegen ldid",
        "macOS build script": "Scripts/build_ipa_macos.sh",
        "artifact upload": "uses: actions/upload-artifact@v4",
        "IPA artifact path": "path: build/GPTNative.ipa",
    },
    "macos_build": {
        "xcodegen project generation": "xcodegen generate",
        "release build": "-configuration Release",
        "iPhoneOS SDK": "-sdk iphoneos",
        "unsigned build for TrollStore": "CODE_SIGNING_ALLOWED=NO",
        "package script called": "Scripts/package_ipa.sh",
    },
    "package": {
        "find release app": "Release-iphoneos/*.app",
        "Payload directory": "mkdir -p build/Payload",
        "copy app to Payload": 'cp -R "$APP_PATH" build/Payload/',
        "zip Payload as IPA": '/usr/bin/zip -qry "GPTNative.ipa" Payload',
    },
    "github_api_builder": {
        "GitHub REST API base": '$ApiBase = "https://api.github.com"',
        "REST method": "Invoke-RestMethod",
        "web request download": "Invoke-WebRequest",
        "workflow dispatch": "/dispatches",
        "artifact download": "archive_download_url",
    },
    "public_repo_builder": {
        "public repo visibility": "-RepoVisibility public",
        "delegates to GitHub API builder": "Build-IPA-With-GitHubApi.ps1",
    },
    "app_source": {
        "official ChatGPT URL": 'URL(string: "https://chatgpt.com/")!',
        "ChatGPT host guard": 'host == "chatgpt.com" || host.hasSuffix(".chatgpt.com")',
        "iOS 16.4 Safari user agent": "iPhone OS 16_4",
    },
}


FORBIDDEN_REGEX = {
    "workflow": {
        "gh CLI in workflow": r"(^|\s)gh(\.exe)?(\s|$)",
    },
    "github_api_builder": {
        "gh CLI in GitHub API builder": r"(^|\s)gh(\.exe)?(\s|$)",
    },
    "app_source": {
        "direct OpenAI API client": r"api\.openai\.com",
    },
}


def fail(message: str) -> None:
    raise SystemExit(f"verify_release_contract: {message}")


def read_file(key: str) -> str:
    path = FILES[key]
    if not path.is_file():
        fail(f"missing required file for {key}: {path}")
    return path.read_text(encoding="utf-8")


def main() -> int:
    contents = {key: read_file(key) for key in FILES}

    missing: list[str] = []
    for key, checks in REQUIRED.items():
        source = contents[key]
        for name, snippet in checks.items():
            if snippet not in source:
                missing.append(f"{key}: {name}")
    if missing:
        fail("missing release contract settings: " + ", ".join(missing))

    forbidden: list[str] = []
    for key, checks in FORBIDDEN_REGEX.items():
        source = contents[key]
        for name, pattern in checks.items():
            if re.search(pattern, source, flags=re.MULTILINE):
                forbidden.append(f"{key}: {name}")
    if forbidden:
        fail("forbidden release contract regression present: " + ", ".join(forbidden))

    print("release contract checks ok")
    return 0


if __name__ == "__main__":
    sys.exit(main())
