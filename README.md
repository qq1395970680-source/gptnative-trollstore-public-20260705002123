# ChatGPT Login Wrapper

This project builds an iOS 16+ TrollStore IPA that opens the official ChatGPT web app in a full-screen WKWebView.

It uses your normal ChatGPT account login at `https://chatgpt.com/`. It does not use an OpenAI API key and does not call the OpenAI API directly.

## Behavior

- Opens `https://chatgpt.com/`.
- Keeps login cookies with the default WKWebView data store.
- Reloads the ChatGPT home/new-chat entry when the app becomes active.
- Uses a full-screen app surface with only a slim loading indicator.
- Targets iPhone / arm64 / iOS 16.0+.

## Build

From Windows, use:

```powershell
$env:GITHUB_TOKEN = "YOUR_TOKEN"
.\Build-IPA-With-GitHubApi.ps1 -Repo "OWNER/REPO" -CreateRepo
```

The script uploads a clean repository tree through `https://api.github.com`, runs `.github/workflows/build-trollstore-ipa.yml`, and downloads the IPA artifact.

## Verification

The GitHub Actions build runs four verification gates:

```powershell
python Scripts\verify_all.py --ipa ..\..\outputs\GPTNative.ipa
```

Or run the gates individually:

```powershell
node Scripts\verify_image_save_bridge.js
node Scripts\verify_page_appearance_bridge.js
python Scripts\verify_native_performance_config.py
python Scripts\verify_packaged_ipa.py ..\..\outputs\GPTNative.ipa
```

The image-save check extracts the real injected script from `Sources/ChatGPTWebView.swift` and verifies image long-press hit testing, composer/header non-misfires, canvas/background/link detection, and data-image filename handling.
The page appearance check verifies viewport-fit, unified top/header surface painting, scrollbar hiding CSS, bottom composer safe-area offsetting, scroll padding, media scroll margins, and the mobile drawer mask.
The native performance check verifies the WKWebView scroll/touch settings, hidden scroll indicators, async drawing flags, and short non-spring custom menu animations.
The packaged IPA check verifies the `Payload/*.app` structure, executable, display name, iOS minimum version, portrait-only orientation, full-screen flag, and the ProMotion unlock key.
