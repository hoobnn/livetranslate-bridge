# qwen3.8 对接审计与本地听力回放

> 后续更新：qwen3.8 已通过音色复刻真实调用，所有音色模式现统一使用 qwen3.8。下面前半部分记录此前普通音色审计；其中“音色复刻选择 qwen3.5”的实现已被文末的新实测替代。

2026-09-22。结论：旧实现混用了 qwen3.5 的会话字段。已拆分两套配置，并通过用户提供的完整 MP3 验证 qwen3.8 文本、音频两条真实服务路径。仅增加 VAD 停顿窗口不足以解决协议及识别/翻译问题。

## 协议边界

| 项目 | qwen3.8 普通音色 / 纯文本 | qwen3.5 音色复刻 |
| --- | --- | --- |
| 输出模态 | `session.output_modalities` | `session.modalities` |
| 分段位置 | `session.audio.input.turn_detection` | `session.turn_detection` |
| 本应用请求 | `speaker_detection`, threshold 0.5 | `server_vad`, 用户静音窗口与阈值 |
| ASR | 自动启用；源语种自动检测 | `input_audio_transcription` 指定模型、源语种 |
| 原文流 | `conversation.item.input_audio_transcription.delta` 累加 | `.text` 的 text/stash 快照 |
| 译文流 | `response.text.delta` 或 `response.audio_transcript.delta` 累加 | 对应 `.text` 快照 |
| 音频 | 输入 16 kHz / 输出 24 kHz，单声道 PCM16 | 当前同样使用此格式 |
| 结束 | 发送 `session.finish`，等待 `session.finished` | 同左 |

官方来源：[模型页](https://help.aliyun.com/zh/model-studio/qwen3-8-livetranslate-flash-realtime)、[使用指南](https://help.aliyun.com/zh/model-studio/qwen3-5-livetranslate-flash-realtime)、[客户端事件](https://help.aliyun.com/zh/model-studio/live-translator-client-events)、[服务端事件](https://help.aliyun.com/zh/model-studio/live-translator-server-events)。文档及实际 session 回包共同核验；speaker_detection 不是客户端静音阈值的另一个名字，也不保证响应段恰好对应语法上的一个句子。

旧实现把顶层 `turn_detection` 和 `input_audio_transcription` 同时发给 qwen3.8。新实现移除这些旧版字段，发送嵌套的说话人检测配置。服务端 `session.created` 实测包含默认 silence_duration_ms=2500；此次 `session.updated` 的嵌套配置回显 speaker_detection/0.5，但不含 silence_duration_ms。因此日志不能把客户端的 1000/1500 ms 当作 qwen3.8 已接受的停顿值。日志已改为按模型读对应配置，只说“回显”，并明确字段缺失。

声音复刻开关仍选择 qwen3.5，不能一边开启复刻、一边声称正在验证 qwen3.8。界面补充两条路径说明；译声音量为零时也允许关闭复刻。当前本机已关闭复刻，使用新 Debug 构建；双向采集偏好与音量保持原设置，未启动麦克风实测。

## 可重复的真实调用

输入文件：用户下载的《四级 Passage 1 (2/2)》，解码后 **57.9668125 秒**。

MP3 SHA-256：`9e623dc9d67e74de278a9b5bde5c615373aec2ed9060e781a4373b0effa1e09f`。

`scripts/replay-translation.sh` 用 FFmpeg 解码为 16 kHz mono PCM16，再编译并直接使用生产 `TranslationClient`、`ServerItemLinks`、`CredentialStore`。每 100 ms 发送 3200 字节，按单调时钟控制节奏；末尾补 2 秒静音，再正常 finish。凭据从现有环境变量或应用钥匙串读取，不打印、不写文件。JSONL 记录服务器事件、时间及音频字节数，删除音频 Base64，不记录鉴权头。

```sh
./scripts/replay-translation.sh '/absolute/path/to/input.mp3' /tmp/qwen38-audio.jsonl audio
./scripts/replay-translation.sh '/absolute/path/to/input.mp3' /tmp/qwen38-text.jsonl text
```

输出文件必须不存在，避免覆盖已有证据。依赖 macOS Swift 工具链、FFmpeg、可用的百炼凭据；调用会使用服务配额。

| 指标 | 文本＋音频 | 纯文本 |
| --- | ---: | ---: |
| 模型 | qwen3.8 | qwen3.8 |
| 会话数量 / 错误事件 | 1 / 0 | 1 / 0 |
| 原文增量次数 | 68 | 71 |
| 译文增量次数 | 70 | 73 |
| 完整响应 | 2 completed | 2 completed |
| session.finished | 已收到 | 已收到 |
| 首批译文，距创建客户端 | 4.019 s | 3.541 s |
| 收到的输出 PCM 时长 | 50.24 s | 0 |
| 最后一句 | 原文、译文均保留 | 原文、译文均保留 |

首批时间包含握手，不是声卡延迟，也不是严格的音频语义对齐延迟。实际流式结果在响应结束前持续到达；两个约半分钟的 response 不代表等待半分钟才出字。

完整本地证据：`/tmp/livetranslate-qwen38-replay.jsonl`、`/tmp/livetranslate-qwen38-text-replay.jsonl`。与同目录 LRC 比较，忽略大小写/标点、统一数字 3 与 three 及 paperbound 拼写后，音频路径 ASR 为 134 个参考词上的 3 次词编辑（约 2.24%）。这是单样本与随附字幕的近似比较，不是正式 ASR 基准；仍存在个别识别及译文措辞问题。

## 客户端回归

从真实音频路径中提取 41 个关键事件，保留顺序和关联结构，把正文与标识替换为合成素材，移除音频及计费详情，保存为 `Qwen38RecordedFixture.swift`。通过真实解码器与字幕模型重放，验证：两条来源仅生成两张卡、最终文本尾部不丢失、无误报 interrupted；同时参数化覆盖 text/audio_transcript 两条解析路径。

最终 **126 个测试、127 次参数化执行通过，0 失败、0 跳过**：`/tmp/livetranslate-audio-opt/Logs/Test/Test-LiveTranslateBridge-2026.09.22_16-08-45-+0800.xcresult`。

边界：此次 MP3 回放验证文件→生产 WebSocket 客户端→云端响应；事件重放验证客户端字幕归属。未把它写成系统 Process Tap、麦克风、设备播放及主观听感的完整验收。原始音频文件和歌词没有复制进仓库。

## qwen3.8 优先与音色复刻（16:29 更新）

用户要求重点支持 qwen3.8。已移除“复刻开启 → qwen3.5”的自动模型选择，以及丢失复刻音色时的普通音色静默回退。所有 Config.modelID 均为 qwen3.8，普通音色、once、always 及固定复刻 ID 不改变模型。旧 VAD 停顿控件从设置移除，不再暗示它们作用于 qwen3.8。

实测配置：

```json
{
  "output_modalities": ["text", "audio"],
  "translation": {"language": "zh"},
  "audio": {
    "input": {"turn_detection": {"type": "speaker_detection", "threshold": 0.5}},
    "output": {"voice": "default"}
  },
  "voice": "default",
  "enable_voice_clone": true,
  "voice_clone_options": {"frequency": "always"}
}
```

先用同一文件前 18 秒验证：只发送顶层复刻参数时，嵌套输出音色仍回显 Tina；显式发送 audio.output.voice=default 后，嵌套音色也正确回显。两轮均收到音频并 completed，但仅顶层回显不足以作为配置一致性依据。因此生产客户端核对 enable_voice_clone、frequency 及嵌套 voice，失败时终止并报错。

随后通过生产客户端完整回放 57.9668125 秒文件：1 个 qwen3.8 会话，0 error，70 次 ASR delta，73 次译文 delta，169 个音频块，2 个 completed 响应，正常 session.finished。原始证据 `/tmp/qwen38-clone-full.jsonl`（音频载荷单独保存在相邻 .pcm 文件）；可试听 WAV 位于 `build/validation/qwen38-clone/translated-voice.wav`。此验证证明复刻配置回显和生成链路可用，不声称真人已确认音色相似度。

回放脚本新增音色参数：

```sh
./scripts/replay-translation.sh '/absolute/path/to/input.mp3' /tmp/qwen38-clone.jsonl audio always
# 我的声音对应 once；普通音色用 preset。
```

生成音频保存在 output.jsonl.pcm（24 kHz mono PCM16）；JSONL 不包含音频 Base64 或鉴权头。用户固定音色 ID 的服务端有效性仍取决于实际已创建的音色，不冒充已验证的样本。

回归增加：qwen3.8 的复刻配置不能落到旧版 schema、Tina 与 default 回显不一致必须报错、丢失复刻音色不静默回退。最终 128 个测试、129 次参数化执行通过，0 失败、0 跳过。结果：`/tmp/livetranslate-audio-opt/Logs/Test/Test-LiveTranslateBridge-2026.09.22_16-28-54-+0800.xcresult`。新构建已启动，并通过 UI 恢复开启音色复刻。
