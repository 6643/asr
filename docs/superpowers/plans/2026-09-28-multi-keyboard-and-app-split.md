# G2 实施计划：多键盘监听 + app.zig 拆分 + 三项加固

> 执行方式：逐任务 TDD（先写失败测试 → 实现 → `zig build check` 全绿 → 真机验证 → 逐任务提交）。
> 每个任务收尾必须同时跑 `zig build test --summary all` 与 `zig build`（后者能抓到测试构建的懒分析漏掉的错误）。

## Goal

修掉"键盘检测靠运气"的根本问题（procfs 读取失效 + 无法区分真假键盘 + 只监听一个设备），把 `app.zig` 拆成三个职责单一的模块，并顺带完成三项加固（启动绑定重试、删死代码、CI 门禁）。

## Architecture

```
main.zig
  └─ app.zig              run / runHotkeyLoop / WaylandLoop / 会话与引擎桥接 / 提示函数
       ├─ keyboard.zig    KeyboardSet（发现→打开→多设备等待→摘除→重扫）+ KeyboardEventStream + 权限提示
       ├─ capture.zig     采集回调与状态（StreamCaptureState / EngineCallbacks / CaptureStartedState /
       │                  CaptureReleaseState / SpeakerMuteGuard / 提示音 / 归集日志）
       ├─ postprocess.zig （不变）
       └─ wayland_im.zig  （+ 启动绑定重试一次）

key.zig                  纯逻辑：事件状态机 + 候选枚举（能力位过滤）+ readAll 流式小文件读取
small_file.zig           readAll(io, allocator, path, max_bytes)：procfs/sysfs 安全的流式读
```

## Tech Stack

Zig 0.16.0（无新增依赖；只允许 `std` 与现有内核接口）。目标环境：NixOS + PipeWire + 合成器 umbriel（Wayland IM）。

## Spec

`docs/superpowers/specs/2026-09-28-multi-keyboard-and-app-split-design.md`（本计划的唯一需求来源；发现 F1–F7 是实现的直接依据）

## Global Constraints

- **禁止用 `std.Io.Dir.readFileAlloc` 读 `/proc`、`/sys`**：这些文件 `stat.size = 0`，会读到 0 字节且**没有任何报错**（F1）；一律走 `small_file.readAll`（流式，带上限）。
- 能力位图解析：`B: KEY=`／`capabilities/key` 的**最高字在前**，空格或逗号分隔；`KEY_RIGHTALT = 100` → `word = 1`、`bit = 36`；`bit0`（KEY_RESERVED）通常为 0，可作自检。
- 键盘来源语义：`ASR_KEYBOARD_DEVICE=<path>` = **只监听它一个**（pin，语义不变）；`ASR_KEYBOARD_DEVICES=a:b:c` = 调试用多设备覆盖；两者都没有 = 自动发现全部合格键盘。
- 不改提交后端、录音器（pw-record）、静音策略、凭证、引擎选择；状态串前缀 `"OK …"`/`"ERR …"` 与日志 domain（`app`/`kbd`/`mic`/`speaker`/`wayland`/`doubao`/`baidu`/`postprocess`）不变。
- 拆分任务（T8–T10）是**纯搬移**：日志文案、`pub` 面、行为一字不变；搬完真机日志与搬前逐行对照。
- 每任务收尾：`zig build test --summary all` 全绿 + `zig build` 成功（T12 之后统一用 `zig build check` 作为收尾命令）。
- 真机验证手法：FIFO + perl 注入（`/tmp/fakekbd`、`/tmp/hold*.pl`）、`ASR_KEYBOARD_DEVICE`/`ASR_KEYBOARD_DEVICES` 指向 FIFO、`pgrep -x asr` 精确清理、日志经 `| cat > file` 落盘（否则子进程持 stdout 会挂住）。
- 绝不 `git add -A`；工作区里 `ai-proxy.log`、`baidu.png`、`config/doubao.json`、`.tmp-*` 是用户自己的改动，不进任何提交。
- 提交信息风格：`fix:`/`feat:`/`refactor:`/`test:`/`build:`/`docs:` + 一行小写英文。

## Review Focus（最容易出错的 5 点）

1. **"谁按的谁松" + 活跃设备被摘除**：录音由 A 开始，若 A 在读失败时被摘除，必须当作 release 结束本次录音（否则永久卡在"录音中"）；B 的按下/松开在录音期间必须被忽略且不改变归属。
2. **定时重扫不得干扰已有设备**：重扫只允许**新增**路径，绝不关闭/重开正在监听的设备（否则会丢掉重开窗口内的事件）；重扫与"按下"同时发生不得丢 press。
3. **procfs/sysfs 必须流式读**：任何一处回退到 `readFileAlloc` 都会静默失效（F1 的教训）；单测必须有一条**对真实 `/proc/bus/input/devices` 断言长度 > 1000**，防止再次静默退化。
4. **位图解析方向**：方向搞反会把所有键盘过滤掉 → 完全无法录音且无报错；单测必须使用本机真实位图串（见 T2 的测试向量），并断言两个真键盘为 true、电源键/媒体键/蓝牙键盘为 false。
5. **拆分与重试的边界**：拆分任务里 `zig build test` 通过不等于 `zig build` 通过（懒分析）；重试只对 `InputMethodUnavailable`、只在启动阶段、只一次，不能掩盖"另一个实例真的在跑"。

## Tasks

### Task 1: 小文件流式读取助手（R1）

- **Files**：新增 `src/runtime/small_file.zig`；`src/root.zig`（导出 + 测试聚合）
- **Interfaces**：
  - `pub const max_bytes_default: usize = 1024 * 1024;`
  - `pub fn readAll(io: std.Io, allocator: std.mem.Allocator, path: []const u8, max_bytes: usize) ![]u8`
  - 语义：循环 `readStreaming` 追加到 `ArrayList(u8)`；读到 0 → 结束；总长超过 `max_bytes` → `error.FileTooBig`（不静默截断）。
- **Steps**：
  1. RED：三个测试 —— ① 读真实 `/proc/bus/input/devices` 断言 `len > 1000`；② 不存在路径 → 期望错误；③ 读真实文件但 `max_bytes = 16` → `expectError(error.FileTooBig, ...)`。
  2. 确认失败原因是 `readAll` 未声明。
  3. GREEN：实现（`std.ArrayList(u8)` + `file.readStreaming(io, &.{buf})`）。
  4. `zig build test --summary all` + `zig build`。
  5. 真机：`zig run` 式探针可省（测试已读真实 /proc）。
- **提交**：`fix: read procfs and sysfs files with a streaming reader`

### Task 2: RightAlt 能力位过滤（R2）

- **Files**：`src/key.zig`
- **Interfaces**：
  - `pub const right_alt_keycode: u16 = 100;`
  - `pub fn supportsRightAltBitmap(bitmap_text: []const u8) bool` —— 按空白/逗号切词 → 反转（最高字在前）→ word1 的 bit36；空串/解析失败 → false。
- **Steps**：
  1. RED：测试用本机真实串（**注意 MSW 在前**）：
     - true：`1000000000007 ff9f207ac14057ff febeffdfffefffff fffffffffffffffe`（event0/event5）
     - false：`733eff 0 0 483ffff17aff32d bfd4444600000000 1 130c730b17c000 267bfad9415fed 9e168000004400 10000002`（Consumer Control）
     - false：`1f0000`（鼠标单字）、`10000 7800000000 e000000000000 0`（J-166 蓝牙）、`""`
     - 自检：真键盘串的**末字最低位为 0**（KEY_RESERVED）
  2. RED 证据 → GREEN 实现（`std.mem.tokenizeAny(u8, text, " \t,")` 收集到栈上 `[8]u64`，反转索引）。
  3. `zig build check`。
- **提交**：`fix: filter keyboard candidates by the right alt capability bit`

### Task 3: `/proc` 多设备枚举 + 能力过滤（R3 的一半）

- **Files**：`src/key.zig`
- **Interfaces**：
  - `pub fn findKeyboardDevicesInProcInput(allocator: std.mem.Allocator, content: []const u8) ![][]u8`（返回按文件顺序、去重后的 `/dev/input/eventN` 列表）
  - 每块条件：`H: Handlers` 含 `kbd`+`leds`+`sysrq`（与现状一致）**且** 该块 `B: KEY=` 通过 `supportsRightAltBitmap`。
  - 保留 `findKeyboardDeviceInProcInput` 作为"取第一个"的薄封装（现有测试与调用点兼容）。
- **Steps**：
  1. RED：① 用本机真实 `/proc` 内容（测试内用 `small_file.readAll` 读，或内联固定串）断言列表 == `{/dev/input/event0, /dev/input/event5}`（顺序）；② 内联含电源键/Consumer/J-166 的假内容 → 只有真键盘入选；③ 重复块去重。
  2. GREEN 实现；内存：`ArrayList([]u8)` + 每项 `allocPrint`；调用方负责释放。
  3. `zig build check`。
- **提交**：`fix: enumerate every keyboard candidate from proc input devices`

### Task 4: 候选发现入口（pin / 调试覆盖 / by-id 兜底）（R3、R5）

- **Files**：`src/key.zig`
- **Interfaces**：
  - `pub fn findKeyboardDevices(allocator, io, environ) ![][]u8`
    - `ASR_KEYBOARD_DEVICE` 有值 → 单元素 `{该路径}`（不检查能力位，pin 语义）
    - `ASR_KEYBOARD_DEVICES` 有值 → 冒号分隔的列表（trim、去空、去重）
    - 否则：`small_file.readAll("/proc/bus/input/devices")` → T3 枚举 → 若为空 → by-id/by-path 兜底（每个 `-event-kbd` 链接解析出的 eventN **再查 sysfs** `capabilities/key` 过滤）
  - `pub fn sysfsCapabilitiesPath(allocator, event_name) ![]u8` → `/sys/class/input/<eventN>/device/capabilities/key`
  - 保留 `findKeyboardDevice`（取第一个）供现有调用点过渡；T7 起 app 改用列表版。
- **Steps**：
  1. RED：① `sysfsCapabilitiesPath` 字符串断言；② 真机：`findKeyboardDevices` 在无 pin 时返回**至少包含** `/dev/input/event5`（用集合断言，不假设顺序）；③ 覆盖语义走纯函数测：`overriddenDevicePaths(allocator, single: ?[]const u8, multi: ?[]const u8) !?[][]u8`（单数 pin → 单元素；冒号分隔多值 → trim/去空/去重；都为空 → null），`findKeyboardDevices` 只负责读环境变量并调用它（避免测试里构造 `std.process.Environ`）。
  2. GREEN 实现（`readAll` + T3 + 兜底 + 过滤 + 覆盖）。
  3. `zig build check`。
- **提交**：`feat: discover all keyboard candidates with pin and debug overrides`

### Task 5: `KeyboardSet`：打开、日志、关闭（R7 的一半）

- **Files**：新增 `src/runtime/keyboard.zig`（本任务只放 Set；T8 把 `KeyboardEventStream` 搬进来）；`src/root.zig`
- **Interfaces**：
  ```zig
  pub const Device = struct { path: []u8, file: std.Io.File, state: key.State };
  pub const Set = struct {
      rescan_interval_ms: i64 = 2_000,
      pub fn openAll(allocator, io, logger, paths: []const []const u8) !Set   // 生产：按路径打开，跳过打不开的并记 err
      pub fn adopt(allocator, io, logger, devices: []Device) Set             // 测试：接管已打开的文件
      pub fn closeAll(self: *Set, io) void
      pub fn len(self: *const Set) usize
      pub fn hasPath(self: *const Set, path: []const u8) bool
      pub fn add(self: *Set, allocator, path: []const u8, file: std.Io.File) !void
  };
  ```
  - 日志：开始监听时每个设备一行 `logger.info("kbd", "{s}", .{path})`；打开失败一行 `logger.err("kbd", "{s}: {s}", .{path, @errorName(err)})`。
- **Steps**：
  1. RED：用 `tmpdir` + `std.os.linux.pipe2` 造 2 个假设备（`Set.adopt`）→ 断言 `len == 2`、`paths` 内容、`closeAll` 后再 `read` 得 `error.NotOpenForReading`/EBADF；`openAll` 对不存在路径**跳过**而不是报错（1 个好的 + 1 个坏的 → 仍有 1 个设备）。
  2. GREEN 实现。
  3. `zig build check`。
- **提交**：`feat: hold every keyboard device in one set`

### Task 6: `KeyboardSet.readNextOrShutdown`（R3、R4、R5、R6 核心）

- **Files**：`src/runtime/keyboard.zig`
- **Interfaces**：
  ```zig
  pub const Outcome = union(enum) { event: key.Event, stop: StopReason };
  pub const StopReason = enum { shutdown, rescan };
  pub const rescan_interval_ms: i64 = 2_000;

  pub fn readNextOrShutdown(
      self: *Set, key_code: u16, is_shutdown: key.ShutdownCheck,
      candidates_fn: ?*const fn (ctx: ?*anyopaque) anyerror![][]u8, ctx: ?*anyopaque,
  ) key.DeviceReadError!Outcome
  ```
  - 槽位：`devices.len + 1` 个（最后一个跑 `pollRescanTask`：每 `rescan_interval_ms` 返回 `.rescan`）；`std.Io.Select.init(io, slice)`（**运行时长度已核实可用**）。
  - 事件处理：`active_index == null` 时任一设备 press → 记 `active_index = i` 并返回 press；`active_index == i` 时仅该设备 release 结束并清空归属；其他设备事件丢弃（debug 日志 `ignored event from {s}`）。
  - 设备错误/EOF：摘除该设备（关闭文件、`orderedRemove`、若 `active_index == i` 则返回 release 语义并清空归属、`active_index > i` 时自减）。
  - `.rescan`：调用 `candidates_fn`；**候选获取自身的错误（OOM/读 /proc 失败）只记 err 日志、不杀死进程**；对不在 `hasPath` 中的新路径 `openFile` 成功才 `add`，日志 `logger.info("kbd", "added {s}", ...)`；候选列表由 Set 释放（每项 + 外层）。
- **Steps**：
  1. RED（5 个测试，全部用 `pipe2` 假设备）：
     ① 无任何事件 + `is_shutdown = true` → `.stop = .shutdown`；
     ② 设备 A 写 press → 返回 press，`active_index == A`；
     ③ 归属 A 后写 B 的 release + B 的 press → 仍返回"未结束"（下一次调用才结束）；再写 A 的 release → 结束；
     ④ 归属 A 后关闭 A 的写端（EOF）→ 该设备被摘除且本次以 release 语义结束，`len` 减 1；
     ⑤ `rescan` 回调返回新路径（tmpdir 里再用 `pipe2` 造一个 `/proc` 不可控的路径 → 用 tmpdir 真实文件 + `Set.adopt` 注入候选）→ 断言集合新增且旧设备仍可用。
  2. GREEN 实现；`rescan_interval_ms` 用参数覆盖（测试注入 20ms，避免 2s 等待）。
  3. `zig build check`。
- **提交**：`feat: listen to every keyboard at once and keep the pressed one`

### Task 7: app 接线 + 真机验证（R3–R7）

- **Files**：`src/runtime/app.zig`
- **Steps**：
  1. `run()`：`const keyboard_paths = try key.findKeyboardDevices(allocator, io, environ)`；失败时沿用 `keyFailureHint` 且区分 `KeyboardPermissionDenied`/`KeyboardDeviceNotFound`；`KeyboardSet.openAll(...)`；`KeyboardEventStream` 仅保留"读事件"职责（或在 T8 一并合并——本任务先最小改动：`runHotkeyLoop` 改用 `Set.readNextOrShutdown`，`candidates_fn` 传 `key.findKeyboardDevices` 的闭包包装）。
  2. 逻辑：press 事件进入原采集流程；release/shutdown/rescan 语义接上现有 `wayland_failed`/`isShutdownRequested` 分支。
  3. 真机验证（FIFO 双设备，全自动）：
     ```bash
     mkfifo /tmp/kbdA /tmp/kbdB
     ASR_KEYBOARD_DEVICES=/tmp/kbdA:/tmp/kbdB ./zig-out/bin/asr --debug
     # A 按→B 松（应仍在录音）→A 松（应结束并提交）；删掉 B 再触发 A；重建 B 等 2s 看是否补挂
     ```
     断言日志：`kbd` 两设备行、`ignored event from`、摘除行、`added` 行。
  4. 真机（真设备，用户在场时补做）：不设 `ASR_KEYBOARD_DEVICE` 运行 → 日志候选含 `event0`、`event5`；按住 SONiX 的 RightAlt 能录音。
  5. `zig build check` + 提交。
- **提交**：`feat: drive the hotkey loop from a multi keyboard set`

### Task 8: 拆分 `keyboard.zig`（R8 第一部分）

- **Files**：`src/runtime/app.zig` → `src/runtime/keyboard.zig`
- **搬移**：`KeyboardEventStream`、`openKeyboardFile`、`drainKeyboardEvents`、`classifyKeyboardReadFailure`、键盘相关提示（若 T7 未合并 Stream，则本任务把 Stream 合并进 `Set` 并删除）
- **Steps**：纯搬移（`pub` 化被 app 引用的符号）；`zig build test` + `zig build`；真机 FIFO 冒烟日志与搬前对照（`diff` 两份日志的关键行）；提交。
- **提交**：`refactor: move keyboard device handling into its own module`

### Task 9: 拆分 `capture.zig`（R8 第二部分）

- **Files**：`src/runtime/app.zig` → `src/runtime/capture.zig`
- **搬移**：`StreamCaptureState`、`EngineCallbacks`、`CaptureStartedState`、`CaptureReleaseState`、`SpeakerMuteGuard`、`onEngineInterim/Final/AudioChunk`、`sendEngineAudioChunk`、`onCaptureStarted/Stopped/Recorder/HoldTimeout`、`playBellTask`、`resolveSession`、`noAudioCaptured`、`formatMicCloseMessage` + 其测试（`noAudioCaptured`/close message 测试随代码走）
- **Steps**：纯搬移；`zig build check`；真机 FIFO 冒烟（含 `on_hold_timeout` 与 `no_audio_captured` 两条分支各跑一次）；提交。
- **提交**：`refactor: move capture callbacks into their own module`

### Task 10: `app.zig` 收尾 + 删死代码（R8、R9）

- **Files**：`src/runtime/app.zig`、`src/runtime/mute.zig`
- **Steps**：① 删除 `mute.resetMuteState`（0 调用）；② `app.zig` 只留 `run`/`runHotkeyLoop`/`WaylandLoop`/`initSessionWithRetry`/`handleFinish`/`engineKind`/`engineLabel`/两个 hint + 其测试；③ `wc -l src/runtime/app.zig` < 420；④ `zig build check`。
- **提交**：`refactor: trim the app module and drop dead mute code`

### Task 11: 启动绑定重试一次（R10）

- **Files**：`src/runtime/wayland_im.zig`、`src/runtime/app.zig`
- **Interfaces**：
  - `pub fn shouldRetryBind(err: anyerror) bool`（仅 `error.InputMethodUnavailable` 为 true）
  - `pub const bind_retry_delay_ms: i64 = 300;`
  - app：`connectWithRetry(io, allocator, err_ctx)`：首次失败且 `shouldRetryBind` → `logger.info("wayland", "retrying bind after {s}", ...)` → 等 300ms → 再试一次；第二次失败按原样报错退出。
- **Steps**：① RED：`shouldRetryBind` 三断言（`InputMethodUnavailable` true；`ConnectionFailed`、`MissingRuntimeDir` false）；② GREEN；③ 真机：`kill -9` 后立即连续启动 3 次，均绑定成功（对照 F6）；④ 两个实例同时跑 → 仍是清晰报错（重试只让错误晚 300ms）。
- **提交**：`fix: retry the input method bind once at startup`

### Task 12: GitHub Actions 门禁（R11）

- **Files**：新增 `.github/workflows/ci.yml`
- **内容**：`on: [push, pull_request]`；`actions/checkout@v4`；`mlugg/setup-zig@v2`（`version: 0.16.0`）；`zig build check`（可选缓存 `~/.cache/zig`）。
- **Steps**：① 写文件；② 本地校验：`zig build check` 与 workflow 里的命令逐字一致（`grep`）；YAML 结构人工审查（无本地 runner，如实记录 D4）；③ 提交。
- **提交**：`build: run the check step on github actions`

### Task 13: README + 收尾验收 + 统一同步（R3–R11 收口）

- **Files**：`README.md`
- **Steps**：
  1. README 补：多键盘监听与"谁按的谁松"、候选过滤（RightAlt 能力位）、`ASR_KEYBOARD_DEVICE`（pin）与 `ASR_KEYBOARD_DEVICES`（调试）、重扫行为（2s，插上即用）、`--debug` 下 `kbd` 日志含义、CI 说明。
  2. 全量验收：`zig build check`；FIFO 双设备脚本一轮（T7 的脚本）；真声 e2e（用户）；
  3. **G2 完成后的统一同步**（用户指示）：`git push origin main`；删除已合并的本地分支 `wayland-input-method`；处理 `origin/master`（与 main 合并/删除，二选一，届时问用户）；父仓库 `/._` 的 submodule 指针更新再推（一并问用户）。
- **提交**：`docs: describe multi keyboard handling and the check gate`

## Self-Review（需求 → 任务）

| 需求 | 任务 |
|---|---|
| R1 流式读 procfs/sysfs | T1 |
| R2 RightAlt 能力位过滤 | T2 |
| R3 枚举全部合格键盘 | T3、T4、T6、T7 |
| R4 谁按的谁松 / 其他设备忽略 | T6 |
| R5 单设备摘除 / pin / 调试覆盖 / 重扫 | T4、T5、T6、T7 |
| R6 常驻 2s 重扫（D1） | T6、T7 |
| R7 逐设备日志 | T5、T7 |
| R8 app.zig 拆分 | T8、T9、T10 |
| R9 删死代码 | T10 |
| R10 启动绑定重试一次 | T11 |
| R11 CI | T12 |
| README / 统一同步 | T13 |

未覆盖（有意）：D5 的非目标项、`TextQueue` 优化、`open` 可取消性、VAD、IM 重连。

## 执行注意（harness）

- 每个任务开始：`task-start docs/superpowers/plans/2026-09-28-multi-keyboard-and-app-split.md <N>`；收尾：`task-done … <N> <BASE> -- zig build check --summary all`（**注意**：命令必须产生输出，否则 `task-done` 的 `grep` 会因空日志失败——所以统一带 `--summary all`）。
- 清理真机残留：`for p in $(pgrep -x asr); do kill -9 $p; done`、`rm -f /tmp/fakekbd /tmp/kbdA /tmp/kbdB`。
- 每任务的遗产（rulings/证据/发现）追加到 `.superpowers/sdd/2026-09-28-multi-keyboard-and-app-split/progress.md`。
