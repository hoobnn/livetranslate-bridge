# 实测样本

2026-09-20 采集，与运营商 IVR 机器人的真实通话，无第三方自然人。

| 文件 | 来源 | 格式 | 时长 |
|---|---|---|---|
| `downlink.wav` | 进程 tap（`avconferenced` 输出） | 48kHz / 2ch / Int16 | 10.09s |
| `uplink.wav` | `AVAudioEngine` 默认输入 | 48kHz / 1ch / Int16 | 10.00s |

对应 `docs/findings.md` 第三、四节的测量数据。3.5–6.0 秒段 downlink 为数字静音
而 uplink 有信号，是两路可分离的直接证据。

**不纳入版本库**（`.gitignore` 忽略 `*.wav`）：含本机说话声。
需要重新采集用 `CallAudioKit` 自行录制。

用途：ASR 原型的固定回归输入，避免每次验证都要真打电话。

## 豆包文件回放

使用项目的 `DoubaoTranslationClient` 和应用保存的凭据（也支持 `DOUBAO_API_KEY`，
或 `DOUBAO_APP_ID` + `DOUBAO_ACCESS_TOKEN`）测试真实同声传译。需要 Xcode 和 ffmpeg，
输入最长 30 秒，按实际语速上传并追加 2 秒静音。会产生服务用量。

```bash
./scripts/replay-doubao.sh input.wav /tmp/doubao-text.jsonl text en zh
./scripts/replay-doubao.sh input.wav /tmp/doubao-audio.jsonl audio zh en preset
./scripts/replay-doubao.sh input.wav /tmp/doubao-clone.jsonl audio en zh clone
./scripts/replay-doubao.sh input.wav /tmp/doubao-transcript.jsonl transcript zh en
```

脚本不创建播放器，也不使用扬声器。输出为带时间戳的 JSONL 事件和相邻的
`.jsonl.pcm` 文件（24 kHz、单声道、Int16 LE；文字模式为空文件），不会覆盖已有结果。
`clone` 是同传中的实时音色克隆，不上传训练样本。
退出码为 0 要求会话就绪、正常结束、原文完整，并按模式检查译文和音频是否返回。

## AI 端到端实时语音模拟通话

使用生产 `CallAgent` 和 `DoubaoRealtimeClient`，从两个录音文件依次模拟来电，
调用真实语音模型。脚本固定验收 A123 订单：第一段问原定送达时间（明天下午三点），
模拟人工接管改为四点，第二段询问最终时间；最后验证生成中的打断和关闭确认。
输入录音应与这两个问题相符。需要端到端实时语音权限及新版豆包 API Key，
无需另配 Chat 模型；会产生真实服务用量。

```bash
./scripts/replay-ai-realtime.sh caller-one.wav caller-two.wav /tmp/ai-realtime-new-result
```

脚本只读取录音并保存事件、回答及 PCM 文件，不创建播放器或音频设备。
输出目录必须不存在。`summary.json` 的 `passed` 要求真实回答保留三点改四点的约定、
接管后没有迟到音频交付，并收到服务端关闭确认。音频为 24 kHz 单声道 Int16 LE。
钥匙串读取可能触发 macOS 授权，也可通过 `DOUBAO_API_KEY` 提供进程环境凭据。
详见[验收报告](../docs/doubao-realtime-integration-validation-2026-10-23.md)。
