# 实时语音声纹训练接入与权限验证 · 2026-10-23

本轮将录音上传和声纹训练接入豆包端到端实时语音模式，使用新版 V3 接口和现有 API Key。现有 Key 的真实权限验证结果是：**查询与训练均被服务端拒绝，尚不能完成真实声纹训练及复刻音色通话验收**。不把本地测试或预置音色通话结果当作复刻成功。

代码接入与本地验证已完成：完整单元测试 **276 项通过，0 失败、0 跳过、0 runtime warnings**；参数展开共 306 次执行。包含 14 项 V3 服务测试、11 项训练控制器测试，以及训练返回音色 ID 进入生产实时会话配置的集成回归。独立只读复核及 `git diff --check` 通过。

## 应用内流程

「设置 → AI 代聊 → 豆包端到端实时语音」现在提供录音选择、参考文本、中英语言、训练上传、状态查询、剩余次数与错误诊断。支持已分配 `S_…` 和后付费自定义名称。成功后显式点「用于实时通话」，采用服务返回的音色 ID；训练和应用音色在通话运行期间不可操作。

上传前生成并持久化同一 request ID 和音色 ID；不存录音、参考文本或 API Key。超时、HTTP 408/5xx、无效成功响应等不确定结果不自动重试，重开设置也必须先查询。查询失败保留原始训练 ID，不用查询 ID 覆盖；查询失败后不能再应用上次的成功结果。新文件导入失败会清除旧样音，避免用户以为上传 B，实际上上传了 A。

导入只读取文件与音频时长，不创建播放器，不下载或播放训练返回的预览。录音推荐 14–30 秒，不把这个建议当作硬性时长门槛；严格检查支持格式、非空数据与 10 MB 上限。测试的偏好设置使用内存隔离。

## 现有 Key 的真实结果

凭据从应用现有登录钥匙串读取，只留在测试进程内，不写入日志、命令参数或测试结果。

| 操作 | 请求 | 实际结果 |
|---|---|---|
| 音色状态查询 | `POST /api/v3/tts/get_voice`，唯一测试名称 | HTTP 403，`45000030`，`[resource_id=volc.megatts.timbre] requested resource not granted` |
| 训练权限探针 | `POST /api/v3/tts/voice_clone`，唯一测试名称和有效 WAV | 同样 HTTP 403 / `45000030` / 音色服务未授权 |

每个端点只调用一次，没有重试。训练输入是 `say -o` 生成的测试语音，16.61 秒、24 kHz、单声道 WAV；没有使用用户本人的录音，没有覆盖已有音色。训练被明确拒绝，没有请求正式合成或后付费音色激活。

查询的 request ID：`716f72fe-58fb-41ce-a6ea-e75f08922b62`，log ID：`202610231540406445ED1CEE7B7724F2D2`。

训练的 request ID：`66c846c3-6a19-4fe9-9cf2-e6bfe1a9098c`，log ID：`2026102315443426FB8880088447908954`。

本机证据目录：`/private/tmp/livetranslate-voice-training-smoke`，包含 `permission-query.json`、`training-attempt.json` 和生成的测试录音。Key 未保存到这些文件。

最终完整测试结果包：`/private/tmp/livetranslate-voice-training-final.xcresult`；日志在证据目录的 `final-tests.log`。Swift 6 严格检查通过，服务新增代码无诊断；依赖中保留既有 weak-self 并发警告。

需要在同一 Key 所属项目开通音色服务和声音复刻能力，并取得可用于测试的音色 ID，才能继续真实验收。此前成功的预置 Jupiter 实时通话，只证明实时模型权限，见[实时语音报告](doubao-realtime-integration-validation-2026-10-23.md)。

## 接口与行为

训练使用 `POST https://openspeech.bytedance.com/api/v3/tts/voice_clone`，查询使用 `/api/v3/tts/get_voice`。新版鉴权只需 `X-Api-Key`、`X-Api-Request-Id` 和 JSON Content-Type，不要求旧 App ID。训练音频为 `audio.data` 的 base64 和 `audio.format`，参考文本位于顶层 `text`，实时模式训练语言为中文或英语。

V3 不再发送 V1 的 `model_type`、`source`、`audios` 和 body `appid`。状态 2（Success）或 4（Active）才可用于通话；训练次数读取 `available_training_times`。HTTP 200 本身不等于训练成功，必须解析明确的音色和状态。

音色 ID 可为控制台已分配的 `S_…`。后付费自定义名称通过 `speaker_id="custom_speaker_id"` 加 `custom_speaker_id` 提交；不自动创建或购买槽位。后付费首次正式合成会收取槽位费用并锁定音色，因此训练完成后也不自动激活或发起试听。

参考官方[音色注册](https://docs.volcengine.com/docs/DoubaoVoice/tone-training-http?lang=zh)、[音色查询](https://docs.volcengine.com/docs/DoubaoVoice/tone-query-http?lang=zh)、[V3 迁移说明](https://docs.volcengine.com/docs/DoubaoVoice/SoundReplicaAPI-V3?lang=en)、[音色开通与生命周期](https://docs.volcengine.com/docs/DoubaoVoice/Soundreplicationorderingandusageguide?lang=zh)。

## 继续真实验收的条件

1. 同项目的当前 Key 已开通音色服务 / 声音复刻权限。
2. 提供一个空闲的预付费 `S_…` 音色 ID，以及训练录音；仅验证链路时可继续使用已生成的测试录音，不能将其称为本人声纹。
3. 一次提交 → 查询到可用状态 → 将返回音色 ID 放入实时会话 → 文件模拟问题得到回答和 PCM → 验证取消与关闭。

如选择后付费自定义音色，应先确认训练预览，再显式决定是否正式使用；不为了权限测试自动产生槽位费用。

全程没有使用扬声器、打开麦克风或拨打真实电话。未替换已安装应用、提交或推送代码。
