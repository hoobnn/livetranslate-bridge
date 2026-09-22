# 服务端分段关联修复

后续协议审计见 [qwen3.8 对接与完整 MP3 验证](qwen38-protocol-validation-2026-09-22.md)。下文 400/1000/1500 ms 实测属于 qwen3.5；qwen3.8 现使用独立的嵌套 speaker_detection 配置，不能套用这些 VAD 结论。

## 问题与行为

之前解码事件时丢弃了消息/响应标识，每个方向只保存一个当前字幕条目。后一句原文先于前一句译文完成到达时，会写入错误条目。服务端断句正确也可能表现为客户端串句。

现在仍由服务端断句，不增加本地断句器。后续听力回归已将新用户默认静音窗口由 400 ms 调为 1000 ms，并提供 1500 ms 听力选项；保留用户已保存的自定义设置：

- 语音起止与 ASR 通过 `item_id` 归属同一输入段，同时保存服务端音频偏移。
- `previous_item_id` 本身仅表示前序消息，assistant 角色也不代表一定是译文。只有输出已被 response 文本/音频事件确认、前序消息已被 ASR/语音边界事件确认为输入段时，才建立原译文关联；元数据先到时暂存候选关系。译文先到、关联晚到时合并对应条目。
- `response_id` 关联译文和译声；`response.done` 的最终文本、完成/取消/失败/未完成状态都被消费，不再仅打印日志。
- 空文本 done 也结束对应文本流；迟到的另一段事件不会更新此段。重复 `event_id` 去重。
- 会话 ID 与方向参与键值，重连或另一方向的相同 item ID 不会串入旧段。
- 音频按 `response.created` 顺序处理，当前回复生成结束且已排空播放队列后才播放后续回复。取消当前回复可继续后续回复；取消等待中的回复不影响正在播放的回复。
- 已收音频总缓冲上限保持约 15 秒，过载有提示并跳过受影响回复的剩余语音；原声链路不受响应取消影响。
- 日志包含 local/remote、会话、源消息、响应 ID、音频起止位置及结束状态。接收延迟指标按同段关联，只在关联与起止时间均已收到时打印，不冒充声卡播放延迟。

生产事件有标识时走关联路径。无标识旧事件保留兼容处理，但不会猜测合并到已标识语音段。内容块元数据不再当作异常 unhandled event 打印。

## 协议依据

[阿里云实时翻译服务端事件](https://help.aliyun.com/zh/model-studio/live-translator-server-events)：`conversation.item.created.previous_item_id`、ASR 的 `item_id`、译文/译声的 `response_id` 与 `item_id`、`response.done`。

## 验证

`ServerSegmentationTests.swift` 从原始服务端 JSON 驱动实际解码器，再驱动字幕模型，覆盖：

- 两句反向返回；晚到原文和晚到关联；空 done；重复事件。
- 取消前一句不关闭后一句；response.done 的最终文本及 incomplete 状态。
- 服务端音频偏移；跨方向/重连标识隔离；600 段会话归档后迟到事件处理。

`ResponseAudioRoutingTests` 通过生产混音图的离线模式，验证交错音频、响应创建顺序、自然播放排空、取消当前/待播回复以及旧回复迟到音频隔离。离线模式使用 dataRendered 完成事件，真实硬件播放仍用 dataPlayedBack。

运行方式：

```sh
xcodebuild -project LiveTranslateBridge.xcodeproj -scheme LiveTranslateBridge \
  -configuration Debug -derivedDataPath /tmp/livetranslate-audio-opt \
  -only-testing:LiveTranslateBridgeTests test CODE_SIGNING_ALLOWED=YES
```

本轮 xcresult 汇总：125 项通过、0 失败、0 跳过。结果位于 `/tmp/livetranslate-audio-opt/Logs/Test/Test-LiveTranslateBridge-2026.09.22_15-29-12-+0800.xcresult`。

这些测试验证客户端对协议事件的处理，不等于真实云端对自然语音的断句质量验收。若后续仍出现句中停顿触发分段，应使用带方向、item/response 标识的新日志判断服务端边界，分别检查停顿参数和输入串音。

## 15:23 真实会话回归修复

用户截图显示重复原文、截断译文和错误的“译文已中断或未完成”。本机 socket 日志显示：输出消息关联源消息之后，该源消息又被旧实现关联到前一输出消息。服务端 ASR 消息也使用 assistant 角色，因此旧实现按角色读取 previous_item_id 会误建反向关联。该会话已记录的六个 response.done 均为 completed，不能把界面警告归因于服务端中断。

修复使用独立 ServerItemLinks 分类输入/输出事件，候选关系必须通过两端类型验证才交给字幕和音频路径。晚到关联合并不再用空译文覆盖已有内容。停止时只对尚未完成且已有译文内容的条目补 interrupted，保留服务端真实状态。

新增三个回归用例：与日志一致的连续 assistant ASR 消息链；元数据早于 ASR 证据；停止时区分仅原文、完成译文和部分译文。之前 122 项用例没有覆盖 ASR 同样使用 assistant 角色的事件组合，是此次回归漏检原因。此次验证为真实日志定位加合成事件重放和离线音频测试，尚未重跑网易云音乐到云端翻译的真人试听验收。

## 听力材料实测：400 / 1500 / 1000 ms

材料：用户提供的网易云 [四级 Passage 1 (2/2)](https://music.163.com/song?id=28503070)，API 标记约 57 秒，播放器显示约 58 秒。2026-09-22 15:49–15:56 使用新 Debug 构建，真实网易云 Process Tap → 16 kHz PCM → qwen3.5 声音复刻会话 → 字幕/播放队列。两轮同起点，threshold 0.2，只采集网易云，避免麦克风串音。译声音量维持用户原有 0%，因此这里只验证字幕和音频队列，不声称完成译声听感验收。

| 静音窗口 | 材料内服务端完成段数 | 观察 |
| --- | ---: | --- |
| 400 ms | 13 | 连接词、比较短语、书名分别独立成段 |
| 1500 ms | 2 | 26.408 秒及 29.512 秒两个长段，碎切减少但合段过长，仍有译文逻辑不准确及后半段显示内容不完整的观察，不能认定质量通过 |
| 1000 ms | 不计入完整比较 | 第一段结束于输入 15.968 秒；中途会话重建并出现输入暂停，无法作同口径完整比较 |

400 ms 会话 `sess_HXrbBouANtmlTyRFJRWkI`，1500 ms 会话 `sess_LdNXhrQCVTTEHFj2wsBgy`。两轮播放器随后自动切换到下一首，表格只统计结束偏移小于 57500 ms 的本材料语音段，排除下一首。原始 socket 日志保存在 `/tmp/livetranslate-listening-ab.log`；第三轮日志 `/tmp/livetranslate-listening-balanced.log`。这是一次人工操控的实测，不是音频字节完全相同的自动化基准。

实施：默认及恢复默认均改为服务端 1000 ms；保留已有显式自定义配置，提供 400/1000/1500 ms 快捷选项；修正“所有流式文字必须等停顿结束才出现”的错误说明。通过设置 UI 将本机保存的旧 400 ms 改为 1000 ms，恢复实测前双向采集，停止会话并暂停播放器。新版本已启动。长句选项是容忍停顿，不是语义断句保证。

本次测试结果：125 passed / 0 failed / 0 skipped，`/tmp/livetranslate-audio-opt/Logs/Test/Test-LiveTranslateBridge-2026.09.22_15-47-46-+0800.xcresult`。测试覆盖新默认值进入协议、长句配置进入声音复刻协议、恢复默认与用户自定义持久化。

[官方客户端协议](https://help.aliyun.com/zh/model-studio/live-translator-client-events)确认 qwen3.5 的 server_vad 按静音窗口结束段落，默认 1000 ms。服务端断句并不等于语义句界识别。后续若需保证长材料语义完整，应继续采集最终 ASR/译文事件证据，分别定位识别、翻译与客户端展示；不能靠无限增加停顿窗口掩盖。
