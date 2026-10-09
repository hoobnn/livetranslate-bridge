<div align="center">

<img src="LiveTranslateBridge/Assets.xcassets/AppIcon.appiconset/AppIcon-256.png" width="112" alt="LiveTranslateBridge 应用图标">

# LiveTranslateBridge

macOS 实时语音翻译与双语字幕工具，适用于通话、会议和任意 App 的音频。

[![Release](https://img.shields.io/github/v/release/hoobnn/livetranslate-bridge?style=flat-square)](https://github.com/hoobnn/livetranslate-bridge/releases/latest)
[![CI](https://img.shields.io/github/actions/workflow/status/hoobnn/livetranslate-bridge/ci.yml?branch=main&style=flat-square&label=CI)](https://github.com/hoobnn/livetranslate-bridge/actions/workflows/ci.yml)
[![macOS](https://img.shields.io/badge/macOS-27%2B-black?style=flat-square&logo=apple)](https://www.apple.com/macos/)
[![License](https://img.shields.io/badge/license-MIT-green?style=flat-square)](LICENSE)

**简体中文** · [English](README.en.md)

</div>

LiveTranslateBridge 是一款开源的 macOS App。它同时采集指定应用的声音（在 Mac 上接听的 iPhone 来电、视频会议、浏览器、播放器）和麦克风，通过阿里云百炼的 Qwen 实时翻译模型（qwen3.8 LiveTranslate）生成双向字幕，并可将译文语音播报。原声和译声分别输出到指定设备，音量独立调节。

典型场景：对方说英语，你看到中文字幕、听到中文译声；你说中文，对方听到英语译声。

<picture>
  <source media="(prefers-color-scheme: dark)" srcset="docs/assets/product/app-subtitles-dark.jpg">
  <img src="docs/assets/product/app-subtitles-light.jpg" alt="LiveTranslateBridge macOS 实时翻译界面：中英文双向字幕左右分栏显示">
</picture>

<sub>截图为 App 内置的示例字幕，并非真实通话，会随 GitHub 的深浅色主题切换。</sub>

## 使用场景

- 在 Mac 上接听 iPhone 来电（接力通话），双向实时翻译。
- 跨语言视频会议：采集会议软件的声音生成双语字幕；配合回环声卡，还可以将你的译声送入会议。
- 观看外语直播、视频和网课：仅采集浏览器或播放器，实时显示字幕。
- 纯转录：不翻译，按时间记录双方原话，可导出为 Markdown 或 Word。

## 功能

- 双向翻译：对方的话译成你的语言，你的话译成对方的语言，字幕按时间顺序交错显示在左右两栏。
- 支持 8 种语言：中文、英语、日语、韩语、法语、德语、西班牙语、俄语，两侧可分别选择。
- 转录模式：只记录原话，不翻译也不播报，两侧可选择同一种语言。
- 声音来源可选任意应用，浏览器等多进程应用会整体采集。默认来源为 `avconferenced`，即 Mac 接听 iPhone 来电时播放通话声音的系统进程。
- 采集范围可选：双向、仅对方（只采集应用声音）、仅自己（只采集麦克风）。
- 音频路由：「我听到」和「对方听到」分别指定输出设备，原声与译声音量均可在 0–200% 之间调节，并可开启「译声播放时自动压低原声」。
- 防回灌：麦克风与输出设备构成回环时禁止启动，并提示原因。
- 音色复刻：可使用说话人自己的音色播报译文。
- 聚合设备：麦克风可选择聚合设备或多声道声卡，所有声道都会被采集；聚合设备中包含回环设备时，同样会触发防回灌检查。
- 术语表：每行一条「原词 = 译词」，确保人名、产品名等专有名词译法一致。
- 节省用量：对方静音时暂停上传，麦克风长时间静音时也可选择暂停；某一侧译声音量设为 0 时，只请求文字结果。
- 会话历史：每次会话的字幕保存在本机（`~/Library/Application Support/com.ikuyu.livetranslate-bridge/Sessions`），可在「历史」页回看、搜索和删除，也可在「设置 › 通用」中关闭。
- 会话录音：在「设置 › 通用」中开启「同时保存录音」后，两侧的原声和播放的译声各保存为一个 `.m4a` 文件（原声 16 kHz、译声 24 kHz，单声道 AAC）。四个文件共用同一条时间轴，可叠加回放；在「历史」页点击波形按钮即可在访达中定位。该功能默认关闭，删除会话时录音一并删除。
- 导出：当前字幕或任意历史会话均可通过「文件 › 导出为文档…」（⇧⌘E）导出为 Markdown、纯文本或 Word（.docx）。
- 诊断面板：查看声音源进程状态和两侧电平，用样本离线回放测试翻译链路，清理异常退出后残留的聚合设备。
- 基于 SwiftUI 构建，中英文界面可随时切换，支持 Liquid Glass 和深浅色外观。

## 安装

需要 macOS 27 或更新版本，仅支持 Apple Silicon。

用 Homebrew 安装：

```bash
brew install --cask hoobnn/tap/livetranslate-bridge
```

也可以从 [GitHub Releases](https://github.com/hoobnn/livetranslate-bridge/releases/latest) 下载 DMG，安装包已签名并通过 Apple 公证。

### 更新

App 通过 [Sparkle](https://sparkle-project.org/) 自动检查新版本，发现后提示安装；也可以在应用菜单中选「检查更新…」手动检查，或在「设置 › 通用 › 更新」关闭自动检查。更新包经 EdDSA 签名校验后才会安装。1.0.0 还没有这项功能，需要手动更新一次（`brew upgrade --cask livetranslate-bridge` 或重新下载 DMG）。

## 首次使用

1. 在[阿里云百炼](https://bailian.console.aliyun.com/)（国内）或 [Alibaba Cloud Model Studio](https://modelstudio.console.alibabacloud.com/)（国际）获取 API Key 和业务空间 ID。
2. 打开设置（⌘,）填写这两项，凭据会保存在登录钥匙串中。在「服务」中选择账号所属地域：华北2（北京）或新加坡。
3. 在「音频路由」中选择声音来源、麦克风和两侧的输出设备。
4. 回到字幕页，选择两种语言后点击「开始」。首次使用时，macOS 会请求系统音频录制和麦克风权限。

## 将译声送入会议或通话

需要一个回环声卡，比如 [BlackHole](https://existential.audio/blackhole/)：

1. 将「对方听到」的输出设为回环设备；
2. 在会议或通话软件中，将输入也设为该回环设备；
3. 本 App 的麦克风必须选择真实麦克风，否则会重新采集到自己的译声。

## 常见问题

**Zoom、腾讯会议、Teams 能用吗？**
可以。App 按应用采集声音，不依赖特定会议软件，在「声音源」中选择对应应用即可。iPhone 接力通话的声音由系统进程 `avconferenced` 播放，这也是默认声音源（实测记录见[接力通话音频实测](docs/findings.md)）。

**会录音吗？数据存在哪里？**
默认不录音。音频以流式方式发送到你自己账号下的百炼服务进行翻译，本机默认只保存字幕文字，可随时关闭或删除；只有手动开启「同时保存录音」后，才会在本机保存音频。

**译声延迟多少？**
比原话晚 1–3 秒，出现积压时会自动加速播放。

**收费吗？**
App 免费开源。翻译费用由你自己的百炼账号按模型标准价格结算。静音时暂停上传、只请求文字结果，都可以节省用量。

**支持 Intel Mac 或旧版 macOS 吗？**
不支持。目前仅支持 macOS 27 及以上的 Apple Silicon Mac。

## 已知限制

- 未启用沙盒：系统会在沙盒中拒绝进程 tap 和聚合设备，因此无法上架 Mac App Store。
- 默认不保存音频：录音需在设置中手动开启。录制通话通常需要征得各方同意。
- 无回声消除：使用扬声器外放时，麦克风会同时采集到对方的声音和译声。佩戴耳机或输出到回环设备可避免此问题。
- 译声比原话晚 1–3 秒，积压时会加速。如不希望两者重叠，可将该侧原声音量调为 0。

## 从源码构建

需要 Xcode 27。

```bash
open LiveTranslateBridge.xcodeproj    # 在 Xcode 里运行
./scripts/build-app.sh                # 或在命令行构建未签名的 dist/LiveTranslateBridge.app
```

调试时可以用环境变量 `DASHSCOPE_API_KEY` / `DASHSCOPE_WORKSPACE_ID` 覆盖钥匙串里的凭据。

## 发布流程

推送到 main 或提交 PR 时，CI 只运行单元测试（`.github/workflows/ci.yml`）。推送 `v*` 标签会触发 `.github/workflows/release.yml`：先运行同一套测试，再构建、使用 Developer ID 签名并公证，最后发布 GitHub Release 并更新 Homebrew tap。标签中的版本号必须与工程中的 `MARKETING_VERSION` 一致。

应用内更新的 appcast 不进版本库：发布时 CI 用仓库 secret `SPARKLE_ED_PRIVATE_KEY` 给 zip 签名，随 Release 附上 `.zip.sparkle.json`；随后重新部署 GitHub Pages（`.github/workflows/pages.yml`），从全部 Release 生成 `https://hoobnn.github.io/livetranslate-bridge/appcast.xml`。删除某个 Release，它对应的更新条目也随之消失。

## 文档

- [更新日志](CHANGELOG.md)
- [接力通话音频实测](docs/findings.md)
- [采集链路重构](docs/audio-capture-2026-09-23.md) · [音频优化](docs/audio-optimization-2026-09-22.md) · [网络与上行优化](docs/network-audio-optimization-2026-09-28.md)
- [qwen3.8 协议对接](docs/qwen38-protocol-validation-2026-09-22.md) · [服务端分段关联](docs/server-segmentation-2026-09-22.md)

## 许可证

[MIT](LICENSE)
