<div align="center">

<img src="LiveTranslateBridge/Assets.xcassets/AppIcon.appiconset/AppIcon-256.png" width="112" alt="LiveTranslateBridge app icon">

# LiveTranslateBridge

**Real-time speech translation and bilingual subtitles for macOS — translate calls, meetings, and any app's audio as you listen.**

[![Release](https://img.shields.io/github/v/release/hoobnn/livetranslate-bridge?style=flat-square)](https://github.com/hoobnn/livetranslate-bridge/releases/latest)
[![CI](https://img.shields.io/github/actions/workflow/status/hoobnn/livetranslate-bridge/ci.yml?branch=main&style=flat-square&label=CI)](https://github.com/hoobnn/livetranslate-bridge/actions/workflows/ci.yml)
[![macOS](https://img.shields.io/badge/macOS-27%2B-black?style=flat-square&logo=apple)](https://www.apple.com/macos/)
[![Apple Silicon](https://img.shields.io/badge/Apple%20Silicon-only-555?style=flat-square)](#quick-start)
[![Homebrew](https://img.shields.io/badge/brew-livetranslate--bridge-FBB040?style=flat-square&logo=homebrew&logoColor=white)](#quick-start)
[![License](https://img.shields.io/badge/license-MIT-green?style=flat-square)](LICENSE)

English · [简体中文](README.zh.md)

</div>

LiveTranslateBridge is an open-source macOS app for live speech translation. It captures audio from any app (iPhone calls answered on your Mac, video meetings, browsers, media players) together with your microphone, sends it to Alibaba Cloud's Qwen real-time translation model (qwen3.8 LiveTranslate), and produces **two-way subtitles** and **translated speech**. Original and translated audio are routed to the output devices you choose at independent volumes — you read and hear the other side in your language, and they hear you in theirs.

<picture>
  <source media="(prefers-color-scheme: dark)" srcset="docs/assets/product/app-subtitles-dark.jpg">
  <img src="docs/assets/product/app-subtitles-light.jpg" alt="LiveTranslateBridge macOS live translation window with Chinese and English two-way subtitles in side-by-side columns">
</picture>

<sub>Screenshot of the app's built-in sample subtitle preview; it follows GitHub's light/dark theme and contains no real call content.</sub>

## Use cases

- **iPhone calls on your Mac** (Continuity): translate what the other person says in real time, and translate your replies for them.
- **Multilingual video meetings**: capture the meeting app's audio for bilingual captions; with a loopback audio device, send your translated voice into the meeting.
- **Foreign-language streams, videos, and lectures**: capture only the browser or player and get live subtitles.
- **Transcription**: skip translation and keep a timestamped record of both sides, then export it to Markdown or Word.

## Features

- **Two-way translation**: the other side is translated into your language and you into theirs, with subtitles interleaved by time in two columns.
- **8 common languages**: Chinese, English, Japanese, Korean, French, German, Spanish, and Russian, chosen separately for each side.
- **Transcription mode**: records the original speech only — no translation or spoken output — and both sides may use the same language.
- **Any audio source**: capture any app, including every process of multi-process apps such as browsers. The default is `avconferenced`, the system process that plays Continuity call audio when your Mac answers an iPhone call.
- **Capture scope**: both sides, far end only (app audio), or me only (microphone).
- **Audio routing**: pick separate output devices for "What I hear" and "What others hear", with independent 0–200% volumes for original and translated audio and optional ducking of the original while the translation speaks.
- **Feedback-loop guard**: refuses to start when the microphone and an output form a loop, and tells you why.
- **Voice cloning**: optionally speak translations in each speaker's own voice.
- **Aggregate devices**: use an aggregate device or multi-channel interface as the microphone; every member channel is captured, and loopback members still trigger the feedback-loop guard.
- **Glossary**: one `term = translation` per line to keep names and product terms consistent.
- **Lower usage**: uploads pause while the far end is fully silent, and optionally during long microphone silence. When a side's translated volume is 0, only text is requested.
- **Session history**: subtitles from each session are saved locally (`~/Library/Application Support/com.ikuyu.livetranslate-bridge/Sessions`) and can be reread, searched, and deleted on the History tab; turn it off in Settings › General.
- **Export**: export the current board or any saved session to Markdown, plain text, or Word (.docx) via File › Export as Document… (⇧⌘E).
- **Diagnostics**: inspect the source process and both sides' levels, replay samples offline to test the translation pipeline, and clean up aggregate devices left behind by a crash.
- **Native UI**: built with SwiftUI, with a Chinese/English interface you can switch instantly, Liquid Glass, and light and dark appearances.

## Quick start

**Requirements:** macOS 27 or later on Apple Silicon.

Install with Homebrew:

```bash
brew install --cask hoobnn/tap/livetranslate-bridge
```

Or download the signed and Apple-notarized DMG from [GitHub Releases](https://github.com/hoobnn/livetranslate-bridge/releases/latest).

1. Get an API key and workspace ID from [Alibaba Cloud Model Studio](https://modelstudio.console.alibabacloud.com/) (international) or [Bailian](https://bailian.console.aliyun.com/) (mainland China).
2. Open Settings (⌘,), enter both values — they are stored in your login keychain — and under Service pick the region that matches your account (Singapore or China North 2 (Beijing)).
3. In Audio Routing, choose the audio source, microphone, and output devices for both sides.
4. Back on the Subtitles tab, pick the two languages and click Start. On first use macOS asks for system audio recording and microphone permission.

## Send translated speech into a meeting or call app

You need a loopback audio device such as [BlackHole](https://existential.audio/blackhole/):

1. Set the "What others hear" output to the loopback device.
2. In the meeting or call app, set the input to the same loopback device.
3. In LiveTranslateBridge, keep a real microphone as the input; otherwise the app captures its own translated voice again.

## FAQ

**Does it work with Zoom, Microsoft Teams, Google Meet, or other meeting apps?**
Yes. Audio is captured per app rather than through a specific integration, so pick the meeting app (or the browser running it) as the audio source. iPhone Continuity calls are played by the system process `avconferenced`, which is the default source (see the [call audio findings](docs/findings.md), in Chinese).

**Does it record calls? Where is my data?**
No audio is recorded. Audio is streamed to the Model Studio service under your own account for translation; only subtitle text is kept on your Mac, and you can turn that off or delete it at any time.

**How much delay is there in the translated speech?**
Translated speech trails the original by 1–3 seconds and speeds up automatically when it falls behind.

**Is it free?**
The app is free and open source. Translation is billed to your own Model Studio account at the model's standard rates; pausing on silence and requesting text only both reduce usage.

**Does it support Intel Macs or older macOS versions?**
No. The current release requires macOS 27 or later and ships for Apple Silicon only.

## Build from source

Requires Xcode 27.

```bash
open LiveTranslateBridge.xcodeproj    # run from Xcode
./scripts/build-app.sh                # or build an unsigned dist/LiveTranslateBridge.app from the command line
```

For debugging, the environment variables `DASHSCOPE_API_KEY` / `DASHSCOPE_WORKSPACE_ID` override the credentials stored in the keychain.

## Releases

Pushes to main and pull requests run unit tests only (`.github/workflows/ci.yml`). Pushing a `v*` tag runs `.github/workflows/release.yml`, which runs the same tests, then builds, signs with Developer ID, notarizes, publishes the GitHub Release, and updates the Homebrew tap. The tag version must match `MARKETING_VERSION` in the project.

## Limitations

- **Not sandboxed**: process taps and aggregate devices are rejected inside the sandbox, so the app can't ship on the Mac App Store.
- **No audio recording**: only subtitle text is saved, never audio. Recording a call generally requires consent from everyone on it.
- **No echo cancellation**: on speakers, the microphone picks up the other side and the translated voice. Headphones or a loopback output avoid this.
- **Translation delay**: translated speech trails the original by 1–3 seconds and speeds up when it falls behind. If you don't want them to overlap, set that side's original volume to 0.

## Documentation

Design notes are written in Chinese.

- [Changelog](CHANGELOG.md)
- [Continuity call audio findings](docs/findings.md)
- [Capture pipeline rework](docs/audio-capture-2026-09-23.md) · [Audio optimization](docs/audio-optimization-2026-09-22.md) · [Network and uplink optimization](docs/network-audio-optimization-2026-09-28.md)
- [qwen3.8 protocol integration](docs/qwen38-protocol-validation-2026-09-22.md) · [Server-side segmentation](docs/server-segmentation-2026-09-22.md)

## License

[MIT](LICENSE)
