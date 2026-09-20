# 接力通话音频链路实测

2026-09-20，macOS 27.0（Build 26A428），Apple Silicon。
测试对象：与运营商 IVR 机器人的真实通话，无第三方自然人。

## 一、通话音频来自哪个进程

枚举 Core Audio 进程对象，读 `kAudioProcessPropertyIsRunningInput` /
`IsRunningOutput`，观察通话期间的状态变化。

| 进程 | PID | 通话中状态 | 结论 |
|---|---|---|---|
| `/usr/libexec/avconferenced` | 853 | 全程 `in+out` | **音频渲染进程** |
| `callservicesd` | 757 | 无音频 | 仅呼叫控制信令 |
| `systemsoundserverd` | 914 | 仅 1 秒级脉冲 | UI 提示音 |
| FaceTime.app | — | 未参与 | 不涉及 |

最初推测的 `callservicesd` 与 FaceTime.app 均被证伪。

`avconferenced` 的 PID 会随 launchd 重启变化，必须按 bundle ID
`com.apple.avconferenced` 动态解析。

## 二、能否捕获

`AudioHardwareCreateProcessTap` + 聚合设备，成功。

| 项 | 实测值 |
|---|---|
| 格式 | 48000 Hz / 2 ch / Float32 |
| 采集速率 | 48128 fr/s，无丢帧 |
| 非静音占比 | 84.8% |
| 峰值 / RMS | 0.7109 / −18.7 dBFS |
| 包络动态比 | 732176:1 |

包络呈明确的话音段与停顿交替，确认是语音而非稳态噪声。

**未触发任何 TCC 权限弹窗**（终端环境下）。tap 创建与 `AudioDeviceStart`
均直接通过。打包为独立 app 后麦克风权限会弹窗。

## 三、两路是否可分离

关键问题：tap 拿到的是仅远端，还是远端与本地的混合。

同时采集 tap 与麦克风 12 秒，做 50ms 分桶包络相关：

```
downlink (IVR 机器人)：
  #####+#########...############.....###########+###########+.++###...
  #############+####+...........................................  ← 7.0s 后数字静音
uplink (麦克风)：
  ........++.###++.............#++....+.++.......+.........+......
  ....+..+.+....+.++...+.......+..........................++++++..  ← 全程有活动
```

- 包络相关 r = 0.1761；±1 秒时移搜索最佳 r = 0.2688（滞后 0.05s）
- **7.0 秒后 downlink 降至 −72.2 dBFS（数字静音），而 uplink 仍有信号**

若 tap 含本地音频，downlink 不可能在用户说话时归零。**两路独立，可分离。**
第二次 10 秒复测结论一致（r = 0.1944，3.5–6.0s 段 downlink 静音而 uplink
有 −24.7dB 峰值），并经人耳确认 downlink 中听不到本机说话声。

残余相关来自扬声器→麦克风的声学耦合，非信号混合。

## 四、双向采集参数

| | downlink（远端） | uplink（麦克风） |
|---|---|---|
| 来源 | 进程 tap | `AVAudioEngine` 默认输入 |
| 格式 | 48000 Hz / 2 ch | 48000 Hz / 1 ch |
| 峰值 | 0.7109 | 0.4390 |
| RMS | −18.7 dBFS | −40.8 dBFS |
| 12 秒采集帧数 | 582144 | 580800 |

两路时钟偏差 0.25%（12.13s vs 12.10s）。短句 ASR 可忽略，长通话需漂移补偿。

uplink 电平偏低是内置麦克风加距离所致，产品中需 AGC。

## 五、对上层方案的结论

双向字幕方案成立，链路为：

- **下行**：tap `avconferenced` → 48k 降 16k → 流式 ASR → 翻译 → 字幕
- **上行**：`AVAudioEngine` → 同链路
- 两路独立显示，无需时间对齐

未解决：若要加 TTS 播报翻译，声学回授会被 ASR 误判为用户说话形成自激，
需强制耳机或引入 AEC（`AVAudioEngine` 的 voice processing 模式会改变音频
通路，需另行验证）。

## 六、工程注意

- tap 与聚合设备是 Core Audio 服务端的全局对象，进程崩溃后会残留，
  在「音频 MIDI 设置」中可见。必须在 `deinit`、显式 `stop()` 与下次
  `start()` 时三重清理。
- `AVAudioFile` 若声明为 `let` 且不释放，WAV header 的 size 字段不会回填，
  播放器会认为文件时长为 0（数据本身完整）。需在结束时置 nil 触发释放。
- Float32 WAV 兼容性差，输出建议用 Int16。

## 七、Qwen 实时翻译接入实测

2026-09-20，华北2（北京）。输入 `samples/downlink.wav`（中文 IVR），
目标语种英文。先在 `qwen3.5-livetranslate-flash-realtime` 上跑通，
后迁移至 `qwen3.8-livetranslate-flash-realtime`（见 §八）。

```
原文  办理流量包，重置宽带密码。
译文  Apply for a data plan, reset the broadband password.
原文  你好，请讲。你可以这样告诉我，啥话。
译文  Hello, please go ahead. You can tell me like this. What's up?
```

### 文档未写的字段语义（q3.5）

`response.text.text` 与 `conversation.item.input_audio_transcription.text`
各带两个文本字段，且都是**累积全量快照，不是增量**：

| 字段 | 含义 |
|---|---|
| `text` | 已确认的稳定文本 |
| `stash` | 未确认的尾部，会被后续事件重写 |

实际显示取 `text + stash`，每次**替换**而非追加。按增量拼接会得到重复串。
识别事件另带 `language` 与 `emotion` 字段。

> 官方文档后来已补上 `stash` 的说明，与此处实测一致。

### 踩到的两个坑

**同步 main 里 `Task {}` 永不执行**：CLI 是同步顶层代码，Swift 并发的协作
线程池不会启动，`Task` 只排队不运行，表现为主线程卡在信号量上、音频一个
分片都发不出去。栈采样可见 `semaphore_wait_trap`。已改为回调式 API
（`whenReady` / `finish(_:)`），`async` 版本保留给有并发环境的调用方。

**`AVAudioFile.read` 到文件末尾抛 `eofErr`**，不是返回 0 帧。读循环要按
`framePosition < length` 驱动。

### 已排除：`turn_detection` 缺失（q3.5）

一度怀疑 `session.update` 是整体替换语义，漏发 `turn_detection` 会关掉 VAD。
**已证伪**：补发该字段后行为完全不变，且 `session.created` 显示服务端默认
本就带 `server_vad`（threshold 0.2 / silence_duration_ms 1000）。

## 八、迁移到 qwen3.8-livetranslate-flash-realtime

2026-09-20。迁移动机：q3.8 是官方当前推荐版，且 **ASR 始终开启、识别结果
免费**——双语字幕在 q3.5 上要为 `input_audio_transcription` 多付一份识别费。

### 协议差异（与 q3.5 相比）

| 项 | q3.5 | q3.8 |
|---|---|---|
| 输出模态字段 | `modalities` | `output_modalities` |
| 译文事件 | `response.text.text`（快照） | `response.text.delta`（**真增量**） |
| 原文事件 | `…transcription.text`（快照） | `…transcription.delta`（**真增量**） |
| ASR 开关 | `input_audio_transcription.model` | 始终开启，不可关闭，免费 |
| 断句 | `turn_detection` = `server_vad`，可调 | `speaker_detection`，无客户端参数 |
| 音频格式字段 | `input/output_audio_format`、`sample_rate` | 不适用，固定 16k 进 / 24k 出 |
| `same_language_skip_options` | 支持 | **不支持** |

URL、Bearer 鉴权、`input_audio_buffer.append`、`session.finish` →
`session.finished` 收尾流程、`translation.corpus.phrases` 热词均不变。

因 q3.8 的两路文本都是真增量，`TranslationClient.Event` 增加
`transcriptDelta`；原有的 `transcript` / `translation` 快照分支保留，
未被 q3.8 触发。**两路都靠 `translationComplete` 封口**，漏封口会把下一句
话接到上一句尾部——已由 `transcriptDeltasDoNotBleedAcrossUtterances` 覆盖。

### 实测结果

`samples/downlink.wav` → 英文，端到端跑通，事件计数
`transcriptDelta=7, translationDelta=18`：

```
[transcript/delta] 办理流量 / 包
[translation/delta] Apply / for a / data package / .
[transcript/DONE]  办理流量包 重置宽带密码
[translation/DONE] Apply for a data package. Reset the broadband password.
```

### §七遗留问题的现状

q3.5 时期「服务端收音频但不回任何事件」的症状，在 q3.8 上**未复现**：
同一条 `downlink.wav`、同一套凭据与端点，事件正常返回。该问题未经单独
定位即随迁移消失，若日后回到 q3.5 需重新排查。

### 已澄清：`samples/uplink.wav` 无响应属样本问题

该样本送入 q3.8 同样不返回任何事件，但**不是协议问题**：
peak −9.7 dBFS / RMS −38.2 dBFS，250ms 分桶显示只有零散孤立的脉冲
（键盘与手持噪声），没有连续语音段——与 §三记录的「uplink 全程稀疏活动」
一致。加 +16 dB 增益后仍无响应，排除电平因素。该文件本就不含成句人声，
不适合用作链路验证素材。

## 九、通话中途停顿后不再有译文

2026-09-20。症状：通话进行中，一段时间无人说话，之后再开口就不再出现新译文。
界面状态仍显示「运行中」，日志里采集与重采样也一直正常。

### 定位

链路各段的实际状态：

| 环节 | 停顿后状态 |
|---|---|
| 进程 tap / 麦克风采集 | 正常，buffer 持续到达 |
| 重采样 | 正常，持续产出 16k PCM |
| `sendAudio` | 正常接收，**但全部丢弃** |
| WebSocket | **已断开** |
| UI 状态 | 仍为 `.running` |

根因在 `TranslationClient`：服务端会主动关闭长时间空闲的会话，而原实现里
socket 一旦断开只是把 `isDead` 置位，没有任何重连。此后 `sendAudio` 每个
分片都被静默丢弃，字幕永久停止，但采集侧一切正常，所以界面无从察觉。

断开有两种表现，都要覆盖：

1. `receive` / `send` 回调报错——可直接捕获；
2. 服务端下发 `session.finished`，或干脆不再应答而 socket 名义上仍开着——
   parked 的 `receive` 会一直等下去，**不报错**。

### 处理

- **自动重连**：非主动 `close()` 的断开一律重开 socket，退避
  0.25s 起指数增长、上限 8s；`session.updated` 到达即清零重试计数，
  因此「每小时断一次」的长通话不会爬上退避阶梯。
- **空闲探测**：以「最近一次收到任何入站帧」为活性判据，超过 20s 无帧即
  重连。入站帧而非「有没有人说话」才是可靠信号——服务端在整个会话期间
  都会发帧。
- **跨断点音频缓冲**：断开期间的音频保留最近 1 秒（32000 B @ 16k/mono/Int16），
  新会话 `session.updated` 后按序重放，接在握手队列之前。超出预算时丢最旧的，
  保证「断开瞬间正在说的那句」不丢。
- **不再误报失败**：可恢复的断开不再抛 `.failed`，否则用户会看到一次自己
  根本无感的红色报错。`.failed` 留给重连修不好的错误（凭据错误、会话被拒），
  这些由服务端的 `error` 帧送达。
- **世代号（generation）**：取消旧 socket 会让它 parked 的 `receive` 报错，
  而这个错误在新 socket 装好**之后**才到达。回调按世代号校验，否则旧连接的
  临终回调会被当成新连接失败并立刻拆掉它——形成无限重连。

`ReconnectBufferTests` 覆盖跨断点缓冲的保留、按序重放、预算上限、丢弃顺序，
以及 `close()` 之后不再持有音频。重连本身需要真实服务端，未做单测。

## 十、运行期性能

同一轮里处理的几处热点，均在 Core Audio IO 线程或每帧重绘路径上：

| 位置 | 问题 | 处理 |
|---|---|---|
| `AudioPath.report(sent:)` | 每个 buffer 全量 `reduce` 求峰值 | 改为步长 16 抽样；峰值只用于日志区分「有声 / 数字静音」，16k 下仍有约 1000 点/秒 |
| 同上 | 每 buffer 取 `Date()` 做限流 | 改 `ContinuousClock`，避免墙钟读取与系统改时引起的停发或刷屏 |
| `Resampler.convert` | 每次调用新分配输出 buffer | 复用；采集帧数恒定，首帧之后不再分配 |
| `Resampler.convert(tapBuffer:)` | 每个 tap 回调新建 `AVAudioFormat` + staging buffer | 复用并按格式校验；锁覆盖「拷入 + 转换」全程，避免并发回调覆写 |
| `SubtitleView` 列表 | `Array(entries.enumerated())` 每次重绘枚举全表 | 分组标志（`continuesRun` / `startsNewSpeaker`）改为随条目存储，只在增删时写入 |
| 同上 | 每个文本 delta 触发 `scrollTo`，每次强制全列表布局 | 合并为每轮 run loop 一次的 `scrollTick` |
| `TranslationClient.sendAudio` | 队列满时每 buffer 打一条日志 | 降为每秒一条 |

`RunGroupingTests` 覆盖分组标志：包括空 utterance 被丢弃后，其下方卡片的
标志需要按新的相邻关系修复——这是存储化之后唯一会算错的情形。
