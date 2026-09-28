# 单后端化与健壮性加固实现计划

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** 删除上一平台（IBus + arecord）的全部代码路径，把 ASR 收敛为"Wayland 输入法提交 + PipeWire 采集"的单后端工具，并落实代码审查中确认的健壮性改进项。

**Architecture:** 提交后端只有 `wayland_im.Client`（删 `CommitBackend` 联合体与 `--ibus`/`--wayland` 开关）；录音只有 `pw-record`（删 arecord 回退链）；Wayland 客户端的读/写路径改为可注入 IO，便于给 EOF、poll 失败、畸形消息、EAGAIN 写满这些真实故障写单测；静音增加"崩溃后恢复"，键盘与录音失败给出可读错误。

**Tech Stack:** Zig 0.16、`std.Io`、`std.posix`。不新增任何第三方依赖。

**Spec:** `docs/superpowers/specs/2026-09-28-cleanup-and-hardening-design.md`

## Global Constraints

- 只支持当前环境：Wayland 合成器（`zwp_input_method_manager_v2`）+ PipeWire（`pw-record`、`wpctl`、`pw-play`）；不新增依赖，只用 `std.posix` 与现有 `std.Io`。
- 提交后端唯一；提交失败**只记日志**（用户决定，不做剪贴板/通知兜底）。
- 凭证继续读写 `config/doubao.json`（用户决定，不迁 XDG state）。
- 录音期间静音**保留**；只新增"崩溃/被强杀后恢复静音"。
- 保留 `doubao`/`baidu` 两个识别引擎与 `--once-pcm`。
- 状态字符串沿用 `"OK …"` / `"ERR …"` 前缀；日志 domain 保持 `app`/`kbd`/`mic`/`speaker`/`wayland`/`doubao`/`baidu`/`postprocess`。
- 每任务收尾：`zig build test --summary all` 全绿且 `zig build` 成功；提交信息用 `refactor:`/`fix:`/`feat:`/`docs:`/`build:` 前缀。
- 删除验收：`grep -ri "ibus" src build.zig` 与 `grep -ri arecord src` 无命中。
- 真机验证步骤照 spec 的“验收”清单执行（绑定成功、按住说话上屏、错误场景非零退出、静音恢复）。

## Review Focus

1. 合成器在 commit 之后立刻 deactivate：本次提交的 `commit_string` + `commit` 必须已在同一次 write 内发出（既有行为），且 IM 死亡时不得再出现"日志 ✅ 但没上屏" —— 由 Task 4 的 fake-IO 测试与真机验证钉住。
2. 极短按住（<100ms）录音器 0 字节：期望一行 `ERR no_audio_captured …`，而不是静默走完（Task 8）。
3. `--max-hold-ms` 到点与用户同时松手：只能提交一次、`up RightAlt` 只出现一次（Task 12）。
4. 静音 marker 写失败（`$XDG_RUNTIME_DIR` 不可写）：静音与恢复都必须照常工作，只是失去崩溃恢复能力（Task 6）。
5. `--log-file` 指向不可写路径：启动时一行清晰错误 + 非零退出，而不是静默丢日志（Task 13）。

---

### Task 1: 录音器只留 pw-record

**Files:**
- Modify: `src/runtime/recorder.zig`（整个文件重写为单录音器）
- Modify: `src/runtime/mic.zig:63-95`（`spawnRecorder`、`CaptureOptions`）
- Test: 同文件内 `test` 块（项目惯例）

**Interfaces:**
- Consumes: 无（本次第一个任务）
- Produces: `recorder.program() []const u8`、`recorder.Params{ rate: []const u8, channels: []const u8 }`、`recorder.buildArgv(params: Params) Args`、`recorder.spawn(io: std.Io, params: Params) !std.process.Child`
- Removes: `Kind`、`candidates`、`SpawnFn`、`Spawned`、`spawnFirst`、`spawnFirstWith`、`Params.device`、`mic.CaptureOptions.device`

- [ ] **Step 1: 改写测试（RED）**

`recorder.zig` 中删除所有 `arecord`/fallback 测试，替换为：

```zig
test "pw-record argv captures raw s16 at the requested rate and channels" {
    const argv = buildArgv(.{ .rate = "16000", .channels = "1" });
    try std.testing.expectEqualSlices([]const u8, &.{
        "pw-record", "--rate", "16000", "--channels", "1", "--format", "s16", "-",
    }, argv.slice());
}

test "program is pw-record" {
    try std.testing.expectEqualStrings("pw-record", program());
}
```

`mic.zig` 的 `test "stream options default to no started callback"` 保持；若引用 `CaptureOptions.device` 则删除该字段引用。

- [ ] **Step 2: 运行测试确认失败**

Run: `zig build test 2>&1 | head -20`
Expected: 编译失败（`buildArgv` 需要参数、`Kind` 等符号不存在）或测试失败 —— 记录实际错误行。

- [ ] **Step 3: 实现 `recorder.zig`**

保留 `max_args = 12`、`Args`（原 `Argv`）的 `items`/`count`/`slice()`/`push()`；`push` 越界继续用 `std.debug.assert(self.count < max_args)`。`buildArgv` 依次 push：`program()`、`"--rate"`、`params.rate`、`"--channels"`、`params.channels`、`"--format"`、`"s16"`、`"-"`。`spawn` 用 `std.process.spawn(io, .{ .argv = argv.slice(), .stdin = .ignore, .stdout = .pipe, .stderr = .ignore })`（与原 `spawn` 相同的 stdio 配置）。

- [ ] **Step 4: 实现 `mic.zig` 改动**

`spawnRecorder` 改为 `pub fn spawnRecorder(io: std.Io, options: CaptureOptions) !std.process.Child`，内部 `recorders.spawn(io, .{ .rate = frame_rate, .channels = channels })`；`captureStreamUntilKeyRelease` 里 `const child = try spawnRecorder(...)`，`on_recorder` 回调传 `recorders.program()`；删 `CaptureOptions.device`。

- [ ] **Step 5: 运行测试确认通过**

Run: `zig build test --summary all`
Expected: PASS（总数 = 123 − 删除的 arecord/fallback 测试 + 2 新测试）。

- [ ] **Step 6: Commit**

```bash
git add src/runtime/recorder.zig src/runtime/mic.zig
git commit -m "refactor: keep only pw-record as the capture backend"
```

---

### Task 2: 单后端化，删除 IBus 与多后端开关

**Files:**
- Delete: `src/runtime/ibus.zig`、`src/runtime/gio_ibus.zig`、`src/runtime/gio_dbus.zig`、`src/install.zig`
- Modify: `src/cli.zig`、`src/runtime/postprocess.zig`、`src/runtime/app.zig`、`src/main.zig`、`src/root.zig`、`build.zig`
- Test: `src/cli.zig`、`src/runtime/postprocess.zig`、`src/runtime/app.zig` 内测试

**Interfaces:**
- Consumes: Task 1 的 `recorder.spawn`
- Produces:
  - `cli.ModeTag = enum { app, once_pcm, help }`；`cli.Options{ mode, engine: Engine = .doubao, debug: bool = false, rectify: bool = true, max_hold_ms: i64 = 120_000, log_file: ?[]const u8 = null }`
  - `cli.optionsFromArgs(args) !Options`（错误：`error.UnknownArgument`、`error.MissingArgumentValue`、`error.InvalidArgumentValue`）
  - `cli.usage_text: []const u8`
  - `postprocess.Pipeline.start(allocator, io, logger, client: *wayland_im.Client, cfg: *const config.Config, provider: []const u8, rectify_enabled: bool) !*Pipeline`
  - `app.run(allocator, io, environ, opts: cli.Options) !void`（Task 13 再加 `log_file: ?*output.LogFile` 参数）
  - `app.waylandFailureHint(err: anyerror) []const u8`、`app.keyFailureHint(err: anyerror) []const u8`

- [ ] **Step 1: 改写 `cli.zig` 测试（RED）**

删除 `--ibus`/`--ibus-xml`/`--wayland`/`--no-wayland` 相关测试，新增：

```zig
test "rejects unknown arguments" {
    const args = [_][:0]const u8{ "asr", "--nope" };
    try std.testing.expectError(error.UnknownArgument, optionsFromArgs(&args));
}

test "rejects once-pcm without a value" {
    const args = [_][:0]const u8{ "asr", "--once-pcm" };
    try std.testing.expectError(error.MissingArgumentValue, optionsFromArgs(&args));
}

test "parses hardening flags" {
    const args = [_][:0]const u8{ "asr", "--no-rectify", "--max-hold-ms", "3000", "--log-file", "/tmp/a.log" };
    const opts = try optionsFromArgs(&args);
    try std.testing.expect(!opts.rectify);
    try std.testing.expectEqual(@as(i64, 3000), opts.max_hold_ms);
    try std.testing.expectEqualStrings("/tmp/a.log", opts.log_file.?);
}

test "help mode prints usage" {
    const args = [_][:0]const u8{ "asr", "--help" };
    try std.testing.expectEqual(ModeTag.help, std.meta.activeTag((try optionsFromArgs(&args)).mode));
}
```

- [ ] **Step 2: 运行确认失败**

Run: `zig build test 2>&1 | head -20`
Expected: 编译失败（`ModeTag.help`/`rectify` 等不存在）。

- [ ] **Step 3: 实现 `cli.zig`**

- `ModeTag = enum { app, once_pcm, help }`；`Mode = union(ModeTag){ app: void, once_pcm: []const u8, help: void }`。
- `optionsFromArgs(args) !Options`：遍历 `args[1..]`；已知 flag 收集，`--engine` 由 `--baidu` 决定（默认 `.doubao`，删除 `Options.engine` 里 `.baidu` 的误导默认值）；`--once-pcm`/`--max-hold-ms`/`--log-file` 取值缺一即 `error.MissingArgumentValue`；`--max-hold-ms` 用 `std.fmt.parseInt(i64, value, 10)`，失败 `error.InvalidArgumentValue`；`--help` 置 `mode = .help`；其余以 `-` 开头的参数 → `error.UnknownArgument`（非 `-` 开头的位置参数忽略，保持 `asr <argv0>` 兼容）。
- `usage_text`：列出所有 flag 与默认值（引擎默认 doubao、`--max-hold-ms` 默认 120000=0 不限、`--log-file` 追加写、`--debug`）。

- [ ] **Step 4: 改 `postprocess.zig`（先删联合体测试）**

删 `CommitBackend` 与 `test "commit backend reports provider domain"`；`Pipeline.backend: CommitBackend` → `client: *wayland_im.Client`；`start(...)` 署名见 Interfaces；`commitWorker` 改：

```zig
const status = ctx.client.commit(text);
if (std.mem.startsWith(u8, status, "OK ")) ctx.logger.info("wayland", "✅", .{}) else ctx.logger.err("wayland", "❌ {s}", .{status});
```

`rectifyWorker` 增 `if (shouldRectify(ctx.rectify_enabled, ctx.cfg.sami_token, ctx.cfg.device_id))` 判定，否则跳过纠错直接入提交队列（Task 11 补 `shouldRectify` 与其测试；本任务先加字段 `rectify_enabled: bool` 并在 `start` 里赋值）。

- [ ] **Step 5: 改 `app.zig`（删 IBus 编排，加失败提示）**

- 删除 `ibus`/`wayland_im` 之外的 import 里不再使用的项；移除 `service`、`service_loop`、`ServiceLoop`、`runServiceLoop`、`startIbusBackend`、`switchToAsrInputMethod` 调用、`waitForServiceReady`、`wayland: cli.WaylandMode` 分支与 `WaylandMode` 参数。
- 改为：

```zig
const client = wayland_im.connect(allocator, io, environ) catch |err| {
    logger.err("wayland", "unavailable: {s}: {s}", .{ @errorName(err), waylandFailureHint(err) });
    return err;
};
logger.info("wayland", "input method bound", .{});
```

- `waylandFailureHint`：`InputMethodUnavailable` → `"另一个 ASR 实例可能正在运行（一个 seat 只能有一个输入法）"`；`MissingRuntimeDir`/`ConnectionFailed` → `"检查 WAYLAND_DISPLAY 与 Wayland 会话"`；`DisplayError` → `"合成器拒绝了该连接"`；其他 → `""`。加 4 条单测。
- `keyFailureHint`（Task 7 会用到）：`KeyboardPermissionDenied` → `"无权读取输入设备：把用户加入 input 组后重新登录"`；`KeyboardDeviceNotFound` → `"未找到键盘设备：可用 ASR_KEYBOARD_DEVICE 指定"`；其他 → `""`。加 2 条单测。
- `WaylandLoop` 增 `failed: std.atomic.Value(bool) = .init(false)`；`runWaylandLoop` 里 pump 失败 → `loop.logger.err("wayland", "disconnected: {s}", .{@errorName(err)}); loop.failed.store(true, .release); return;`。
- `runHotkeyLoop` 增参数 `wayland_failed: *const std.atomic.Value(bool)`；等按键与每轮循环用统一的停止谓词：

```zig
const should_stop = struct {
    fn check() bool { return isShutdownRequested() or wayland_failed.load(.acquire); }
}.check;
```

把 `readNextOrShutdown`/`waitNextDeviceEventOrShutdown` 传的 `isShutdownRequested` 换成 `should_stop`；循环顶部 `if (isShutdownRequested()) {...}` 之后加：

```zig
if (wayland_failed.load(.acquire)) {
    logger.err("wayland", "input method connection lost; exiting", .{});
    return error.WaylandDisconnected;
}
```

- 顺带把凭证刷新去重：在 `config.zig` 加 `pub fn refreshDoubaoCredentials(allocator, io, path, debug) bool`（内部调用 `credentials.refreshFile` + `refreshSucceeded`），`app.zig` 与 `main.zig` 的 `--once-pcm` 分支都改用它，只保留各自的日志与 reload。

- [ ] **Step 6: 改 `main.zig`**

- 删 `.ibus_xml`/`.ibus_service` 分支。
- `optionsFromArgs` 用 catch：打印 `asr: <@errorName>` + `usage_text` 到 stderr，`std.process.exit(2)`；`.help` → 打印 `usage_text` 并 `exit(0)`。
- `.app` → `app.run(allocator, init.io, init.minimal.environ, opts)`。

- [ ] **Step 7: 删文件与引用**

```bash
git rm src/runtime/ibus.zig src/runtime/gio_ibus.zig src/runtime/gio_dbus.zig src/install.zig
```

`root.zig`：删 `runtime.gio_dbus`/`runtime.gio_ibus`/`runtime.ibus` 三行 export 与 `test` 块里的对应引用。`build.zig`：删 `install_exe`（`asr-install`）、`b.installArtifact(install_exe)`、`install-ibus` 步骤与 `install_run_cmd`。

- [ ] **Step 8: 验证**

Run: `zig build test --summary all && zig build && grep -ri "ibus" src build.zig | wc -l`
Expected: 测试全绿；构建成功；`grep` 输出 `0`。

- [ ] **Step 9: Commit**

```bash
git add -A
git commit -m "refactor: serve only the wayland input method and drop the ibus backend"
```

---

### Task 3: README 与文档清理

**Files:**
- Modify: `README.md`
- Test: 无（验收为 grep + 真机 --help 对照）

**Interfaces:**
- Consumes: Task 2 的 `cli.usage_text`
- Produces: 无（文档）

- [ ] **Step 1: 重写 README 的依赖与用法**

依赖段改成：Wayland 合成器需支持 `zwp_input_method_manager_v2`（本机 umbriel 已支持）；PipeWire（`pw-record` 采集、`wpctl` 录音静音、`pw-play` 提示音）；`curl`；键盘读取需要 `input` 组（附 `extraGroups` 示例）。删掉 IBus/`asr-install`/`install-ibus`/arecord 的全部段落。用法段与 `cli.usage_text` 保持一致，并写明：没有回退后端（IM 不可用即报错退出）、提交失败只记日志、`--max-hold-ms`/`--no-rectify`/`--log-file` 语义。

- [ ] **Step 2: 验证**

Run: `grep -rni "ibus\|arecord\|install-ibus" README.md | wc -l; ./zig-out/bin/asr --help`
Expected: `0`；`--help` 输出与 README 用法段落一致。

- [ ] **Step 3: Commit**

```bash
git add README.md
git commit -m "docs: describe the single wayland plus pipewire setup"
```

---

### Task 4: IM 读路径加固（R1 + R2）

**Files:**
- Modify: `src/runtime/wayland_im.zig`（`classifyMessage`、`drainMessages`、`pumpWith`、`pump`）
- Test: 同文件内 `test` 块

**Interfaces:**
- Consumes: Task 2 的 `app.runWaylandLoop` 失败传播
- Produces:
  - `pub const MessageSlice = union(enum) { message: Message, incomplete, malformed };`
  - `pub fn classifyMessage(buf: *const std.ArrayList(u8)) MessageSlice`（替换现有 `extractMessage`）
  - `pub const max_read_buffer_bytes: usize = 1024 * 1024;`
  - `pub fn drainMessages(client: *Client) ConnectError!void`
  - `pub const ReadIo = struct { ctx: ?*anyopaque, readFn: *const fn (ctx: ?*anyopaque, buf: []u8) ReadError!usize, pollFn: *const fn (ctx: ?*anyopaque, timeout_ms: i32) ReadError!bool };`
  - `pub fn pumpWith(client: *Client, io: ReadIo, timeout_ms: i32) ConnectError!void`；`pump(timeout_ms)` 用真实 socket 组装 `ReadIo` 调 `pumpWith`
  - `ConnectError` 增 `MalformedMessage`

- [ ] **Step 1: 写失败测试（RED）**

```zig
test "malformed header marks client dead" {
    var client = try testClient(std.testing.allocator);
    defer client.deinit();
    var bad: [8]u8 = @splat(0);
    std.mem.writeInt(u32, bad[4..8], (3 << 16) | 0, .little); // size = 3
    try client.read_buf.appendSlice(std.testing.allocator, &bad);
    try std.testing.expectError(error.MalformedMessage, drainMessages(&client));
    try std.testing.expect(client.dead);
}

test "read buffer over the cap marks client dead" {
    var client = try testClient(std.testing.allocator);
    defer client.deinit();
    try client.read_buf.appendNTimes(std.testing.allocator, 0, max_read_buffer_bytes);
    try std.testing.expectError(error.ConnectionFailed, drainMessages(&client));
    try std.testing.expect(client.dead);
}

test "incomplete header keeps the client alive" {
    var client = try testClient(std.testing.allocator);
    defer client.deinit();
    try client.read_buf.appendSlice(std.testing.allocator, "abc");
    try drainMessages(&client);
    try std.testing.expect(!client.dead);
    try std.testing.expectEqual(@as(usize, 3), client.read_buf.items.len);
}

test "pump marks client dead when poll fails" {
    var client = try testClient(std.testing.allocator);
    defer client.deinit();
    const Fake = struct {
        fn read(ctx: ?*anyopaque, buf: []u8) ReadError!usize { _ = ctx; _ = buf; return 0; }
        fn poll(ctx: ?*anyopaque, timeout_ms: i32) ReadError!bool { _ = ctx; _ = timeout_ms; return error.ConnRefused; }
    };
    try std.testing.expectError(error.ConnectionFailed, pumpWith(&client, .{ .ctx = null, .readFn = Fake.read, .pollFn = Fake.poll }, 0));
    try std.testing.expect(client.dead);
}

test "pump marks client dead on eof" {
    // 同上，pollFn 返回 true，readFn 返回 0 → error.ConnectionFailed 且 dead
}
```

`testClient` 辅助：`client.* = .{ .allocator = allocator, .io = std.testing.io, .stream = undefined };` —— 若 `std.Io.net.Stream` 的 `undefined` 初始化在 Zig 0.16 下报错，改为 `std.mem.zeroes(std.Io.net.Stream)` 并在 ledger 记 ruling。

- [ ] **Step 2: 运行确认失败**

Run: `zig build test 2>&1 | head -20`
Expected: 编译失败（`classifyMessage`/`drainMessages`/`max_read_buffer_bytes`/`pumpWith` 不存在）。

- [ ] **Step 3: 实现 `classifyMessage` 与 `drainMessages`**

`classifyMessage`：`len < 8` → `.incomplete`；`size < 8 or size % 4 != 0` → `.malformed`；`len < size` → `.incomplete`；否则 `.message`。
`drainMessages`：

```zig
while (true) {
    if (client.read_buf.items.len > max_read_buffer_bytes) { client.dead = true; return error.ConnectionFailed; }
    switch (classifyMessage(&client.read_buf)) {
        .incomplete => return,
        .malformed => { client.dead = true; return error.MalformedMessage; },
        .message => |m| { try client.applyMessage(m.object_id, m.opcode, m.payload); consumeMessage(&client.read_buf, m.total_size); },
    }
}
```

- [ ] **Step 4: 实现 `pumpWith` 与真实 `pump`**

`pumpWith`：`pollFn` 返回 false（超时）→ return；错误 → `client.dead = true; return error.ConnectionFailed;`。循环 `readFn`：`n == 0` → `dead = true; return error.ConnectionFailed;`；`n > 0` → append 到 `read_buf`（OOM → `dead = true`）；错误 `WouldBlock`/`Timeout` → break；其他 → `dead = true; return error.ConnectionFailed;`。最后 `try drainMessages(client)`。
`pump(timeout_ms)`：组装 `ReadIo`，`readFn` 用 `std.posix.system.read` + `std.posix.errno`（`.AGAIN` → `error.WouldBlock`，`.INTR` → 重试，其他 → `error.ReadFailed`），`pollFn` 用 `std.posix.poll(&fds, timeout_ms)`（返回值 < 0 → `error.ReadFailed`）。

- [ ] **Step 5: 运行测试确认通过**

Run: `zig build test --summary all`
Expected: PASS（新增 5 条）。

- [ ] **Step 6: Commit**

```bash
git add src/runtime/wayland_im.zig
git commit -m "fix: mark the wayland client dead on eof, poll failure, or malformed message"
```

---

### Task 5: IM 写路径 EAGAIN 重试（R3）

**Files:**
- Modify: `src/runtime/wayland_im.zig`（`writeAllWith`、`writeAll`、`commit`、`deinit` 调用点不变）
- Test: 同文件内 `test` 块

**Interfaces:**
- Consumes: Task 4 的 `ConnectError`
- Produces:
  - `pub const write_timeout_ms: i64 = 500;`
  - `pub const WriteError = error{ WouldBlock, WriteFailed };`
  - `pub const WriteIo = struct { ctx: ?*anyopaque, writeFn: *const fn (ctx: ?*anyopaque, bytes: []const u8) WriteError!usize, waitFn: *const fn (ctx: ?*anyopaque) WriteError!void, elapsedFn: *const fn (ctx: ?*anyopaque) i64 };`
  - `pub fn writeAllWith(io: WriteIo, bytes: []const u8, timeout_ms: i64) ConnectError!void`

- [ ] **Step 1: 写失败测试（RED）**

```zig
test "write retries after would block then succeeds" {
    try writeAllWith(.{ .ctx = null, .writeFn = FakeWouldBlockThenWrite.write, .waitFn = FakeWouldBlockThenWrite.wait, .elapsedFn = FakeWouldBlockThenWrite.elapsed }, "abcdefgh", write_timeout_ms);
    try std.testing.expectEqual(@as(usize, 2), FakeWouldBlockThenWrite.calls);
}

test "write fails when the deadline passes" {
    FakeAlwaysWouldBlock.elapsed_ms = 0;
    try std.testing.expectError(error.ConnectionFailed, writeAllWith(.{ .ctx = null, .writeFn = FakeAlwaysWouldBlock.write, .waitFn = FakeAlwaysWouldBlock.wait, .elapsedFn = FakeAlwaysWouldBlock.elapsed }, "abc", 100));
    FakeAlwaysWouldBlock.elapsed_ms = 100;
    try std.testing.expectError(error.ConnectionFailed, writeAllWith(.{ .ctx = null, .writeFn = FakeAlwaysWouldBlock.write, .waitFn = FakeAlwaysWouldBlock.wait, .elapsedFn = FakeAlwaysWouldBlock.elapsed }, "abc", 100));
}
```

两个 fake 定义在测试区（文件级），例如：

```zig
const FakeWouldBlockThenWrite = struct {
    var calls: usize = 0;
    fn write(ctx: ?*anyopaque, bytes: []const u8) WriteError!usize {
        _ = ctx;
        calls += 1;
        if (calls == 1) return error.WouldBlock;
        return bytes.len;
    }
    fn wait(ctx: ?*anyopaque) WriteError!void { _ = ctx; }
    fn elapsed(ctx: ?*anyopaque) i64 { _ = ctx; return 0; }
};

const FakeAlwaysWouldBlock = struct {
    var elapsed_ms: i64 = 0;
    fn write(ctx: ?*anyopaque, bytes: []const u8) WriteError!usize { _ = ctx; _ = bytes; return error.WouldBlock; }
    fn wait(ctx: ?*anyopaque) WriteError!void { _ = ctx; }
    fn elapsed(ctx: ?*anyopaque) i64 { _ = ctx; return elapsed_ms; }
};
```

（每个测试开头把计数器归零：`FakeWouldBlockThenWrite.calls = 0;`）

- [ ] **Step 2: 运行确认失败**

Run: `zig build test 2>&1 | head -20`
Expected: 编译失败（`writeAllWith`/`WriteIo` 不存在）。

- [ ] **Step 3: 实现 `writeAllWith` 与真实 `writeAll`**

```zig
pub fn writeAllWith(io: WriteIo, bytes: []const u8, timeout_ms: i64) ConnectError!void {
    var written: usize = 0;
    while (written < bytes.len) {
        if (io.elapsedFn(io.ctx) >= timeout_ms) return error.ConnectionFailed;
        const n = io.writeFn(io.ctx, bytes[written..]) catch |err| switch (err) {
            error.WouldBlock => { io.waitFn(io.ctx) catch return error.ConnectionFailed; continue; },
            else => return error.ConnectionFailed,
        };
        if (n == 0) return error.ConnectionFailed;
        written += n;
    }
}
```

真实 `writeAll(client, bytes)`：`elapsedFn` 用 `std.Io.Clock.real.now(client.io).toMilliseconds()` 与起始值之差；`writeFn` 用 `std.posix.system.write` + `std.posix.errno`（`.AGAIN` → `error.WouldBlock`；`.INTR` → 内部 continue 重试；其他 → `error.WriteFailed`）；`waitFn` 用 `std.posix.poll(POLLOUT, 剩余毫秒)`。

- [ ] **Step 4: 运行测试确认通过**

Run: `zig build test --summary all`
Expected: PASS（新增 2 条）。

- [ ] **Step 5: Commit**

```bash
git add src/runtime/wayland_im.zig
git commit -m "fix: retry wayland writes on eagain until a deadline"
```

---

### Task 6: 静音崩溃恢复、SIGHUP 与探测加宽（R4 + R8）

**Files:**
- Modify: `src/runtime/mute.zig`、`src/runtime/shutdown.zig`、`src/runtime/app.zig`
- Test: `src/runtime/mute.zig`、`src/runtime/app.zig` 内测试

**Interfaces:**
- Consumes: Task 2 的 `app.run` 启动顺序
- Produces:
  - `pub const marker_name = "asr-speaker-muted";`
  - `pub fn markerPathWith(allocator, runtime_dir: ?[]const u8) ?[]u8`
  - `pub fn markerExists(io, path: []const u8) bool`、`pub fn writeMarker(io, path: []const u8) void`、`pub fn clearMarker(io, path: []const u8) void`
  - `pub fn recoverStaleMute(allocator, io, environ: std.process.Environ) bool`（返回是否恢复过）
  - `pub fn isMutedOutput(output: []const u8) bool`（改为大小写不敏感）

- [ ] **Step 1: 写失败测试（RED）**

```zig
test "builds the marker path from XDG_RUNTIME_DIR" {
    const path = markerPathWith(std.testing.allocator, "/run/user/1000").?;
    defer std.testing.allocator.free(path);
    try std.testing.expectEqualStrings("/run/user/1000/asr-speaker-muted", path);
    try std.testing.expect(markerPathWith(std.testing.allocator, null) == null);
}

test "detects muted output regardless of case" {
    try std.testing.expect(isMutedOutput("Volume: 0.45 [muted]\n"));
    try std.testing.expect(isMutedOutput("Volume: 0.45 [MUTED]\n"));
    try std.testing.expect(!isMutedOutput("Volume: 0.45\n"));
}

test "marker round trip" {
    // tmpDir + markerExists/writeMarker/clearMarker：写完存在、清完不存在
}
```

- [ ] **Step 2: 运行确认失败**

Run: `zig build test 2>&1 | head -20`
Expected: 编译失败（新符号不存在）。

- [ ] **Step 3: 实现 marker 与探测**

`markerPathWith`：`runtime_dir` 为空或无 `$XDG_RUNTIME_DIR` → null；否则 `std.fmt.allocPrint("{s}/{s}", .{dir, marker_name})`。`markerExists`：`std.Io.Dir.cwd().openFile(io, path, .{}) catch return false` 后 close 返回 true。`writeMarker`：`createFile(io, path, .{ .truncate = true })` + close，失败忽略（`catch {}`）。`clearMarker`：`deleteFile(io, path) catch {}`。`isMutedOutput`：改为 `std.ascii.findIgnoreCase(output, "MUTED") != null`（`std.ascii` 无 `indexOfIgnoreCase`，只有 `findIgnoreCase`）。

- [ ] **Step 4: 接入 `muteSpeaker`/`unmuteSpeaker`/`recoverStaleMute`**

`MuteState` 增 `marker_path: ?[]u8 = null` 与 `setMarkerPath(io, environ)`（由 app 启动时调用一次，`std.process.Environ.getPosix(environ, "XDG_RUNTIME_DIR")` → `markerPathWith`）。`muteSpeaker`：`runMute(true)` 成功 → `writeMarker`。`unmuteSpeaker`：`runMute(false)` 成功 → `clearMarker`。`recoverStaleMute(allocator, io, environ) bool`：取 marker 路径，不存在 → false；存在 → `runMute(false)`（直接调用，绕过 `muted_by_us`）→ `clearMarker` → true。

- [ ] **Step 5: 加 SIGHUP 并在 `app.run` 启动时恢复**

`shutdown.installSignalHandlers()` 增 `std.posix.sigaction(std.posix.SIG.HUP, &act, null);`。`app.run` 在创建 logger 后、连接 IM 前：

```zig
if (mute.recoverStaleMute(allocator, io, environ)) logger.info("speaker", "restored mute state after an unclean exit", .{});
mute.setMarkerPath(io, environ);
```

- [ ] **Step 6: 运行测试 + 真机验证**

Run: `zig build test --summary all`
Expected: PASS（新增 3 条）。
真机：`./zig-out/bin/asr --debug` → 按住说话（听到 mute）→ 录音中 `pkill -9 -x asr` → `wpctl get-volume @DEFAULT_AUDIO_SINK@` 显示 `[MUTED]` → 再启动 ASR → 日志出现 `restored mute state after an unclean exit` 且 `wpctl` 不再 MUTED。

- [ ] **Step 7: Commit**

```bash
git add src/runtime/mute.zig src/runtime/shutdown.zig src/runtime/app.zig
git commit -m "feat: restore speaker mute state after a crash and handle sighup"
```

---

### Task 7: 键盘权限诊断（R5）

**Files:**
- Modify: `src/key.zig`、`src/runtime/app.zig`
- Test: `src/key.zig` 内测试

**Interfaces:**
- Consumes: Task 2 的 `app.keyFailureHint`
- Produces:
  - `pub const DeviceOpen = enum { usable, missing, denied };`
  - `pub fn classifyDeviceOpenError(err: anyerror) DeviceOpen`
  - `pub fn openDeviceState(io: std.Io, path: []const u8) DeviceOpen`（替换 `isUsableInputDevice`）
  - `findKeyboardDevice` 返回类型改为 `(error{ KeyboardDeviceNotFound, KeyboardPermissionDenied } || std.mem.Allocator.Error || ...)![]u8`：内部记录"是否出现过 denied"，最终无 usable 且出现过 denied → `error.KeyboardPermissionDenied`

- [ ] **Step 1: 写失败测试（RED）**

```zig
test "classifies device open errors" {
    try std.testing.expectEqual(DeviceOpen.denied, classifyDeviceOpenError(error.AccessDenied));
    try std.testing.expectEqual(DeviceOpen.missing, classifyDeviceOpenError(error.FileNotFound));
    try std.testing.expectEqual(DeviceOpen.missing, classifyDeviceOpenError(error.IsDir));
}

test "unreadable input device is reported as denied" {
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    const file = try tmp.dir.createFile(std.testing.io, "dev", .{ .permissions = .fromMode(0o000) });
    file.close(std.testing.io);
    const path = try std.fs.path.join(std.testing.allocator, &.{ ".zig-cache/tmp", tmp.sub_path[0..], "dev" });
    defer std.testing.allocator.free(path);
    if (openDeviceState(std.testing.io, path) == .usable) return error.SkipZigTest; // 以 root 运行，权限位无效
    try std.testing.expectEqual(DeviceOpen.denied, openDeviceState(std.testing.io, path));
}
```

（`std.testing.tmpDir` 的 `dir`/`sub_path` 是相对 cwd 的 `.zig-cache/tmp/<随机名>`；`std.Io.Dir` 没有 `realpathAlloc`，所以用 `std.fs.path.join` 拼路径。`std.posix` 没有 `geteuid`，用 "能打开就 SkipZigTest" 代替 root 判定。）

- [ ] **Step 2: 运行确认失败**

Run: `zig build test 2>&1 | head -20`
Expected: 编译失败（`DeviceOpen`/`classifyDeviceOpenError`/`openDeviceState` 不存在）。

- [ ] **Step 3: 实现并在 `findKeyboardDevice` 里传播**

`classifyDeviceOpenError`：`error.AccessDenied` → `.denied`，其余 → `.missing`。`openDeviceState`：`openFile` 成功 → close + `.usable`；失败 → `classifyDeviceOpenError(err)`。
`findKeyboardDevice`：三条候选路径（env / proc / by-id）都先取 `openDeviceState`，`.usable` 直接返回路径；`.denied` 置 `saw_denied = true`；最后 `if (saw_denied) return error.KeyboardPermissionDenied; return error.KeyboardDeviceNotFound;`。

- [ ] **Step 4: 在 `app.run` 用 `keyFailureHint` 打错误行**

```zig
const keyboard_device = key.findKeyboardDevice(allocator, io, environ) catch |err| {
    logger.err("kbd", "{s}: {s}", .{ @errorName(err), keyFailureHint(err) });
    return err;
};
```

- [ ] **Step 5: 运行测试确认通过**

Run: `zig build test --summary all`
Expected: PASS（新增 2 条）。

- [ ] **Step 6: Commit**

```bash
git add src/key.zig src/runtime/app.zig
git commit -m "fix: report keyboard permission problems instead of device-not-found"
```

---

### Task 8: 空采集显式错误（R6）

**Files:**
- Modify: `src/runtime/app.zig`
- Test: `src/runtime/app.zig` 内测试

**Interfaces:**
- Consumes: `mic.StreamSummary`
- Produces: `pub fn noAudioCaptured(summary: mic.StreamSummary) bool`

- [ ] **Step 1: 写失败测试（RED）**

```zig
test "flags a capture that produced no audio" {
    try std.testing.expect(noAudioCaptured(.{}));
    try std.testing.expect(noAudioCaptured(.{ .chunk_count = 3 }));
    try std.testing.expect(!noAudioCaptured(.{ .chunk_count = 1, .byte_count = 1 }));
}
```

- [ ] **Step 2: 运行确认失败**

Run: `zig build test 2>&1 | head -20`
Expected: 编译失败（`noAudioCaptured` 不存在）。

- [ ] **Step 3: 实现并在采集结束后短路**

`pub fn noAudioCaptured(summary: mic.StreamSummary) bool { return summary.byte_count == 0; }`；在 `runHotkeyLoop` 打完 `close_message` 之后、`if (!has_session)` 之前插入：

```zig
if (noAudioCaptured(capture_summary)) {
    logger.err("mic", "no_audio_captured: recorder produced 0 bytes; check the microphone and PipeWire", .{});
    output.keyWait(logger);
    continue;
}
```

（`continue` 走既有 defer 链清理 session 与 future，不要手工 `deinit`。）

- [ ] **Step 4: 运行测试确认通过**

Run: `zig build test --summary all`
Expected: PASS（新增 1 条）。

- [ ] **Step 5: Commit**

```bash
git add src/runtime/app.zig
git commit -m "fix: report an explicit error when the recorder captures no audio"
```

---

### Task 9: finish 超时后的 grace 窗口（R7）

**Files:**
- Modify: `src/runtime/engine.zig`、`src/doubao/client.zig`、`src/baidu/client.zig`
- Test: `src/runtime/engine.zig` 内测试

**Interfaces:**
- Consumes: `doubao/client.zig` 与 `baidu/client.zig` 的 `StreamingResultState.reader_closed`/`error_message`（同文件私有字段）
- Produces:
  - `engine.shouldWaitGrace(grace_ms: i64, reader_closed: bool, has_error: bool) bool`
  - `doubao.finish_grace_ms: i64 = 2_000`、`baidu.finish_grace_ms: i64 = 2_000`

- [ ] **Step 1: 写失败测试（RED）**

```zig
test "grace window only applies while the session is alive" {
    try std.testing.expect(shouldWaitGrace(2000, false, false));
    try std.testing.expect(!shouldWaitGrace(2000, true, false));
    try std.testing.expect(!shouldWaitGrace(2000, false, true));
    try std.testing.expect(!shouldWaitGrace(0, false, false));
}
```

- [ ] **Step 2: 运行确认失败**

Run: `zig build test 2>&1 | head -20`
Expected: 编译失败（`shouldWaitGrace` 不存在）。

- [ ] **Step 3: 实现**

`engine.zig`：`pub fn shouldWaitGrace(grace_ms: i64, reader_closed: bool, has_error: bool) bool { return grace_ms > 0 and !reader_closed and !has_error; }`。
两个 client 的 `finish()` 末尾改为：

```zig
const first = try session.waitForFinish(finish_timeout_ms);
if (first == .none and engine_grace.shouldWaitGrace(finish_grace_ms, session.state.reader_closed, session.state.error_message != null)) {
    return try session.waitForFinish(finish_grace_ms);
}
return first;
```

（`engine.zig` 导入会与 `client.zig` 形成循环 —— `engine.zig` 已经 import 两个 client。为避免环，把 `shouldWaitGrace` 放 `src/runtime/finish_grace.zig`（8 行小模块），两个 client 都 import 它；`root.zig` 加 export 与测试聚合。这是本任务唯一的模块拆分。）

- [ ] **Step 4: 运行测试确认通过**

Run: `zig build test --summary all`
Expected: PASS（新增 1 条）。

- [ ] **Step 5: Commit**

```bash
git add src/runtime/finish_grace.zig src/doubao/client.zig src/baidu/client.zig src/root.zig
git commit -m "fix: give the server a grace window for the final result after finish times out"
```

---

### Task 10: 提示音候选路径（R9）

**Files:**
- Modify: `src/runtime/notify.zig`
- Test: 同文件内测试

**Interfaces:**
- Consumes: `cmd.runDiscard`
- Produces:
  - `pub const bell_candidates = [_][]const u8{ "/run/current-system/sw/share/sounds/freedesktop/stereo/bell.oga", "/usr/share/sounds/freedesktop/stereo/bell.oga" };`
  - `pub fn selectBellIndex(candidates: []const []const u8, exists_fn: *const fn (path: []const u8) bool) ?usize`

- [ ] **Step 1: 写失败测试（RED）**

```zig
test "selects the first existing bell candidate" {
    const onlySecond = struct {
        fn exists(path: []const u8) bool { return std.mem.endsWith(u8, path, "second.oga"); }
    }.exists;
    const candidates = [_][]const u8{ "/a/first.oga", "/b/second.oga" };
    try std.testing.expectEqual(@as(?usize, 1), selectBellIndex(&candidates, onlySecond));

    const none = struct {
        fn exists(path: []const u8) bool { _ = path; return false; }
    }.exists;
    try std.testing.expect(selectBellIndex(&candidates, none) == null);
}
```

- [ ] **Step 2: 运行确认失败**

Run: `zig build test 2>&1 | head -20`
Expected: 编译失败（`selectBellIndex` 不存在）。

- [ ] **Step 3: 实现**

`selectBellIndex` 顺序遍历，`exists_fn` 首次为真即返回下标。`playMicReadyNotification`：

```zig
pub fn playMicReadyNotification(allocator: std.mem.Allocator, io: std.Io) void {
    const index = selectBellIndex(&bell_candidates, fileExists) orelse return;
    cmd.runDiscard(allocator, io, &.{ "pw-play", bell_candidates[index] }, 2000) catch {};
}
```

`fileExists` 用 `std.Io.Dir.cwd().openFile(io, path, .{}) catch return false` + close。可选：`$ASR_BELL` 环境变量优先（需 `environ`，若签名改动过大则省略并在 ledger 记 ruling）。

- [ ] **Step 4: 运行测试 + 真机听声**

Run: `zig build test --summary all`
Expected: PASS（新增 1 条）；真机按住说话时应能听到提示音（此前从未响过）。

- [ ] **Step 5: Commit**

```bash
git add src/runtime/notify.zig
git commit -m "fix: find the notification sound in the nixos system profile"
```

---

### Task 11: 纠错可选（R10）

**Files:**
- Modify: `src/runtime/postprocess.zig`、`src/runtime/app.zig`
- Test: `src/runtime/postprocess.zig` 内测试

**Interfaces:**
- Consumes: Task 2 的 `Pipeline.rectify_enabled` 字段与 `cli.Options.rectify`
- Produces: `postprocess.shouldRectify(enabled: bool, sami_token: []const u8, device_id: []const u8) bool`

- [ ] **Step 1: 写失败测试（RED）**

```zig
test "rectify needs the flag and both credentials" {
    try std.testing.expect(shouldRectify(true, "t", "d"));
    try std.testing.expect(!shouldRectify(false, "t", "d"));
    try std.testing.expect(!shouldRectify(true, "", "d"));
    try std.testing.expect(!shouldRectify(true, "t", ""));
}
```

- [ ] **Step 2: 运行确认失败**

Run: `zig build test 2>&1 | head -20`
Expected: 编译失败（`shouldRectify` 不存在）。

- [ ] **Step 3: 实现**

`shouldRectify` 三条件与运算；`rectifyWorker` 用 `if (!shouldRectify(...)) { 记 🚀 原文本 + enqueue; continue; }` 跳过 curl；`app.run` 调 `Pipeline.start(..., opts.rectify)`。

- [ ] **Step 4: 运行测试确认通过**

Run: `zig build test --summary all`
Expected: PASS（新增 1 条）。

- [ ] **Step 5: Commit**

```bash
git add src/runtime/postprocess.zig src/runtime/app.zig
git commit -m "feat: make result rectification optional"
```

---

### Task 12: 最大按住时长（R11）

**Files:**
- Modify: `src/key.zig`、`src/runtime/mic.zig`、`src/runtime/app.zig`
- Test: `src/key.zig`、`src/runtime/app.zig` 内测试

**Interfaces:**
- Consumes: Task 2 的 `cli.Options.max_hold_ms`
- Produces:
  - `key.WaitOutcome = enum { released, shutdown, timed_out }`
  - `key.holdStopReason(released: bool, stop: bool, elapsed_ms: i64, max_hold_ms: i64) WaitOutcome`
  - `key.waitForDeviceReleaseOrShutdown(io, file, state, key_code, is_stop, max_hold_ms) DeviceReadError!WaitOutcome`（签名扩展，`max_hold_ms <= 0` → 不限时）
  - `mic.StreamOptions.on_hold_timeout: ?*const fn (ctx: ?*anyopaque) void`；`captureStreamUntilKeyRelease(..., max_hold_ms: i64, stream: StreamOptions)`

- [ ] **Step 1: 写失败测试（RED）**

```zig
test "hold stop reason prefers release then shutdown then timeout" {
    try std.testing.expectEqual(WaitOutcome.released, holdStopReason(true, false, 0, 1000));
    try std.testing.expectEqual(WaitOutcome.shutdown, holdStopReason(false, true, 0, 1000));
    try std.testing.expectEqual(WaitOutcome.timed_out, holdStopReason(false, false, 1000, 1000));
    try std.testing.expectEqual(WaitOutcome.released, holdStopReason(false, false, 1000, 0));
    try std.testing.expectEqual(WaitOutcome.released, holdStopReason(false, false, 1000, -1));
}
```

（最后一例的语义：`max_hold_ms <= 0` 表示不限时，"未到点"用 `.released` 表示继续等待 —— 该枚举在此分支只表达"本次判定结果"，实现在无限时分支永不进入 timeout。）

- [ ] **Step 2: 运行确认失败**

Run: `zig build test 2>&1 | head -20`
Expected: 编译失败（`WaitOutcome`/`holdStopReason` 不存在）。

- [ ] **Step 3: 实现 `key.zig`**

`waitNextDeviceEventOrShutdown` 的 Select 增第三臂 `deadlineTask`：`max_hold_ms <= 0` 时不注册该臂；注册时用 `sleepUntilOr` 轮询"是否 stop"直到截止，返回 `.timed_out`。`waitForDeviceReleaseOrShutdown` 循环里按 `holdStopReason(released, stop, elapsed, max_hold_ms)` 决定返回 `WaitOutcome`。

- [ ] **Step 4: 实现 `mic.zig` / `app.zig`**

`captureStreamUntilKeyRelease` 增 `max_hold_ms` 参数，把 `key.waitForDeviceReleaseOrShutdown(...)` 的结果接住：`.timed_out` → 调 `stream.on_hold_timeout`（若提供）后照常 `stopCaptureAndJoin`（与松手同一路径，因此仍会 finish 并提交已识别内容）。`app.runHotkeyLoop` 传 `opts.max_hold_ms`，并设 `.on_hold_timeout = onHoldTimeout`（`logger.info("mic", "max hold reached; stopping", .{})`，ctx 复用 `started_state`）。

- [ ] **Step 5: 运行测试 + 真机验证**

Run: `zig build test --summary all`
Expected: PASS（新增 1 条）；真机：`./zig-out/bin/asr --debug --max-hold-ms 3000` 按住 5 秒 → 3 秒时日志出现 `max hold reached; stopping`、`up RightAlt` 只出现一次、随后正常 `session_finished`。

- [ ] **Step 6: Commit**

```bash
git add src/key.zig src/runtime/mic.zig src/runtime/app.zig
git commit -m "feat: cap the maximum hold duration"
```

---

### Task 13: `--log-file` 追加写（R12）

**Files:**
- Modify: `src/runtime/output.zig`、`src/main.zig`、`src/runtime/app.zig`
- Test: `src/runtime/output.zig` 内测试

**Interfaces:**
- Consumes: Task 2 的 `cli.Options.log_file`
- Produces:
  - `output.LogFile`（`pub fn open(path: []const u8) !LogFile`、`pub fn writeLine(log_file: *LogFile, line: []const u8) void`、`pub fn deinit(log_file: *LogFile) void`）
  - `output.Logger` 增字段 `log_file: ?*LogFile = null`；`log_file != null` 时只写文件（错误级别也写文件）

- [ ] **Step 1: 写失败测试（RED）**

```zig
test "log file appends every line" {
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    const path = try std.fs.path.join(std.testing.allocator, &.{ ".zig-cache/tmp", tmp.sub_path[0..], "asr.log" });
    defer std.testing.allocator.free(path);

    var first = try LogFile.open(path);
    first.writeLine("one\n");
    first.deinit();
    var second = try LogFile.open(path);
    second.writeLine("two\n");
    second.deinit();

    const contents = try std.Io.Dir.cwd().readFileAlloc(std.testing.io, path, std.testing.allocator, .limited(1024));
    defer std.testing.allocator.free(contents);
    try std.testing.expectEqualStrings("one\ntwo\n", contents);
}
```

- [ ] **Step 2: 运行确认失败**

Run: `zig build test 2>&1 | head -20`
Expected: 编译失败（`LogFile` 不存在）。

- [ ] **Step 3: 实现 `LogFile` 与 `Logger.log_file`**

`LogFile.open`：`const fd = try std.posix.open(path, .{ .ACCMODE = .WRONLY, .CREAT = true, .APPEND = true }, 0o644);`（字段名若与 0.16 不符按编译错误调整并在 ledger 记 ruling），`LogFile{ .fd = fd }`。`writeLine`：`std.posix.write(log_file.fd, line) catch return;`（`std.posix.write` 已处理 EINTR）。`deinit`：`std.posix.close(log_file.fd)`。`Logger.write`：把格式化目标从"stdout/stderr writer"改为 `var buffer: [1024]u8`，`std.fmt.bufPrint` 出整行后：`if (logger.log_file) |lf| lf.writeLine(line) else 走原 console 路径`。

- [ ] **Step 4: 接入 `main.zig` 与 `app.run`**

`main.zig`：`.app` 分支里若 `opts.log_file` 非空 → `var log_file = output.LogFile.open(path) catch { stderr 打印 `asr: cannot open log file ...`; std.process.exit(2); };` 并把 `&log_file` 传给 `app.run(allocator, io, environ, opts, &log_file)`；`app.run` 增参数 `log_file: ?*output.LogFile`，创建 Logger 时 `.{ .io = io, .level = ..., .log_file = log_file }`。

- [ ] **Step 5: 运行测试 + 真机验证**

Run: `zig build test --summary all`
Expected: PASS（新增 1 条）；真机：`./zig-out/bin/asr --debug --log-file /tmp/asr.log` → `/tmp/asr.log` 里出现完整启动日志；再跑一次 → 两段日志都在（追加，不覆盖）。

- [ ] **Step 6: Commit**

```bash
git add src/runtime/output.zig src/main.zig src/runtime/app.zig
git commit -m "feat: add --log-file that appends instead of overwriting"
```

---

### Task 14: 工程门禁与 fmt（R13）

**Files:**
- Modify: `build.zig`、`src/baidu/proto.zig`、`src/doubao/rectify.zig`、`README.md`（一行说明）
- Test: 命令验收

**Interfaces:**
- Consumes: 全部前序任务
- Produces: `zig build check` 步骤

- [ ] **Step 1: 格式化现有树**

Run: `zig fmt src build.zig && git diff --stat`
Expected: 只有 `src/baidu/proto.zig` 与 `src/doubao/rectify.zig` 变更，且是纯格式差异（人工确认 diff 无逻辑变化）。

- [ ] **Step 2: 加 `check` 步骤**

```zig
const fmt_check = b.addFmt(.{ .paths = &.{ "src", "build.zig" }, .check = true });
const check_step = b.step("check", "zig fmt --check plus tests");
check_step.dependOn(&fmt_check.step);
check_step.dependOn(&run_tests.step);
```

- [ ] **Step 3: 验证**

Run: `zig build check && zig fmt --check src build.zig`
Expected: 两条命令都成功（后者无输出）。

- [ ] **Step 4: Commit**

```bash
git add build.zig src/baidu/proto.zig src/doubao/rectify.zig README.md
git commit -m "build: add a check step and format the tree"
```

---

## Self-Review

**Spec coverage:** R1→T4、R2→T4、R3→T5、R4→T6、R5→T7、R6→T8、R7→T9、R8→T6、R9→T10、R10→T11、R11→T12、R12→T13、R13→T14、R14→T2 Step 5；删除清单→T1/T2/T3；行为变化→T2/T4/T6/T7/T8/T13。
**已知缺口（ledger 处理）：** 多键盘监听（P2-8）与 `app.zig` 拆分（A1）按 spec 的"非目标"另立计划；Task 4 的 `Stream` 假对象初始化方式、Task 10 的 `$ASR_BELL`、Task 13 的 `std.posix.open` 字段名在实现时按编译结果落 ruling。
**类型一致性：** `Pipeline.start` 在 T2 定签名，T11 追加 `rectify_enabled` 实参；`captureStreamUntilKeyRelease` 在 T12 追加 `max_hold_ms`；`app.run` 在 T13 追加 `log_file`；`ConnectError` 在 T4 增 `MalformedMessage` 并在 T5 复用。
**Review Focus 对应：** 5 条分别由 T4（1）、T8（2）、T12（3）、T6（4）、T13（5）覆盖。
