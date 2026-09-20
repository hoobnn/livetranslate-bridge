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
