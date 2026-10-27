# 豆包端到端实时语音集成验收 · 2026-10-23

本轮按用户要求，先以应用已有的豆包语音 API Key 验证权限，再接入端到端实时语音，使用生产 `CallAgent` 和 WebSocket 客户端跑真实模型模拟通话。不需要另配火山方舟 Chat 模型或 API Key。

最终真实模拟通话 **通过**：原定三点 → 人工改约四点 → AI 正确确认四点；生成中接管后无迟到音频交付，服务端确认取消与关闭。完整单元测试 **250 项通过，0 失败、0 跳过、0 runtime warnings**，参数展开共 264 次执行。独立只读复核及 `git diff --check` 通过。

所有音频输入均来自文件，输出仅保存为 PCM；没有创建扬声器播放器、打开麦克风或拨打真实电话。文件输入通过 `say -o` 生成，再转换为 16 kHz 单声道 Int16。模拟上传遵循每 20 ms 640 字节，模型输出为 24 kHz 单声道 Int16。

## 权限与协议

- 应用钥匙串中的现有 API Key 成功创建和关闭会话，取得 `session.created`、`session.closed`；首次就绪约 0.54 秒。该探针不上传音频。
- 端点：`wss://openspeech.bytedance.com/api/v3/duplex/realtime/dialogue`；使用 `X-Api-Key`，模型版本 `1.2.6.1`，默认音色 `zh_female_vv_jupiter_bigtts`。
- 当前产品集成限制为中英通话，要求新版 API Key（App ID 留空）。AI 回答字幕只显示所说语言，对方原话的双语字幕继续走原翻译服务。实时语音音色与同传、声音复刻分开配置。
- 依据[官方端到端实时语音 3.0 协议](https://docs.volcengine.com/docs/DoubaoVoice/endtoend-realtime-voice-full-duplex-version?lang=zh)及真实返回实现。官方正文已通过文档 API 取得并留存于本机验收目录。

## 真实模型暴露并修复的问题

订单 A123 原始资料是明天下午三点，人工接管改为四点。向原会话注入完整 QA，再更新 instructions，两种请求都收到服务端确认，但模型第二次仍回答三点。不能用确认回执代替模型行为验收。

单变量对照：把同样的新 instructions 放进新会话的初始请求，真实回答变为：`Order A123 is confirmed for 4 o'clock tomorrow afternoon.`。因此产品在明确的“交还给 AI”操作时关闭旧连接，用最新资料和人工接管记录创建新会话；就绪后注入最近的完整 QA，再开放输入。等待新音频问题，不把资料或指令当成用户语音播放。

通话中编辑资料只更新本地配置，下次交回 AI 时生效，面板明确说明。编辑器逐字更新不会触发付费重连。上下文限制最近 20 组完整 QA，单条最多 4 KB、总量最多 16 KB；人工主动更正即使没有对应问题，也会进入优先级更高的初始说明。

其他边界：接管同步停传、取消回复并清空输出；新会话 epoch 和输出令牌拒绝旧回调；空上下文不发无效请求；音色清空时回退 Jupiter；连接时显示状态并禁用主动开场。保留 Chat + TTS 模式及原有回归。

收尾复核还修复了三个传输问题：`connect()` 自带 15 秒握手上限；20 ms 音频节奏使用绝对时钟，避免每帧处理开销逐渐积成输入延迟；observer 的跨线程读取和解除订阅使用锁保护，取快照后在锁外执行。13 项传输测试、11 项产品集成测试均包含在最终完整回归中。

## 最终真实通话结果

最终脚本使用两条真实服务连接，约 26 秒完成，没有替换模型或语音服务。录音转写完整识别了两次订单询问。

| 步骤 | 实际结果 |
|---|---|
| 第一轮问送达时间 | `Order A123 is scheduled to be delivered tomorrow at 3 PM as we agreed.` |
| 人工接管 | 本地记录 `Yes. Order A123 is now confirmed for four tomorrow afternoon.` |
| 交回 AI | 新会话初始资料含人工决定，收到 ready 和 QA 注入确认后上传第二个问题 |
| 第二轮问最终时间 | `Order A123 is confirmed for 4 o'clock tomorrow afternoon.` |
| 生成中再次接管 | `takeOver()` 返回时即取音频字节基线，直到取消确认及其后 300 ms 字节数均未增长；诊断日志确实收到过取消后的音频，未进入应用输出 |
| 关闭 | 收到 `session.closed`，不是只检查 WebSocket 本地断开 |

应用输出文件累计 506,542 字节，24 kHz 单声道 Int16，约 10.55 秒音频，非零采样检查通过；该文件包含两次回答及被打断开场的已交付片段。未对音质作听感验收。AI 音频在产品集成回归中另外走过生产音频管道和离线 `TranslationPlayer(manualRendering: true)`。

## 复现

在应用「设置 → 凭据」保存有相应权限的豆包语音 API Key，然后选择「AI 代聊 → 豆包端到端实时语音」。目标和资料在字幕页的 AI 面板填写。正常通话需选择“对方听到”的输出设备。

无扬声器模拟使用两个固定问题录音：

1. `Hello, I am calling about order A123. When will it arrive?`
2. `Please confirm the final delivery time for order A123.`

```bash
./scripts/replay-ai-realtime.sh caller-one.wav caller-two.wav /tmp/ai-realtime-new-result
```

脚本使用生产实现，只替换输入来源和输出文件接收端；不使用模拟模型。输入最长 30 秒，输出目录不得已存在，会产生服务用量。可通过 `DOUBAO_API_KEY` 设置进程凭据，密钥不写入结果。`summary.json` 同时检查回答语义、接管后迟到音频和关闭确认。

## 证据与验收边界

本机证据根目录：`/private/tmp/livetranslate-realtime-smoke`。API Key 未写入证据，事件日志只保存文本、ID、时间和音频字节数，不保存鉴权头或 base64 音频。

| 证据 | 内容 |
|---|---|
| `permission-summary.json` | 现有 Key 创建、关闭成功；无音频输入 |
| `official-realtime.md` | 本轮取得的官方协议正文 |
| `protocol-call-events.jsonl` | QA 注入已确认，模型仍沿用三点的原始负面证据 |
| `production-call-1/summary.json` | 生产客户端同会话更新后仍答三点，明确 `passed=false` |
| `initial-manual-summary.json` | 同样的新说明放入新会话后正确回答四点的对照 |
| `production-call-2/summary.json` | 最终生产实现真实模拟通过：两个回答、改约、新会话、接管和关闭均满足判定 |
| `production-call-2/events.jsonl` | 原始回执、转写、回答、音频字节数与时间 |
| `production-call-2/delivered.pcm`、`audio-metrics.json` | 应用实际接收的 PCM 及非零采样检查；未播放 |
| `final-tests.log` | 最终完整单元测试日志；结果包 `/private/tmp/livetranslate-realtime-final.xcresult` |

原始 `protocol-call-summary.json` 的 `passed` 仅检查协议两轮完成与关闭，不代表改约语义通过；以生产脚本的语义判定为准，负面证据保留不覆盖。

完整单元测试复现：

```bash
xcodebuild test -project LiveTranslateBridge.xcodeproj \
  -scheme LiveTranslateBridge -destination 'platform=macOS' \
  -only-testing:LiveTranslateBridgeTests \
  CODE_SIGN_IDENTITY=- CODE_SIGN_STYLE=Manual DEVELOPMENT_TEAM=
```

本轮证明文件输入到真实模型、生产状态机、回答文本与 PCM 文件输出的链路；不代表真人抢话体验、实际通话软件、回环设备、已安装应用或扬声器音质已验收。未提交、推送或替换已安装应用。先前同传和 Chat 本地模拟结果分别见[同传报告](doubao-integration-validation-2026-10-23.md)、[本地模拟报告](ai-call-simulation-validation-2026-10-23.md)。
