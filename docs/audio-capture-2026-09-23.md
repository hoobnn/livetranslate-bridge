# 音频采集与播放链路重构（2026-09-23）

对照开源实现（insidegui/AudioCap）、Apple「Capturing system audio with Core Audio taps」与 macOS 27 SDK 头文件，逐项核对后修改。每一项都在本机（macOS 27.0 / 26A428，Apple Silicon）实测过。

## 发现的问题与处理

| # | 问题 | 影响 | 处理 |
|---|---|---|---|
| 1 | 按精确 bundle ID 只 tap **一个**进程对象 | Chrome、飞书、QQ 等从 `*.helper` 进程出声，选「Google Chrome」实际 tap 到不出声的主进程，只能录到静音；Chrome 有两个 helper 对象时也只 tap 其中一个 | 按可执行文件路径所在的最外层 `.app` 判断进程归属（`proc_pidpath`），应用列表把 helper 合并到所属应用；tap 用 macOS 26 的 `CATapDescription.bundleIDs`，覆盖应用本身和全部 helper |
| 2 | 应用每次开始 / 停止播放都拆掉再重建 tap 和聚合设备 | 恢复播放后的第一段声音丢失；静音接管反复开关 | `bundleIDs` + `processRestoreEnabled` 让 tap 在会话里只建一次。实测：应用未启动时即可建 tap，启动后自动出数据，退出后 tap 仍在；只有出现新 helper bundle ID 时才重建 |
| 3 | `AVAudioConverter` 立体声 → 单声道没开 `downmix` | 实测只保留左声道，偏右声道的说话人进 ASR 时是**静音** | `downmix = true`，SRC 质量设为 `.max`；新增 `rightOnlyStereoReachesRecognition` 测试 |
| 4 | 麦克风用 `installTap`，API 下限 100 ms 一包，且回调不在实时线程 | 上行句尾平均晚约 90 ms 到服务端 | 改用 `AVAudioSinkNode`：实时线程，设备 IO 大小（实测 512 帧 / 10.7 ms、每秒 94 次） |
| 5 | 原声逐块 `scheduleBuffer` 到 `AVAudioPlayerNode`，经两次队列跳转 | 延迟随 worker 抖动变化，块迟到就出现空隙 | `AVAudioSourceNode` 从无锁环形缓冲拉取：40 ms 抖动缓冲、200 ms 上限一次追回、欠载补静音并重新缓冲 |
| 6 | 音量渐变用 `asyncAfter` 分 5 步改 `volume` | 阶梯式变化，压低时机依赖完成回调 | 渲染线程逐采样一阶平滑（增益 15 ms；压低 40 ms 起、300 ms 放），压低按译声缓冲实时判断 |
| 7 | 每秒轮询设备快照，快照包含 IO 缓冲大小 | 其他应用调整共享设备缓冲时整个会话（含 WebSocket）被重建 | 改为 Core Audio 属性监听 + 300 ms 去抖 + 5 秒兜底；快照去掉缓冲大小 |
| 8 | tap 格式读自聚合设备的流格式 | 设备切换时可能滞后 | 读 `kAudioTapPropertyFormat` 并校验为 Float32 PCM |

实测 `AVAudioPlayerNode.volume = 2.0` 确实会放大，旧实现的 >100% 增益本来就可用，不属于本次问题。

## 调研后没有采用的做法

- **聚合设备挂真实输出设备作为主设备（AudioCap 的写法）**：本机实测只挂 tap 的私有聚合设备能正常出数据（48 kHz 连续，无丢帧），继续沿用，避免和用户选择的输出设备耦合。
- **Voice Processing IO 回声消除**：需要输入输出处在同一个 VPIO 单元 / 聚合设备里，和本 App「输入、监听、虚拟输出分别绑定不同设备」的路由冲突，还会改变输入声道格式、默认压低其他应用音量。需要单独做实机验证，本轮不接入。
- **私有 TCC SPI 预检系统录音权限**：属于私有接口，继续依赖系统在创建 tap 时弹出的官方授权提示。
- **原声连续变速的漂移补偿**：抖动缓冲的追赶 / 重新缓冲已经能吸收常见的 ppm 级漂移；只有麦克风与输出设备时钟相差较大时，才会偶尔出现 40 ms 级的跳跃。

## 验证

- 单元测试：131 项通过、0 失败（新增下混与 helper 归属两项）。
- 硬件 harness（直接编译 `CallAudioKit`）：tap 在 QuickTime 未启动时建立，播放 `samples/downlink.wav` 期间持续有数据（峰值 0.4–0.83），QuickTime 退出后 tap 继续读静音；麦克风 sink 每秒 94 × 512 帧；source node 播放器在默认输出上以 0 音量运行，1 秒译声播完后状态正确回落；停止后无残留聚合设备。
- 未做：带翻译服务的真实通话端到端、BlackHole 回环实测、长时间漂移观察。
