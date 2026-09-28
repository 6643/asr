# G2 设计：多键盘监听 + app.zig 拆分 + 三项加固

- 日期：2026-09-28
- 状态：待用户批准
- 前置：`docs/superpowers/specs/2026-09-28-cleanup-and-hardening-design.md`（G1，已完成并合入 `main` → 已推 GitHub `9fa3fa5`）
- 关联审查项：P2-8（单键盘）、A1（app.zig 765 行）、P3（`resetMuteState` 死代码、无 CI）、观察项（偶发 `InputMethodUnavailable`）

## 1. 目标

1. **键盘输入源不再"靠运气"**：修掉主检测路径失效、按能力位筛选真正的键盘、同时监听全部候选键盘（含热插拔补挂），任何一把键盘上的 RightAlt 都能触发录音。
2. **`app.zig` 拆成三个职责清晰的模块**（纯搬移，行为不变）。
3. **三项加固**：启动时对 `InputMethodUnavailable` 重试一次、删死代码、加 GitHub Actions 门禁。

## 2. 本机实测发现（设计的直接依据）

| 编号 | 事实 | 证据 |
|---|---|---|
| F1 | `/proc/bus/input/devices` 用 `std.Io.Dir.readFileAlloc` 读到 **0 字节**；`stat.size = 0`，流式读得到 3935 字节 | 探针：`readStreaming = 3935` / `readFileAlloc = 0` |
| F2 | 因此 `findKeyboardDeviceInProcInput` 恒返回 null，主路径**从未生效**；实际靠 `/dev/input/by-id` 兜底，取第一个 `-event-kbd`，顺序由 readdir 决定 | 探针：`proc-first = none`；`findKeyboardDevice = /dev/input/event5`（raw 目录顺序里 SONiX 在 Compx 前） |
| F3 | 内核暴露 2 个"完整键盘"节点：`event0 Compx 2.4G Receiver`（键鼠一体接收器，`event1` 是其鼠标）、`event5 SONiX USB Keyboard`；另有 `event8 Generic J-166 BT`（已配对未连接） | `/proc/bus/input/devices`；`/dev/input/by-id/` 里两者都有 `-event-kbd` |
| F4 | `KEY_RIGHTALT`(bit 100) 可精确区分真键盘与"假键盘"：18 个 event 节点中只有 event0/event5 合格（电源键×2、Video Bus、HDA PCBeep、Consumer/System Control×4、蓝牙键盘全部出局） | 位图过滤实跑结果 |
| F5 | 能力位图（`B: KEY=` 与 sysfs `capabilities/key` 字符串完全一致）**最高字在前**，用空格分隔；`bit0 = KEY_RESERVED` 通常为 0 可作自检 | event1(鼠标) = `1f0000 0 0 0 0` → 末字为 word0，`1f0000` 是 word4 = BTN_LEFT..BTN_TASK(272..276) ✓ |
| F6 | `kill -9` 之后紧接着启动，合成器偶发返回 `InputMethodUnavailable`（本次 12:47:41 再次复现） | 日志 `[wayland] unavailable: InputMethodUnavailable: another ASR instance may already hold the seat input method`；随后 3 次重启均正常 |
| F7 | sysfs/procfs 属性文件同样 `stat.size = 0`（`capabilities/key` 亦然） | 与 F1 同因；`readAll` 助手必须流式读 |

## 3. 需求

| 编号 | 现状 | 期望 | 验收 |
|---|---|---|---|
| R1 | procfs 文件读成空（F1/F2） | 新增小文件读取助手 `readAll(io, allocator, path, max_bytes)`，流式读到上限；`/proc/bus/input/devices` 与 sysfs 属性都用它 | 单测：对真实 `/proc/bus/input/devices` 读到 >1000 字节；对不存在的路径返回错误；超过上限截断或报错（取一，明确写测试） |
| R2 | 只按 `kbd+leds+sysrq` 与名字猜，误报电源键/媒体键/离线蓝牙键盘 | 用 `KEY_RIGHTALT`(bit 100) 过滤：`supportsRightAltBitmap(text)` 纯函数，解析 `B: KEY=`（MSW 在前，兼容空格/逗号分隔） | 单测：本机 5 组真实位图串（Compx/SONiX=true；Consumer Control/System Control/Power Button/Video Bus/PCBeep/J-166=false）；`bit0=0` 自检 |
| R3 | 只监听 1 个设备，选中哪个由目录顺序决定 | 枚举**全部**合格键盘并同时监听；任一键盘的 RightAlt 按下都能开始录音 | 单测：候选枚举顺序（/proc 中的出现顺序）与去重；真机：两只键盘各按一次都能触发 |
| R4 | 录音期间另一把键盘的事件语义未定义 | "谁按的谁松"：录音由设备 A 开始时，只有 A 的松开结束录音；录音期间其他设备的按下/松开一律忽略并记 debug 日志 | 单测：A press → B release → 仍录音；A release → 结束 |
| R5 | 设备读失败即整进程失败/换单设备 | 单个设备失败**只摘除该设备**（记 err 日志）；集合非空时其余设备继续；集合为空时进入每 2 秒重扫（并重新打开新出现的设备）；`ASR_KEYBOARD_DEVICE` 仍表示"只监听这一个"；新增调试用 `ASR_KEYBOARD_DEVICES=a:b`（冒号分隔的多设备覆盖，仅用于测试/诊断） | 单测：两设备中一个 EOF → 另一个仍可触发；集合空 → 重扫后新设备可用（用注入的候选列表与假设备文件） |
| R6 | 无 | 常驻每 2 秒重扫候选列表（若比批准范围宽，见 §5 决策 D1），发现新设备即补挂，已挂的不重复打开 | 单测：重扫检测到新路径 → 只新增该设备；真机：插上第二只键盘后无需重启即可用 |
| R7 | 键盘设备无逐设备日志 | `kbd` domain：候选列表一行（开始监听时）、每设备生效一行、摘除一行、重扫补挂一行 | 真机日志可见 |
| R8 | `app.zig` 791 行（编排 + 键盘 + 采集回调混在一起） | 拆为 `app.zig`（主循环/编排/提示函数）、`keyboard.zig`（设备集合 + 读事件 + 权限提示 + 重开）、`capture.zig`（采集回调/状态/静音守卫/提示音）；纯搬移，行为与日志不变 | `zig build test` 全绿；真机冒烟与拆分前逐行一致；`app.zig` < 420 行 |
| R9 | `mute.resetMuteState` 死代码（0 调用） | 删除 | `grep -rn resetMuteState src` = 0 |
| R10 | `kill -9` 后立即启动偶发 `InputMethodUnavailable` 直接失败（F6） | 启动阶段对该错误**重试一次**（间隔 300ms），仍失败才退出；其他错误不重试 | 单测：`shouldRetryBind(err)` 纯判定；真机：`kill -9` 后连续 3 次立即重启都成功 |
| R11 | 无 CI，`zig build check` 只在本地跑 | GitHub Actions：push/PR 跑 `zig build check`（Zig 0.16.0） | workflow 文件命令与本地一致；**CI 侧真跑只能等 push 后由 GitHub 验证**（如实记录） |

## 4. 设计

### 4.1 设备发现（`key.zig` + 新助手）

```
readAll(io, allocator, path, max) ── 流式读，procfs/sysfs 安全（R1）
        │
        ├─ /proc/bus/input/devices 内容
        │     └─ findKeyboardDevicesInProcInput(content) -> [][]u8
        │           · 每个块：H: Handlers 含 kbd+leds+sysrq（与现状一致）
        │           · B: KEY= 位图通过 supportsRightAltBitmap（R2）
        │           · 按文件出现顺序返回，去重
        │
        └─ 兜底：/dev/input/by-id 的 *-event-kbd 链接
              └─ 解析出 eventN → 读 /sys/class/input/eventN/device/capabilities/key（readAll）
                    └─ 通过 R2 过滤
```

- `ASR_KEYBOARD_DEVICE` 有值时：只返回该路径（单设备语义不变，README 明确）。
- 顺序：`/proc` 结果（确定性顺序：Compx → SONiX）优先；为空时用兜底结果。

### 4.2 设备集合与等待（新 `KeyboardSet`，落点见 R8）

```zig
pub const Device = struct { path: []u8, file: std.Io.File, state: key.State };
pub const Set = struct {
    devices: []Device,
    active_index: ?usize,      // 录音期间"谁按的"
    logger: output.Logger,
    ...
};
```

- `readNextOrShutdown(key_code)`：`std.Io.Select`，槽位 = `devices.len + 1`（最后一个是"停止/重扫"定时臂）；槽位数组用分配器按运行时长度分配（`Select.init` 接受 slice —— 实现前先核实 0.16 的签名，必要时退化为"每设备一个 arm 的轮询 `poll()` 实现"）。
- 事件语义（R4）：`active_index == null` 时任何设备 press → 返回 press 并记录 `active_index`；`active_index == i` 时仅设备 i 的 release 结束；其他设备事件丢弃并 debug 日志。
- 设备 EOF/错误：摘除该设备（`file.close` + 从数组移除），若 `active_index` 指向它则视为 release（避免"卡在录音中"）。
- 定时臂：每 2 秒（a）集合为空 → 重扫；（b）常驻重扫（决策 D1）→ 比较候选与现有集合，补挂新设备。

**可测试性**：单测里的假设备用 `std.os.linux.pipe2`（Zig 0.16 没有 `std.posix.pipe`）成对创建：写入 24 字节合成 `input_event` 即可让对应读臂就绪，不写则阻塞，关闭写端即 EOF/设备死亡；生产路径用 `openAll(paths)` 按路径打开，测试路径用 `adopt(devices)` 直接接收已打开的文件。

### 4.3 `app.zig` 拆分（R8）

| 新文件 | 内容 | 来源 |
|---|---|---|
| `src/runtime/app.zig` | `run`、`runHotkeyLoop`、`runWaylandLoop`/`WaylandLoop`、`initSessionWithRetry`、`handleFinish`、`engineKind`/`engineLabel`、`waylandFailureHint`/`keyFailureHint` + 其测试 | 现 app.zig 主循环部分 |
| `src/runtime/keyboard.zig` | `KeyboardSet`、`KeyboardEventStream`（或合并）、`openKeyboardFile`、`drainKeyboardEvents`、`classifyKeyboardReadFailure`、键盘权限提示 | 现 app.zig 键盘部分 + `key.zig` 的发现逻辑保持不动 |
| `src/runtime/capture.zig` | `StreamCaptureState`、`EngineCallbacks`、`CaptureStartedState`、`CaptureReleaseState`、`SpeakerMuteGuard`、`onCaptureStarted/Stopped/Recorder/HoldTimeout`、`onEngineInterim/Final/AudioChunk`、`sendEngineAudioChunk`、`playBellTask`、`resolveSession`、`noAudioCaptured`、`formatMicCloseMessage` + 其测试 | 现 app.zig 采集部分 |

约束：只搬移不改逻辑；`pub` 面按需（`app.zig` 需要引用的符号设为 `pub`）；日志文案一字不改（真机冒烟可与拆分前日志对照）。

### 4.4 三项加固

- R9：删 `mute.resetMuteState`。
- R10：新纯函数 `shouldRetryBind(err) bool`（仅 `InputMethodUnavailable` 为真）+ 重试循环（`retries = 1`、`delay_ms = 300`），日志两行（第一次失败/重试）。
- R11：`.github/workflows/ci.yml`（`actions/checkout` + `mlugg/setup-zig` 0.16.0 + `zig build check`）。

## 5. 设计决策（请确认或否决）

- **D1（比批准范围略宽，请确认）**：重扫从"集合空了才扫"改为**常驻每 2 秒重扫**。理由：插拔检测不需要"设备全没了"才生效，成本是每 2 秒一次 3.9KB 的 `/proc` 读 + 一次比较（已打开的设备不重开）；否则"插上新键盘要重启"仍是痛点。若你否决，按原批准范围实现（集合空才扫）。
- **D2（已核实）**：`std.Io.Select.init(io, buffer: []U)` 接受**运行时长度**的 slice（`std/Io.zig:1377`），所以 `N 个设备 + 1 个定时臂` 可直接用堆分配的槽位数组；若实测 `concurrent` 容量不足，再退化为 `std.posix.poll` + 按就绪设备读取（语义与 R3–R6 相同，任务卡里写明分支）。
- **D3**：`ASR_KEYBOARD_DEVICE` 保持"只监听它一个"（不做"额外追加"语义），避免语义歧义。
- **D4**：CI 无法本地真跑（无 runner），只保证命令与本地一致 + YAML 结构审查；首次 push 由 GitHub 验证，若失败再修。
- **D5**：不做（记入非目标）：`TextQueue` 的 `orderedRemove(0)`、键盘 `open` 可取消性、VAD 自动停、IM 断线重连、常驻/toggle 模式。

## 6. 非目标

- 不改变提交后端、录音器、静音策略、凭证、引擎选择。
- 不做按键级别的"设备偏好/学习"（不记忆哪把键盘最近用过）——多设备同时监听已覆盖需求。
- 不做设备级 `grab`（独占），仍允许其他进程读取同一设备。

## 7. 验收

1. `zig build test --summary all` 全绿（新增约 12–16 个测试）；`zig build check` 通过。
2. 真机：两只键盘各按一次都能触发录音并上屏；`event0` 被摘除后 `event5` 仍可用；拔掉一只键盘时进程不退出、日志有摘除行。
3. 真机：`[kbd]` 日志列出候选设备与生效设备；`--debug` 下可见被忽略的其他设备事件。
4. `kill -9` 后立即连续启动 3 次，均绑定成功（R10）。
5. `grep -rn resetMuteState src` = 0；`app.zig` < 420 行。
6. `.github/workflows/ci.yml` 存在且命令为 `zig build check`。
7. 用户侧真声 e2e（G1 遗留）：`./zig-out/bin/asr --debug` 按住 RightAlt 说中文 → `[wayland] ✅`；建议同时用两只键盘各试一次。

## 8. 风险

- **多设备 `Select` 的运行时槽位**（D2）：若 API 不支持，改用 `poll`；两套语义都要有单测护住"谁按的谁松"与"摘除后继续"。
- **拆分引入回归**：纯搬移 + 现有测试 + 真机日志对照；若某文件拆分后反而更乱，允许在任务内调整边界（记 ruling）。
- **常驻重扫（D1）**：每 2 秒一次 `/proc` 读；若实测有 CPU 波动再降频到 5 秒。
- **CI 首次可能失败**（D4）：Zig 0.16.0 的 action 版本/缓存行为未本地验证。
