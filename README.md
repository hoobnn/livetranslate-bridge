<div align="center">

<img src="LiveTranslateBridge/Assets.xcassets/AppIcon.appiconset/AppIcon-256.png" width="112" alt="LiveTranslateBridge 应用图标">

# LiveTranslateBridge

macOS 上的实时语音翻译和双语字幕工具。通话、会议、浏览器里的声音，边听边译。

[![Release](https://img.shields.io/github/v/release/hoobnn/livetranslate-bridge?style=flat-square)](https://github.com/hoobnn/livetranslate-bridge/releases/latest)
[![CI](https://img.shields.io/github/actions/workflow/status/hoobnn/livetranslate-bridge/ci.yml?branch=main&style=flat-square&label=CI)](https://github.com/hoobnn/livetranslate-bridge/actions/workflows/ci.yml)
[![macOS](https://img.shields.io/badge/macOS-27%2B-black?style=flat-square&logo=apple)](https://www.apple.com/macos/)
[![License](https://img.shields.io/badge/license-MIT-green?style=flat-square)](LICENSE)

**简体中文** · [English](README.en.md)

</div>

LiveTranslateBridge 是一个开源的 macOS App。它同时采集某个应用的声音（Mac 上接的 iPhone 电话、视频会议、浏览器、播放器）和你的麦克风，交给阿里云百炼的 Qwen 实时翻译模型（qwen3.8 LiveTranslate），出双向字幕，也可以把译文念出来。原声和译声分别送到你指定的输出设备，音量各调各的。

用起来大概是这样：对方说英语，你看到中文字幕、听到中文；你说中文，对方听到的是英语。

<picture>
  <source media="(prefers-color-scheme: dark)" srcset="docs/assets/product/app-subtitles-dark.jpg">
  <img src="docs/assets/product/app-subtitles-light.jpg" alt="LiveTranslateBridge macOS 实时翻译界面：中英文双向字幕左右分栏显示">
</picture>

<sub>截图是 App 自带的示例字幕，不是真实通话，会跟着 GitHub 的深浅色主题切换。</sub>

## 能用在哪

- 在 Mac 上接 iPhone 来电（接力通话），实时翻译对方的话，也把你的话译给对方。
- 跨语言的视频会议：采集会议软件的声音出双语字幕。配一个回环声卡，还能把你的译声送进会议。
- 看外语直播、视频、网课：只采集浏览器或播放器，边看边出字幕。
- 只做记录：不翻译，把双方原话按时间记下来，之后导出成 Markdown 或 Word。

## 功能

- 双向翻译。对方的话译成你的语言，你的话译成对方的语言，字幕按时间交错排在左右两栏。
- 支持 8 种语言：中文、英语、日语、韩语、法语、德语、西班牙语、俄语，两边分开选。
- 转录模式：只记原话，不翻译也不播报，两边可以选同一种语言。
- 声音来源可以选任意应用，浏览器这种多进程应用会一起采。默认来源是 `avconferenced`，Mac 接 iPhone 电话时就是它在放通话声音。
- 采集范围可选：双向、只听对方（只采应用声音）、只听我（只采麦克风）。
- 音频路由：「我听到」和「对方听到」各选一个输出设备，原声、译声音量都能在 0–200% 之间调；可以开「译声播放时自动压低原声」。
- 防回灌：麦克风和输出设备连成回环时不让启动，并告诉你原因。
- 音色复刻：可以用说话人自己的音色念译文。
- 聚合设备：麦克风可以选聚合设备或多声道声卡，所有声道都会采到；聚合设备里带回环设备的，同样会触发防回灌检查。
- 术语表：一行一条「原词 = 译词」，人名、产品名这类专有名词就不会每次译得不一样。
- 省用量：对方完全没声音时暂停上传；麦克风长时间静音时也可以暂停。某一侧译声音量设成 0，就只请求文字。
- 会话历史：每次的字幕存在本机（`~/Library/Application Support/com.ikuyu.livetranslate-bridge/Sessions`），在「历史」页可以回看、搜索、删除；不想存可以在「设置 › 通用」里关掉。
- 导出：当前字幕或任意一次历史会话，可以导出为 Markdown、纯文本或 Word（.docx），菜单「文件 › 导出为文档…」（⇧⌘E）。
- 诊断面板：看声音源进程的状态和两侧电平，用样本离线回放测试翻译链路，清理异常退出后留下的聚合设备。
- 界面用 SwiftUI 写，中英文界面随时切换，支持 Liquid Glass 和深浅色。

## 安装

需要 macOS 27 或更新版本，Apple Silicon 芯片。

用 Homebrew 安装：

```bash
brew install --cask hoobnn/tap/livetranslate-bridge
```

或者到 [GitHub Releases](https://github.com/hoobnn/livetranslate-bridge/releases/latest) 下载 DMG，已经签名并通过 Apple 公证。

## 第一次使用

1. 在[阿里云百炼](https://bailian.console.aliyun.com/)（国内）或 [Alibaba Cloud Model Studio](https://modelstudio.console.alibabacloud.com/)（国际）拿到 API Key 和业务空间 ID。
2. 打开设置（⌘,），填这两项，它们会存进登录钥匙串。在「服务」里选和账号对应的地域：华北2（北京）或新加坡。
3. 在「音频路由」里选好声音来源、麦克风和两侧的输出设备。
4. 回到字幕页，选两种语言，点「开始」。第一次用时 macOS 会要系统音频录制和麦克风权限。

## 把译声送进会议或通话

需要一个回环声卡，比如 [BlackHole](https://existential.audio/blackhole/)：

1. 把「对方听到」的输出设成回环设备；
2. 会议或通话软件里，输入也选这个回环设备；
3. 本 App 的麦克风一定要选真实的麦克风，不然会把自己的译声又采回来。

## 常见问题

**Zoom、腾讯会议、Teams 能用吗？**
能。App 是按应用采集声音的，不跟哪个会议软件绑定，在「声音源」里选对应的应用就行。iPhone 接力通话的声音由系统进程 `avconferenced` 播放，这也是默认的声音源（实测记录见[接力通话音频实测](docs/findings.md)）。

**会录音吗？数据存在哪？**
不录音。音频以流的方式发到你自己账号下的百炼服务做翻译，本机只存字幕文字，随时可以关掉或删除。

**译声有多少延迟？**
比原话晚 1–3 秒，积压时会自动加快播放。

**收费吗？**
App 免费开源。翻译用的是你自己的百炼账号，按模型的标准价格计费。静音时暂停上传、只要文字不要译声，都能省一些用量。

**Intel Mac 或旧版 macOS 能用吗？**
不能。目前只支持 macOS 27 及以上，只有 Apple Silicon 版本。

## 已知限制

- 没有沙盒：进程 tap 和聚合设备在沙盒里会被系统拒绝，所以上不了 Mac App Store。
- 不录音：只存字幕文字，不存任何音频。录通话一般要经过各方同意。
- 没有回声消除：用扬声器外放时，麦克风会把对方的声音和译声一起采进来。戴耳机或者输出到回环设备就没这个问题。
- 译声比原话晚 1–3 秒，积压时会加速。不想两者叠在一起，就把那一侧的原声音量调到 0。

## 从源码构建

需要 Xcode 27。

```bash
open LiveTranslateBridge.xcodeproj    # 在 Xcode 里运行
./scripts/build-app.sh                # 或者命令行构建未签名的 dist/LiveTranslateBridge.app
```

调试时可以用环境变量 `DASHSCOPE_API_KEY` / `DASHSCOPE_WORKSPACE_ID` 覆盖钥匙串里的凭据。

## 发布流程

推 main 或提 PR 时，CI 只跑单元测试（`.github/workflows/ci.yml`）。推 `v*` 标签会触发 `.github/workflows/release.yml`：先跑同一套测试，再构建、用 Developer ID 签名、公证，最后发 GitHub Release 并更新 Homebrew tap。标签里的版本号必须和工程里的 `MARKETING_VERSION` 一致。

## 文档

- [更新日志](CHANGELOG.md)
- [接力通话音频实测](docs/findings.md)
- [采集链路重构](docs/audio-capture-2026-09-23.md) · [音频优化](docs/audio-optimization-2026-09-22.md) · [网络与上行优化](docs/network-audio-optimization-2026-09-28.md)
- [qwen3.8 协议对接](docs/qwen38-protocol-validation-2026-09-22.md) · [服务端分段关联](docs/server-segmentation-2026-09-22.md)

## 许可证

[MIT](LICENSE)
