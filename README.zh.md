<div align="center">

<img src="LiveTranslateBridge/Assets.xcassets/AppIcon.appiconset/AppIcon-256.png" width="112" alt="LiveTranslateBridge 应用图标">

# LiveTranslateBridge

**macOS 实时语音翻译与双语字幕：通话、会议、任意应用的声音，边听边译。**

[![Release](https://img.shields.io/github/v/release/hoobnn/livetranslate-bridge?style=flat-square)](https://github.com/hoobnn/livetranslate-bridge/releases/latest)
[![CI](https://img.shields.io/github/actions/workflow/status/hoobnn/livetranslate-bridge/ci.yml?branch=main&style=flat-square&label=CI)](https://github.com/hoobnn/livetranslate-bridge/actions/workflows/ci.yml)
[![macOS](https://img.shields.io/badge/macOS-27%2B-black?style=flat-square&logo=apple)](https://www.apple.com/macos/)
[![Apple Silicon](https://img.shields.io/badge/Apple%20Silicon-only-555?style=flat-square)](#快速开始)
[![Homebrew](https://img.shields.io/badge/brew-livetranslate--bridge-FBB040?style=flat-square&logo=homebrew&logoColor=white)](#快速开始)
[![License](https://img.shields.io/badge/license-MIT-green?style=flat-square)](LICENSE)

简体中文 · [English](README.md)

</div>

LiveTranslateBridge 是一款开源的 macOS 实时语音翻译 App。它采集任意应用的声音（接力通话、视频会议、浏览器、播放器等）和麦克风，调用阿里云百炼的 Qwen 实时翻译模型（qwen3.8 LiveTranslate）生成**双向字幕**与**译声**，并把原声、译声按各自的音量送到指定的输出设备——对方说外语时你看到、听到母语，你说母语时对方听到他的语言。

<picture>
  <source media="(prefers-color-scheme: dark)" srcset="docs/assets/product/app-subtitles-dark.jpg">
  <img src="docs/assets/product/app-subtitles-light.jpg" alt="LiveTranslateBridge macOS 实时翻译界面：中英文双向字幕左右分栏显示">
</picture>

<sub>截图为应用内置的示例字幕预览，跟随 GitHub 深浅色主题切换，不包含真实通话内容。</sub>

## 适用场景

- **iPhone 来电在 Mac 上接听**（接力通话）时，实时翻译对方的话，并把你的话译给对方。
- **跨语言视频会议**：采集会议应用的声音，生成双语字幕；配合回环声卡，还能把你的译声送进会议。
- **看外语直播、视频、网课**：只采集浏览器或播放器的声音，边看边出字幕。
- **转录与记录**：不翻译，只把双方原话按时间记下来，事后导出为 Markdown / Word。

## 主要功能

- **双向翻译**：对方的声音译成我的语言，我的声音译成对方的语言，字幕按时间顺序交错显示在左右两栏。
- **8 种常用语言**：中文、英语、日语、韩语、法语、德语、西班牙语、俄语，两侧各自选择。
- **转录模式**：只记录原话，不翻译也不播报，两侧可以选同一种语言。
- **任选声音来源**：按应用采集声音，多进程应用（如浏览器）一并采集；默认是接力通话进程 `avconferenced`（Mac 接听 iPhone 来电时由它播放通话音频）。
- **采集范围**：可选双向、只听对方（仅应用声音）或只听我（仅麦克风）。
- **音频路由**：「我听到」和「对方听到」分别指定输出设备，原声和译声音量各自可调，范围 0–200%，可开启“译声播放时自动降低原声音量”。
- **防回灌检查**：麦克风与输出构成回环时拒绝启动并给出提示。
- **音色复刻**：可选择用原说话人的音色播报译文。
- **聚合设备**：麦克风可以选聚合设备或多声道声卡，所有成员的声道都会被采集；聚合设备里含回环设备时，同样会触发防回灌检查。
- **术语表**：每行一条“原词 = 译词”，统一人名、产品名等专有名词的译法。
- **省用量**：对方一侧完全静音时暂停上传；麦克风一侧可选在长时间静音时暂停上传。某一侧译声音量为 0 时，只请求文字。
- **会话历史**：每次会话的字幕自动保存在本机（`~/Library/Application Support/com.ikuyu.livetranslate-bridge/Sessions`），可在「历史」页回看、搜索、删除；设置 › 通用里可以关闭。
- **导出为文档**：把当前字幕板或任一历史会话导出为 Markdown、纯文本或 Word（.docx），菜单「文件 › 导出为文档…」（⇧⌘E）。
- **诊断面板**：查看声音源进程状态和两侧电平，用样本离线回放测试翻译链路，清理异常退出后残留的聚合设备。
- **原生界面**：SwiftUI 编写，中英双语界面可即时切换，适配 Liquid Glass 与深浅色外观。

## 快速开始

**系统要求：** macOS 27 或更高版本，Apple Silicon 芯片。

通过 Homebrew 安装：

```bash
brew install --cask hoobnn/tap/livetranslate-bridge
```

也可以从 [GitHub Releases](https://github.com/hoobnn/livetranslate-bridge/releases/latest) 下载已签名并经过 Apple 公证的 DMG。

1. 在[阿里云百炼](https://bailian.console.aliyun.com/)（国内）或 [Alibaba Cloud Model Studio](https://modelstudio.console.alibabacloud.com/)（国际）获取 API Key 和业务空间 ID。
2. 打开设置（⌘,），填入以上两项，保存在登录钥匙串里；在「服务」中选择与账号对应的服务地域（华北2（北京）或新加坡）。
3. 在「音频路由」中选择声音来源、麦克风和两侧的输出设备。
4. 回到字幕页，选好两种语言，点「开始」。首次使用时 macOS 会请求系统音频录制和麦克风权限。

## 将实时译声送入会议或通话应用

需要一个回环声卡，例如 [BlackHole](https://existential.audio/blackhole/)：

1. 把「对方听到」的输出设为回环设备；
2. 在会议或通话应用里，把输入也设为同一个回环设备；
3. 本 App 的麦克风输入一定要选真实麦克风，否则会把自己的译声再采集回来。

## 常见问题

**能翻译 Zoom、腾讯会议、Teams 这类会议软件吗？**
可以。App 按应用采集声音，不绑定具体会议软件，在「声音源」里选中对应应用即可。iPhone 接力通话的声音由系统进程 `avconferenced` 播放，这也是默认声音源（实测见[接力通话音频实测](docs/findings.md)）。

**会录音吗？数据存在哪里？**
不录音。音频以流的形式发给你自己账号下的百炼服务做翻译，本机只保存字幕文字，可以随时关闭或一键删除。

**译声延迟多大？**
译声比原话晚 1–3 秒，积压时会自动加速播放。

**要付费吗？**
App 本身开源免费。翻译按百炼的模型计费标准扣你自己账号的用量；静音时暂停上传、只要文字时不请求译声，都能省用量。

**支持 Intel Mac 或更早的 macOS 吗？**
不支持。当前版本要求 macOS 27 或更高版本，且只提供 Apple Silicon 版本。

## 从源码构建

需要 Xcode 27。

```bash
open LiveTranslateBridge.xcodeproj    # 在 Xcode 里运行
./scripts/build-app.sh                # 或者用命令行构建出未签名的 dist/LiveTranslateBridge.app
```

调试时可以用环境变量 `DASHSCOPE_API_KEY` / `DASHSCOPE_WORKSPACE_ID` 覆盖钥匙串里的凭据。

## 发布

推送 main 和 PR 时 CI 只跑单元测试（`.github/workflows/ci.yml`）。推送 `v*` 标签后，`.github/workflows/release.yml` 会先跑同一套测试，再完成构建、Developer ID 签名、公证，然后发布 GitHub Release 并更新 Homebrew tap。标签版本必须与工程里的 `MARKETING_VERSION` 一致。

## 限制

- **没有沙盒**：进程 tap 和聚合设备在沙盒里会被拒绝，所以无法上架 Mac App Store。
- **不录音**：App 只保存字幕文字，不保存任何音频；通话录音一般需要各方同意。
- **没有回声消除**：用扬声器外放时，麦克风会采到对方的声音和译声；戴耳机或输出到回环设备就不会有这个问题。
- **译声延迟**：译声比原话晚 1–3 秒，积压时会自动加速播放。不希望二者重叠时，把对应一侧的原声音量调到 0。

## 文档

- [更新日志](CHANGELOG.md)
- [接力通话音频实测](docs/findings.md)
- [采集链路重构](docs/audio-capture-2026-09-23.md) · [音频优化](docs/audio-optimization-2026-09-22.md) · [网络与上行优化](docs/network-audio-optimization-2026-09-28.md)
- [qwen3.8 协议对接](docs/qwen38-protocol-validation-2026-09-22.md) · [服务端分段关联](docs/server-segmentation-2026-09-22.md)

## 许可证

[MIT](LICENSE)
