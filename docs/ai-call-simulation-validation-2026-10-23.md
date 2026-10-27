# AI 代聊修复与本地模拟通话 · 2026-10-23

本轮已修复首轮报告留下的多句合并字幕收尾问题，以及 AI 通话测试中新确认的取消、音频队列、空回答和默认音色问题。按用户安排，真实对话模型测试推迟；本轮模拟服务全部在本机运行，没有拨号、没有调用云端模型或语音服务，没有使用扬声器。

最终完整单元测试 **226 项通过，0 失败、0 跳过**；参数展开为 240 次执行。`git diff --check` 通过。独立只读复核确认生产默认仍连接真实服务，测试隔离钥匙串、网络、真实偏好设置和硬件音频。

## 模拟通话实际走过的路径

`SubtitleModel` 接收对方字幕事件 → 生产 `CallAgent` 组织资料和历史 → 本地 Chat 夹具返回双语回答 → 本地语音夹具生成 Int16 PCM → 生产音频管道和 `TranslationPlayer(manualRendering: true)` 离线渲染 → 字幕板记录双方内容。

模型和合成服务使用可控的异步夹具；状态机、字幕板、音频管道和离线播放器使用生产实现。模拟音频是 24 kHz 测试信号，验证数据交付和渲染，不代表实际语音质量。

| 场景 | 验收内容 |
|---|---|
| 自动回答 | 对方询问 A123 订单送达时间；AI 回答明天下午三点；字幕板显示英文及中文释义；24,000 字节 PCM 进入离线播放器，渲染样本非零 |
| 用户接管 | 本地开始说话立即进入人工状态并清空剩余 AI 音频；用户将三点改为四点 |
| 交还 AI | 对方再次确认时 AI 保持安静；手动交还后，下一次 Chat 请求携带用户改为四点的历史；第二段回答正常进入字幕与音频管道 |
| 结束 | 道别回答的 `hang_up=true` 使 AI 停止继续代聊；这不会自动挂断真实电话 |
| 默认音色 | 未填音色仍可监听并应答；已配置预置音色或训练音色时保留原选择 |
| 启动条件 | 缺少 Chat 凭据或对方输出静音时不开始自动应答，并显示原因 |

另以手动控制 completion、取消与迟到回调的方式验证 13 项生命周期场景：自动应答、多句防抢话、思考时被打断、语音中被打断、接管未发声音频、直接重建会话、停止后恢复、Chat/TTS 失败重试、主动开场、停止时撤回、部分音频失败后不重复答复、生成结束后的残留音频打断，以及空回答恢复。

## 修复内容

- 合并译文的有效 `end_time` 覆盖已结束的后续原文卡片时，立即关闭这些卡片；分拆译文、部分覆盖、时间缺失/倒退不误关。会话结束会补齐剩余卡片，重复结束保持幂等。
- `begin/end`、远端打断与人工接管都取消旧任务。每次回答持有独立音频令牌，取消后拒绝迟到音频；旧请求结束不能修改新会话的历史或回调。
- 还没发出音频的回答被取消时，立即从字幕和对话历史撤回；已发出一部分的回答保留，交还 AI 时不自动重复。
- 语音生成结束后可能仍有待处理音频；远端重新说话会清理队列，人工接管状态不受干扰。
- HTTP 200 的空白 Chat 内容及结构化空 `say` 都明确失败，保留待回答上下文，允许通过交还 AI 重试。
- 音色留空时回退到默认预置音色，和人工接管后的译声保持一致。界面和中英文说明同步更新，提示词不再无条件声称已克隆声音。
- 异步读取凭据后检查会话代际，避免旧启动任务在停止或重建后重新启动 AI。

服务注入的默认值仍调用原来的真实 Chat/TTS；普通应用启动不使用测试夹具。测试凭据不会写入钥匙串；模型使用临时内存偏好设置和内存会话历史。

## 复现与证据

只跑本地 AI 模拟：

```bash
xcodebuild test -project LiveTranslateBridge.xcodeproj \
  -scheme LiveTranslateBridge -destination 'platform=macOS' \
  -only-testing:LiveTranslateBridgeTests/AICallSimulationTests \
  -only-testing:LiveTranslateBridgeTests/CallAgentLifecycleTests \
  CODE_SIGN_IDENTITY=- CODE_SIGN_STYLE=Manual DEVELOPMENT_TEAM=
```

先红后绿证据（本机，未纳入 Git）：

- `/private/tmp/livetranslate-agent-tests-red.log`：合并字幕和结束收尾的两项原始失败。
- `/private/tmp/livetranslate-local-simulation-red-compiled.xcresult`：默认音色缺失使 AI 无法启动和完成模拟通话。
- `/private/tmp/livetranslate-local-simulation-green.xcresult`：默认音色修复后的模拟通话通过。
- `/private/tmp/livetranslate-call-agent-red.xcresult`：旧语音迟到、撤回不及时、重建未取消的原始失败。
- `/private/tmp/livetranslate-call-agent-tail-red.xcresult`：残留音频无法打断、空回答无法恢复的原始失败。
- `/private/tmp/livetranslate-call-agent-chat-red.xcresult`：空白 Chat 响应误成功。
- `/private/tmp/livetranslate-ai-call-final.xcresult`：最终完整单元测试。

## 后续真实模型验收

本报告记录当时的 Chat + TTS 本地模拟。随后用户选择接入豆包端到端实时语音，复用现有语音 API Key，无需另配 Chat 模型。最新实现与真实服务模拟结果见[端到端实时语音验收报告](doubao-realtime-integration-validation-2026-10-23.md)。

真实模型的回答质量、实际语音时延与音质、真人抢话时机、麦克风/回环设备和真实通话连接均未由本轮夹具测试证明。原有豆包真实服务结果见[首轮集成报告](doubao-integration-validation-2026-10-23.md)。本轮没有提交、推送或替换已安装的应用。
