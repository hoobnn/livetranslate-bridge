# 豆包语音集成测试 · 2026-10-23

结论：使用应用钥匙串内的 API Key，真实同传的字幕、预置译声、实时克隆译声、纯转录，以及独立 HTTP 语音合成均已获得正常结果。测试发现并修复了 Float32 音频误当 Int16、音色 protobuf 字段过时、关闭后误报就绪、HTTP 空响应误报成功的问题。最终 201 项单元测试通过，0 失败、0 跳过。

本次未播放任何声音。输入由 macOS `say -o` 生成到文件；回放程序只上传文件和保存返回音频，没有播放器。音频验证覆盖格式、样本、电平和时长，没有人工听感验收，也没有真实通话或麦克风采集验收。

后续修复和 AI 模拟通话验证见[第二轮报告](ai-call-simulation-validation-2026-10-23.md)。本页的 201 项测试为首轮结果。

## 真实服务结果

输入英文 5.139 秒，中文 5.695 秒，每次按 100 ms 上传并追加 2 秒静音。

| 测试 | 结果 | 核验内容 |
|---|---|---|
| 英文 → 中文字幕，`s2t` | 通过 | 3 段原文、3 段译文，0 音频字节，正常结束 |
| 中文 → 英文译声，预置音色 | 修复后通过 | 3 段原文与译文；295,988 字节 Int16，6.166 秒；峰值 0.573，RMS −20.02 dBFS |
| 英文 → 中文译声，实时克隆 | 修复后通过 | 3 段原文与译文；248,974 字节 Int16，5.187 秒；峰值 0.847，RMS −14.31 dBFS |
| 中文纯转录 | 通过 | 3 段原文，0 译文，0 音频字节，正常结束 |
| `/api/v3/tts/unidirectional` | 通过 | 默认音色合成中文短句，144,000 字节 Int16，3 秒，正常完成 |

示例原文 `Our meeting starts at 3 tomorrow afternoon.` 返回 `我们的会议明天下午三点开始。`；中文 `我们明天下午三点开会。` 返回 `We have a meeting tomorrow at 3 p.m.`。

修复后的两次同传分别约 0.444 秒和 0.391 秒进入就绪。这是本机短样本的单次观察，不是延迟基准。

## 发现与修复

1. **24 kHz 音频格式错误**：服务实际返回 Float32。修复前的两份真实响应按 Float32 解读时，所有样本均为有限值、幅度小于 1；按 Int16 解读会把每个样本拆成两个，使时长翻倍并引入错误信号。现在明确请求 `bits=32`，在 `DoubaoTranslationClient` 内转换为共享播放器和录音器需要的 Int16 LE。普通音频帧和句尾帧均转换，并处理溢出、非有限值与不完整样本。
2. **音色 protobuf 字段过时**：当前 `is_custom_speaker=7`、`tts_resource_id=8`；原实现写入 5、6。当前 5、6 已是 `speech_rate`、`enable_source_language_detect`，现已按官方 proto 修正。已训练 `S_` 音色仅验证编码，未做真实合成。
3. **关闭后误报 ready**：关闭时清理 `isStarted`，查询就绪时优先判断已关闭状态。
4. **HTTP 成功误判**：语音合成现在要求有效音频与完成帧；空流、坏 JSON/base64、缺状态码、提前结束均报错，最后一帧携带音频时也能完整交付。声音训练的响应要求有效 JSON 和 `BaseResp.StatusCode`。这些异常由本地 `URLProtocol` 驱动真实 HTTP 处理路径验证，没有调用训练服务。

官方依据已于本次实时读取：[同声传译 2.0 文档](https://docs.volcengine.com/docs/DoubaoVoice/SimultaneousInterpretation20APIAccessDocumentation?lang=zh) 及其所链接 Python 示例。文档参数表说明 `pcm16000=16bit`、`pcm24000=32float`；示例的 `ast_service.proto` 确认字段 7、8。proto SHA-256：`279990188e83bef3969d3faa57a4e49408734f0cbf489d4fc894807de5f3e6bf`。

## 回归证据

基线 192 项通过。新增 HTTP 与关闭状态用例先复现失败；音频格式、音色字段、真实音频转交用例也先复现失败，再实施修复。最终测试 201 项通过（参数展开为 211 次执行），0 失败、0 跳过。

```bash
xcodebuild test -project LiveTranslateBridge.xcodeproj \
  -scheme LiveTranslateBridge -destination 'platform=macOS' \
  -only-testing:LiveTranslateBridgeTests \
  CODE_SIGN_IDENTITY=- CODE_SIGN_STYLE=Manual DEVELOPMENT_TEAM=
```

音频路由测试使用 `manualRendering: true` 离线渲染，不输出至硬件。

可复用真实服务回放命令见 [samples/README.md](../samples/README.md)。新增脚本直接编译项目生产客户端，输出 JSONL 和 24 kHz Int16 PCM，禁止覆盖既有输出，失败退出非零，不包含密钥。

本机证据位置（未纳入 Git）：

- `/private/tmp/livetranslate-doubao-smoke/results.json`：逐项汇总、原文/译文及音频指标。
- `/private/tmp/livetranslate-doubao-smoke/*.jsonl`、`*.jsonl.pcm`：真实服务事件与返回音频；`*-fixed` 为格式修复后的结果。
- `/private/tmp/livetranslate-doubao-smoke/tts-preset-summary.json`：独立 HTTP 合成结果。
- `/private/tmp/livetranslate-doubao-smoke/official/`：本次读取的官方正文与 proto。
- `/private/tmp/livetranslate-doubao-final.xcresult`：最终完整单元测试。
- `/private/tmp/livetranslate-doubao-audio-red-permitted.xcresult`：音频与字段修复前的 3 项失败。

## 剩余边界

- **多句合并译文的卡片收尾缺口已在第二轮修复**：补充了合并、分拆、时间边界与会话终结回归，详见[第二轮报告](ai-call-simulation-validation-2026-10-23.md)。原始失败证据保留在 `/private/tmp/livetranslate-doubao-merged-review.xcresult`。
- 当前凭据没有 App ID 或已训练的 `S_` 音色；旧版 App ID + Access Token 登录、真实声音训练与已训练音色合成未做云端验证。未上传训练样本、未消耗训练次数。
- 未验证长通话、断网恢复、所有语言组合、实际音频设备与通话回环，也未进行扬声器或耳机试听。
- 工作开始前已有的 `SubtitleModel.swift` 修改保持原样。本次未提交、未推送。
