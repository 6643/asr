# evdev 读泵实现计划

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** 把 evdev 的阻塞读搬到 `std.Io` 之外的泵线程，让拔键盘的 `ENODEV` 变成 pipe 的 EOF，从而撤销 `unexpected_error_tracing = false` 并保留全局诊断。

**Architecture:** 每条设备一个泵线程 + 一条 4 KiB pipe。泵用裸 `poll`/`read`/`write` 把事件字节搬进 pipe，并记录死因；应用侧仍用 `std.Io.File.readStreaming` 读 pipe（可取消语义不变）。`Device.file` 变成 pipe 读端，`Select` 臂与按住等待的代码不变。

**Tech Stack:** Zig 0.17，`std.posix` / `std.os.linux` 裸 syscall，`std.Thread`，`std.Io.Select`。

**Spec:** `docs/superpowers/specs/2026-11-06-evdev-pump-design.md`

## Global Constraints

- 只支持当前平台（Linux + Wayland），不引入第三方依赖，不新增 libc 之外的链接。
- 不改变事件解析、按键语义、热键循环、重扫节奏、录音/引擎/Wayland 链路。
- 应用侧读路径必须是 `std.Io` 的可取消读；泵线程内不得调用 `std.Io`。
- 数据 pipe 只有泵写；读端只在 `join` 之后关闭（Zig 0.17 默认不忽略 SIGPIPE）。
- 泵线程栈 `128 * 1024` 字节；pipe 容量尽力设为 `4096`（`F.SETPIPE_SZ` 失败则用默认值）。
- `Device.pump == null` 表示该设备没有泵（`adopt` 的测试设备），关闭行为与今天一致。

## Review Focus

- 设备消失前已缓冲的事件必须先送达、再给 EOF：泵按 `POLLIN` 先读，`POLLERR|POLLHUP|POLLNVAL` 只在没有可读数据时才判死（Task 2 测试 1）。
- 应用侧长时间不读导致 pipe 写满时，泵必须等 `POLLOUT` 且能被 stop 打断，不能卡住 `closeAll`（Task 2 测试 3）。
- 关闭顺序错误会触发 SIGPIPE 杀进程：`killDevice`/`closeAll` 一律先停泵再关读端（Task 3 测试 1/2）。
- 泵启动失败（`pipe2`/`eventfd`/`spawn`/内存）必须让该设备被跳过、调用方的 fd 被关闭，进程继续（Task 3 测试 3）。
- `adopt` 的无泵设备仍要正常关闭、不泄漏（既有测试，Task 3 步骤 5 回归）。

---

### Task 1: 读 errno 分类器（`src/key.zig`）

**Files:**
- Modify: `src/key.zig`（`mapReadStreamingError` 附近，约 455-470 行）
- Test: `src/key.zig`（文件末尾 `test` 区）

**Interfaces:**
- Consumes: `std.posix.E`
- Produces: `key.PumpDeath = enum(u8) { none, gone, end_of_stream, failed }`、`key.PumpReadVerdict = enum { keep_reading, device_gone, failed }`、`key.classifyPumpReadErrno(err: std.posix.E) key.PumpReadVerdict`

- [ ] **Step 1: 写失败测试**

在 `src/key.zig` 的测试区加入：

```zig
test "classifies pump read errnos" {
    try std.testing.expectEqual(PumpReadVerdict.keep_reading, classifyPumpReadErrno(.INTR));
    try std.testing.expectEqual(PumpReadVerdict.keep_reading, classifyPumpReadErrno(.AGAIN));
    try std.testing.expectEqual(PumpReadVerdict.device_gone, classifyPumpReadErrno(.NODEV));
    try std.testing.expectEqual(PumpReadVerdict.device_gone, classifyPumpReadErrno(.NXIO));
    try std.testing.expectEqual(PumpReadVerdict.failed, classifyPumpReadErrno(.IO));
}
```

- [ ] **Step 2: 跑测试确认失败**

Run: `zig build test --cache-dir /tmp/asr-t1 2>&1 | tail -5`
Expected: 编译失败，`classifyPumpReadErrno` 未定义。

- [ ] **Step 3: 实现**

在 `mapReadStreamingError` 之后加：

```zig
/// 泵线程看到的 evdev 读 errno 该怎么处理。ENODEV/ENXIO 表示设备已被内核
/// 吊销（拔掉、休眠），不是程序错误；INTR/EAGAIN 只是重试。
pub fn classifyPumpReadErrno(err: std.posix.E) PumpReadVerdict {
    return switch (err) {
        .INTR, .AGAIN => .keep_reading,
        .NODEV, .NXIO => .device_gone,
        else => .failed,
    };
}
```

并在 `DeviceReadError` 定义之后加两个类型（`PumpDeath.none` 就是“泵还活着或正常停止”）：

```zig
/// 泵停止读设备的原因，只用于把 EOF 细化成更准确的日志。
pub const PumpDeath = enum(u8) { none, gone, end_of_stream, failed };
pub const PumpReadVerdict = enum { keep_reading, device_gone, failed };
```

- [ ] **Step 4: 跑测试确认通过**

Run: `zig build test --cache-dir /tmp/asr-t1 2>&1 | tail -3`
Expected: `Build Summary: … tests passed`，退出码 0。

- [ ] **Step 5: 提交**

```bash
git add src/key.zig
git commit -m "feat(key): classify evdev read errnos for the pump"
```

---

### Task 2: 泵线程（`src/runtime/keyboard.zig`）

**Files:**
- Modify: `src/runtime/keyboard.zig`（`fakePath` 之前新增 `Pump`，文件末尾加测试）

**Interfaces:**
- Consumes: `key.PumpDeath`、`key.PumpReadVerdict`、`key.classifyPumpReadErrno`、`key.inputEvent`、`key.readNextDeviceEvent`
- Produces:

```zig
pub const Pump = struct {
    pub const Attachment = struct { pump: *Pump, file: std.Io.File };
    pub const stack_size: usize = 128 * 1024;
    pub const pipe_capacity: usize = 4096;

    thread: ?std.Thread = null,
    stop_fd: std.posix.fd_t,
    death: std.atomic.Value(u8) = .init(@intFromEnum(key.PumpDeath.none)),

    /// 成功后接管 `evdev` 的 fd；失败时 fd 仍归调用方。
    pub fn start(allocator: std.mem.Allocator, evdev: std.Io.File) !Attachment;
    /// 写 stop、join、关 stop fd、释放自身；调用方必须随后把持有它的字段置 null。
    pub fn deinit(self: *Pump, allocator: std.mem.Allocator) void;
    pub fn deathReason(self: *const Pump) key.PumpDeath;
};
```

- 泵线程函数：`fn pumpMain(pump: *Pump, evdev_fd: std.posix.fd_t, pipe_write: std.posix.fd_t) void`
- 写 pipe 的辅助函数：`fn writeAll(stop_fd: std.posix.fd_t, fd: std.posix.fd_t, bytes: []const u8) bool`（返回 `false` 表示被 stop 或写端坏掉，泵应退出）

- [ ] **Step 1: 写失败测试**

```zig
test "pump forwards events before reporting end of stream" {
    const allocator = std.testing.allocator;
    var fds: [2]i32 = undefined;
    if (std.posix.errno(std.os.linux.pipe2(&fds, .{ .CLOEXEC = true })) != .SUCCESS) return error.PipeFailed;
    const attached = try Pump.start(allocator, .{ .handle = fds[0], .flags = .{ .nonblocking = false } });
    defer attached.file.close(std.testing.io);
    defer attached.pump.deinit(allocator);

    const press = key.inputEvent(key.ev_key, key.right_alt, 1);
    const release = key.inputEvent(key.ev_key, key.right_alt, 0);
    _ = std.posix.system.write(fds[1], &press, press.len);
    _ = std.posix.system.write(fds[1], &release, release.len);
    _ = std.posix.system.close(fds[1]);

    var state: key.State = .{};
    try std.testing.expectEqual(key.Event.press, try key.readNextDeviceEvent(std.testing.io, attached.file, &state, key.right_alt));
    try std.testing.expectEqual(key.Event.release, try key.readNextDeviceEvent(std.testing.io, attached.file, &state, key.right_alt));
    try std.testing.expectError(error.EndOfStream, key.readNextDeviceEvent(std.testing.io, attached.file, &state, key.right_alt));
    try std.testing.expectEqual(key.PumpDeath.end_of_stream, attached.pump.deathReason());
}

test "pump stops while idle" {
    const allocator = std.testing.allocator;
    var fds: [2]i32 = undefined;
    if (std.posix.errno(std.os.linux.pipe2(&fds, .{ .CLOEXEC = true })) != .SUCCESS) return error.PipeFailed;
    const attached = try Pump.start(allocator, .{ .handle = fds[0], .flags = .{ .nonblocking = false } });
    defer attached.file.close(std.testing.io);
    defer std.posix.system.close(fds[1]);

    const started = std.Io.Clock.real.now(std.testing.io).toMilliseconds();
    attached.pump.deinit(allocator);
    const elapsed = std.Io.Clock.real.now(std.testing.io).toMilliseconds() - started;
    try std.testing.expect(elapsed < 500);
}

test "pump stops while its pipe is full" {
    const allocator = std.testing.allocator;
    var fds: [2]i32 = undefined;
    if (std.posix.errno(std.os.linux.pipe2(&fds, .{ .CLOEXEC = true })) != .SUCCESS) return error.PipeFailed;
    const attached = try Pump.start(allocator, .{ .handle = fds[0], .flags = .{ .nonblocking = false } });
    defer attached.file.close(std.testing.io);
    defer std.posix.system.close(fds[1]);

    // 171 个事件 = 4104 B，超过泵 pipe 的 4096 B 容量，且远小于假设备 pipe 的 64 KiB。
    var batch: [171 * key.input_event_size]u8 = undefined;
    for (0..171) |index| {
        const event = key.inputEvent(key.ev_key, key.right_alt, 1);
        @memcpy(batch[index * key.input_event_size ..][0..key.input_event_size], &event);
    }
    _ = std.posix.system.write(fds[1], &batch, batch.len);

    const started = std.Io.Clock.real.now(std.testing.io).toMilliseconds();
    attached.pump.deinit(allocator);
    const elapsed = std.Io.Clock.real.now(std.testing.io).toMilliseconds() - started;
    try std.testing.expect(elapsed < 500);
}
```

- [ ] **Step 2: 跑测试确认失败**

Run: `zig build test --cache-dir /tmp/asr-t2 2>&1 | tail -5`
Expected: 编译失败，`Pump` 未定义。

- [ ] **Step 3: 实现 `Pump`**

要点（签名与测试已定，细节如下）：

- `start`：`pipe2(CLOEXEC)` → `F.SETPIPE_SZ = pipe_capacity`（失败忽略）→ 写端 `F.SETFL` 加 `O_NONBLOCK`（`1 << @bitOffsetOf(std.posix.O, "NONBLOCK")`，参考 `drainDevice`）→ `std.os.linux.eventfd(0, EFD.CLOEXEC | EFD.NONBLOCK)` → `allocator.create(Pump)` → `Thread.spawn(.{ .stack_size = stack_size }, pumpMain, .{ pump, evdev.handle, write_fd })`。任一步失败都要关掉已建 fd、`allocator.destroy`，并保持 `evdev` 的 fd 归调用方。
- `pumpMain`：`defer` 里按 `pipe_write`、`evdev_fd` 顺序 `system.close`；循环：
  1. `system.poll` 两个 fd（evdev `POLL.IN`、stop `POLL.IN`），`-1` 超时；`INTR` 重试，其他 errno → `death = .failed` 并返回。
  2. stop 有 `revents` → 直接返回，`death` 保持 `.none`。
  3. evdev 有 `POLL.IN` → `system.read` 最多 `16 * key.input_event_size` 字节；返回 >0 → `writeAll`（`false` → 返回）；==0 → `death = .end_of_stream` 返回；errno → `key.classifyPumpReadErrno`：`keep_reading` 继续、`device_gone` → `.gone` 返回、`failed` → `.failed` 返回。
  4. 没有 `POLL.IN` 但有 `ERR|NVAL|HUP` → `death = .gone` 返回；否则继续（先把可读数据读干净再判死）。
  5. 所有 `death` 写入用 `store(release)`，必须发生在 `pipe_write` 关闭之前。
- `writeAll`：循环 `system.write`；`SUCCESS` 累加；`INTR` 重试；`AGAIN` → `poll`（写端 `POLL.OUT`、stop `POLL.IN`）后再试；stop 有事件或 `INTR` 以外失败（含 `EPIPE`）→ 返回 `false`。
- `deinit`：`thread` 非 null 时把 `1u64` 写给 `stop_fd`（`system.write`，8 字节），`join()`，置 `thread = null`；然后 `close(stop_fd)` 与 `allocator.destroy(self)`。可重复调用只在字段已置 null 的前提下安全，调用方负责。
- `deathReason`：`@enumFromInt(self.death.load(.acquire))`。

- [ ] **Step 4: 跑测试确认通过**

Run: `zig build test --cache-dir /tmp/asr-t2 2>&1 | tail -3`
Expected: 三个新测试通过，退出码 0。

- [ ] **Step 5: 提交**

```bash
git add src/runtime/keyboard.zig
git commit -m "feat(kbd): pump evdev reads through a pipe so revocation is EOF"
```

---

### Task 3: 接进 `Set` 并把 EOF 细化成具体原因

**Files:**
- Modify: `src/runtime/keyboard.zig`（`Device`、`openAll`、`add`、`closeAll`、`killDevice`、`readNextOrShutdown` 错误分支）
- Test: `src/runtime/keyboard.zig`（文件末尾）

**Interfaces:**
- Consumes: Task 2 的 `Pump`
- Produces:

```zig
pub const Device = struct {
    path: []u8,
    file: std.Io.File, // 泵设备是 pipe 读端；adopt 的是调用方的 fd
    pump: ?*Pump = null,
    state: key.State = .{},
    dead: bool = false,
};

/// 接管 `file`：任何错误路径都由这里关闭 `file` 并返回错误。
pub fn add(self: *Set, path: []const u8, file: std.Io.File) !void;

/// EOF 时用泵记录的死因给出具体错误，其余错误原样返回。
fn refineRemovalError(device: *const Device, err: key.DeviceReadError) key.DeviceReadError;
```

- [ ] **Step 1: 写失败测试**

```zig
test "removal error uses the pump death reason" {
    const allocator = std.testing.allocator;
    var device = Device{
        .path = try fakePath(allocator, "pump"),
        .file = .{ .handle = -1, .flags = .{ .nonblocking = false } },
    };
    defer allocator.free(device.path);

    var pump = Pump{ .stop_fd = -1, .death = .init(@intFromEnum(key.PumpDeath.gone)) };
    device.pump = &pump;
    try std.testing.expectEqual(error.KeyboardDeviceDisconnected, refineRemovalError(&device, error.EndOfStream));

    pump.death.store(@intFromEnum(key.PumpDeath.failed), .release);
    try std.testing.expectEqual(error.ReadFailed, refineRemovalError(&device, error.EndOfStream));

    pump.death.store(@intFromEnum(key.PumpDeath.none), .release);
    try std.testing.expectEqual(error.EndOfStream, refineRemovalError(&device, error.EndOfStream));
    try std.testing.expectEqual(error.Interrupted, refineRemovalError(&device, error.Interrupted));
}

test "set pumps a fake evdev and drops it after end of stream" {
    const allocator = std.testing.allocator;
    const logger: output.Logger = .{ .io = std.testing.io, .level = .err };
    var fds: [2]i32 = undefined;
    if (std.posix.errno(std.os.linux.pipe2(&fds, .{ .CLOEXEC = true })) != .SUCCESS) return error.PipeFailed;

    var set = Set{ .allocator = allocator, .io = std.testing.io, .logger = logger };
    try set.add("/fake/pump", .{ .handle = fds[0], .flags = .{ .nonblocking = false } });
    defer set.closeAll();
    defer std.posix.system.close(fds[1]);

    const press = key.inputEvent(key.ev_key, key.right_alt, 1);
    _ = std.posix.system.write(fds[1], &press, press.len);
    const outcome = try set.readNextOrShutdown(key.right_alt, neverShutdown, null, null);
    try std.testing.expectEqual(key.Event.press, outcome.event.kind);
    try std.testing.expectEqualStrings("/fake/pump", outcome.event.device.path);
}

test "add closes the device when the pump cannot start" {
    const logger: output.Logger = .{ .io = std.testing.io, .level = .err };
    var fds: [2]i32 = undefined;
    if (std.posix.errno(std.os.linux.pipe2(&fds, .{ .CLOEXEC = true })) != .SUCCESS) return error.PipeFailed;
    defer std.posix.system.close(fds[1]);

    var failing = std.testing.FailingAllocator.init(std.testing.allocator, .{ .fail_index = 0 });
    var set = Set{ .allocator = failing.allocator(), .io = std.testing.io, .logger = logger };
    try std.testing.expectError(error.OutOfMemory, set.add("/fake/fail", .{ .handle = fds[0], .flags = .{ .nonblocking = false } }));
    try std.testing.expectEqual(std.posix.E.BADF, std.posix.errno(std.posix.system.fcntl(fds[0], std.posix.system.F.GETFL, 0)));
}
```

`neverShutdown` 是文件里已有的测试谓词。

- [ ] **Step 2: 跑测试确认失败**

Run: `zig build test --cache-dir /tmp/asr-t3 2>&1 | tail -5`
Expected: 编译失败（`Device.pump` / `refineRemovalError` 不存在）。

- [ ] **Step 3: 实现**

- `add`：`dupe(path)` → `Pump.start(allocator, file)` → `append(.{ .path = owned, .file = attached.file, .pump = attached.pump })`。所有错误路径统一关闭 `file`（`Pump.start` 成功后才换成 `attached.file`/`attached.pump`；append 失败要 `pump.deinit` + `attached.file.close`）。
- `openAll`：把内联的 `append` 换成 `self.add(path, file)`，错误照旧记录并 `continue`（`add` 已负责关闭 fd）。
- `closeAll`：`for (self.devices.items) |*device|`（改成可变引用）；先 `if (device.pump) |pump| { pump.deinit(self.allocator); device.pump = null; }`，再 `if (!device.dead) device.file.close(self.io);`，最后 `free(path)`。**顺序不可反**。
- `killDevice`：同样先停泵（`deinit` + 置 null），再 `device.file.close(self.io)`，最后 `dead = true`。
- `readNextOrShutdown` 的 `else =>` 分支：`self.logRemoved(index, refineRemovalError(&self.devices.items[index], err));`（在 `killDevice` 之前，日志要先读泵的死因）。
- `refineRemovalError`：非 `error.EndOfStream` 原样返回；`device.pump` 为 null 原样返回；否则按 `deathReason()`：`.gone` → `error.KeyboardDeviceDisconnected`，`.failed` → `error.ReadFailed`，其余原样。

- [ ] **Step 4: 跑测试确认通过**

Run: `zig build test --cache-dir /tmp/asr-t3 2>&1 | tail -3`
Expected: 两个新测试与既有测试全部通过。

- [ ] **Step 5: 回归既有测试**

Run: `zig build test --cache-dir /tmp/asr-t3 2>&1 | rg "tests passed|FAIL"`
Expected: 175 + 新增数量全部通过，无 FAIL。

- [ ] **Step 6: 提交**

```bash
git add src/runtime/keyboard.zig
git commit -m "feat(kbd): wire the evdev pump into the keyboard set"
```

---

### Task 4: 撤销全局开关、同步文档、整体验证

**Files:**
- Modify: `src/main.zig`（删掉 `unexpected_error_tracing = false` 及其注释）
- Modify: `README.md`（键盘热键小节）
- Modify: `docs/superpowers/specs/2026-11-06-evdev-pump-design.md`（如实现与设计有偏差，就地修正）

**Interfaces:**
- Consumes: Task 3 的全部行为
- Produces: 无新接口

- [ ] **Step 1: 撤销开关**

`src/main.zig` 的 `std_options` 恢复成只有 `.logFn`，删掉 `.unexpected_error_tracing = false` 和那 7 行注释。

- [ ] **Step 2: 同步 README**

键盘热键小节：删掉“Debug 构建关掉了 Zig 的 unexpected-errno 栈回溯”那一条，改成描述泵（evdev 读在独立线程，拔掉/休眠 → `KeyboardDeviceDisconnected; removed`，节点消失 → `EndOfStream; removed`，都不会触发 std 的 unexpected-errno 栈回溯）。

- [ ] **Step 3: 验证诊断确实回来了**

Run: `zig fmt --check src build.zig && zig build 2>&1 | tail -3 && grep -c "unexpected errno" zig-out/bin/asr`
Expected: fmt 通过；构建成功；字面量计数 ≥ 1（开关重新生效）。

- [ ] **Step 4: 全量检查**

Run: `zig build check --summary all 2>&1 | tail -6`
Expected: `check success`，测试全通过。

- [ ] **Step 5: 冒烟**

Run: `./zig-out/bin/asr --help | head -3`
Expected: 正常打印用法，退出码 0。

- [ ] **Step 6: 提交**

```bash
git add src/main.zig README.md docs/superpowers/specs/2026-11-06-evdev-pump-design.md docs/superpowers/plans/2026-11-06-evdev-pump.md
git commit -m "docs: describe the evdev pump and restore unexpected-errno tracing"
```

---

## 手工验证（需要真实键盘）

本机 `/dev/uinput` 仅 root，无法自动复现 ENODEV。插拔一次键盘：

- 拔掉：预期只有一行 `[kbd] <path>: KeyboardDeviceDisconnected; removed`，**没有** `unexpected errno` 与栈回溯。
- 插回：2 秒内出现 `[kbd] added <path>`，按 RightAlt 能正常录音。
