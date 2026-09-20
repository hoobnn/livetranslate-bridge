# LiveTranslateBridge

macOS app：捕获「接力通话」（Continuity / Phone Call Relay）的音频，接 Qwen 实时翻译，输出双语字幕。

前身是 `call-audio-bridge` 的命令行原型，本仓库把它迁成带界面的 App，CLI 的各项命令改为 App 内的诊断面板。

## 背景

Mac 接听 iPhone 来电走的是 Continuity 接力通话——iPhone 保持蜂窝语音链路，把音频通过 Wi-Fi 上的 Apple 私有协议转发给 Mac。Mac 只是远程的麦克风 + 扬声器端点。

实测确认（见 `docs/findings.md`）：

- 通话音频由 `/usr/libexec/avconferenced` 渲染，**不是** FaceTime.app，也不是 `callservicesd`
- 进程 tap 拿到的只有远端下行，不含本机麦克风，两路可独立处理
- 下行 48kHz 立体声，电平约 −18.7 dBFS，可直接降采样喂 ASR

## 要求

macOS 14.2+（Core Audio 进程 tap 的下限）。工程当前的 deployment target 是 27.0，在 macOS 27 上开发验证。

需要百炼（阿里云 Model Studio）的 API Key 与业务空间 ID：<https://bailian.console.aliyun.com/>

## 使用

用 Xcode 打开 `LiveTranslateBridge.xcodeproj` 运行。

首次运行先进「设置」（⌘,）填 API Key 与业务空间 ID，存入登录钥匙串。之后只剩一件事：在字幕页顶部选「我说」和「对方说」两种语言，点「开始」，接听 iPhone 来电。

顶部还有「采集」三选一，默认双向：

| 采集 | 开什么 | 要不要通话 |
|---|---|---|
| 双向 | 进程 tap + 麦克风 | 要 |
| 只听对方 | 仅进程 tap | 要 |
| 只听我 | 仅麦克风 | **不要** |

只听对方不会打开麦克风，也就不弹麦克风权限；只听我不开进程 tap，因此**不依赖通话**——点「开始」就直接采集，线下会议、口述笔记、当场口译都能用。单边时只建一条 WebSocket，另一条不开。

另外还有「翻译 / 转录」两种模式，默认翻译。转录只把两边说的话按原话记成文字，不译、也不播报，适合只想留个通话记录的场合——**这时两边可以选同一种语言**，同语种通话记录是转录的常见用法，翻译模式下则仍然禁止（把一种语言译成它自己没有意义）。两个语言选择器在转录模式下依然有用：它们把各自方向的 ASR 钉在已知语种上，识别比自动检测更准，切回翻译时也原样还在。

以下说的是翻译模式。

**双向翻译是默认行为，没有开关。** 两种语言一旦选定，两个方向就完全确定了：

- 对方（进程 tap）→ 译成我的语言，显示在字幕板左侧
- 我（麦克风）→ 译成对方的语言，显示在字幕板右侧

两条链路各有独立的 WebSocket 与断句状态，在同一条时间轴上按先后交错排列。

两个选择器中间的 ⇄ 按钮可以一键互换。把某一侧选成另一侧已有的语言时，两者自动交换而不是变成同一种语言——后者没有可翻译的内容。

调试时也可以用 scheme 的环境变量 `DASHSCOPE_API_KEY` / `DASHSCOPE_WORKSPACE_ID` 覆盖钥匙串里的值。

## 让对方听到译文

上面那套默认只出字幕。要让对方听到你的译文，去「设置 → 语音」选一个输出设备——**选设备本身就是开启播报，不另设开关**，选「不播报」就只有字幕。

**但播到普通扬声器只有你自己听得到。**

接力通话的上行是 `avconferenced` 从**系统默认输入设备**读的，App 无法直接写入。要让对方真的听到译文，需要一个回环设备中转：

1. 装一个回环声卡，例如 [BlackHole](https://existential.audio/blackhole/)（`brew install blackhole-2ch`）
2. 「系统设置 → 声音 → 输入」选中它——**输出仍保持你的耳机 / 扬声器，不要也选回环设备**，否则你自己什么都听不到
3. 回到本 App 的「设置 → 语音 → 播放到」，选同一个设备
4. 同一页的「从这里采集我的声音」，明确选中你的**真实麦克风**

第 4 步不能省。系统默认输入此时已经是回环设备，而采集若跟随默认输入，读到的就是 App 自己播出去的译文——译文被重新采集、再翻译一次，你的原声则始终没人听。选中真实麦克风后，回环设备留给通话，麦克风留给采集，两者互不干扰。漏掉这一步时设置页会直接给出橙色警告。

两个选择器各有标记：「播放到」里的「可回灌通话」是推荐项，「从这里采集」里的「回环设备，会采到译文」则是**要避开**的项。该页还会显示当前的系统默认输入，用来确认第 2 步是否生效。

同一页还有「用我自己的声音播报」：通话开始时克隆一次你的音色并沿用，关闭则用默认音色。

代价是上行从此只有译文：合成语音比说话本身晚 1–3 秒，对方听到的是延迟版本而不是你的原声。

App 不会也无法替你修改系统默认输入设备，更不会安装回环驱动——HAL 插件装在 `/Library/Audio/Plug-Ins/HAL`，需要管理员权限和独立签名。

## 结构

```
LiveTranslateBridge/
  LiveTranslateBridgeApp   程序入口，持有全局 SubtitleModel
  ContentView              字幕 / 诊断两个标签页
  CallAudioKit/            采集层，与 UI 无关
    AudioObjectProperty    AudioObject 属性读取的类型化封装
    CallMonitor            监听 avconferenced 的 IO 状态，判定通话起止
    DownlinkTap            进程 tap + 聚合设备，采集远端；含残留清理
    UplinkCapture          AVAudioEngine 采集本机麦克风
    CallAudioSession       把监听与两路采集串起来；两路各可单独关闭，只留麦克风时不等通话
    Resampler              48k 立体声 → 16k 单声道 Int16
    AudioOutputDevice      枚举输出设备，识别可回灌通话的回环设备
    TranslationPlayer      把服务端合成的 24k 语音播到指定输出设备
  Translation/             与翻译服务对接
    TranslationClient      qwen3.8-livetranslate-flash-realtime 的 WebSocket 客户端
    CredentialStore        凭据读写（钥匙串，环境变量优先）
  Models/                  可观察状态，供视图绑定
    SubtitleModel          两向各一条链路，把采集与翻译的回调汇成字幕条目；持有采集范围与翻译 / 转录模式
    DiagnosticsModel       进程检查、电平表、离线文件翻译
  Views/                   纯视图
    SubtitleView           字幕板
    SettingsView           凭据、服务区域与语音输出
    DiagnosticsView        诊断面板（原 CLI 的 status / levels / clean / translate-file）
```

采集层全部标了 `nonisolated`：它们跑在 Core Audio 的实时线程上，而工程默认 `SWIFT_DEFAULT_ACTOR_ISOLATION = MainActor`，不脱离隔离就会被编译器拦下。音频线程通过 `SubtitleModel.AudioPath`（带锁，每个方向一个）交给对应的翻译客户端，只有事件回调才跳主线程。

## 诊断面板

对应原 CLI 的四个命令，用来在不真打电话的前提下检查链路：

| 面板 | 原命令 | 作用 |
|---|---|---|
| 通话进程 | `status` | 当前是否有通话、在哪个进程上 |
| 电平表 | `levels` | 双向电平，会请求麦克风权限 |
| 离线翻译 | `translate-file` | 用 `samples/*.wav` 回归翻译链路 |
| 维护 | `clean` | 清理异常退出遗留的聚合设备 |

## 关于沙盒

工程已关闭 App Sandbox。`AudioHardwareCreateProcessTap` 与聚合设备在沙盒下会被拒绝，这是采集链路的硬前提。代价是不能上架 Mac App Store。

系统音频与麦克风用途说明分别写在 build settings 的 `INFOPLIST_KEY_NSAudioCaptureUsageDescription`、`INFOPLIST_KEY_NSMicrophoneUsageDescription`，Hardened Runtime 所需的 `com.apple.security.device.audio-input` 写在 App entitlement 中。字幕首次创建 process tap 时，macOS 会请求系统音频录制权限；只有诊断面板的电平表会打开麦克风。

## 关于录音

App 刻意不提供录制到磁盘的功能。通话内容属于双方，多数司法辖区要求全员同意才能录音；中国《个人信息保护法》将声纹列为敏感个人信息，需单独同意。

需要录制请直接用 `CallAudioKit`，并自行确保已获得对方同意。

## 已知问题

**声学回授**：扬声器外放时麦克风会收到远端声音，实测包络相关 r≈0.19–0.27。做纯字幕不受影响。在「设置 → 语音」把译文播到扬声器时，译文会被麦克风重新采集、再送去翻译一次；播到回环设备则不经过声学路径，没有这个问题。

**时钟漂移**：两路时钟独立，实测 12 秒偏差约 0.25%。短句 ASR 无影响，长通话需补偿。

**译文回灌依赖外部回环设备**：App 只能把合成语音播到某个输出设备，无法直接写入接力通话的上行——那一路由 `avconferenced` 从系统默认输入读取。因此要让对方听到译文，必须由用户自行安装回环声卡并设为默认输入（见「让对方听到译文」一节）。自带回灌需要一个 HAL 插件，属于独立的驱动工程。

**译文延迟**：合成语音比说话本身晚 1–3 秒。上行被译文占用时，对方听到的是延迟版本而非原声，两者无法并存。
