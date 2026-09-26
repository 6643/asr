# Wayland 输入法后端实现计划

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** ASR 在 Wayland（niri）上作为 seat 输入法绑定 `zwp_input_method_v2`，把最终识别文本用 `commit_string` + `commit` 提交到焦点文本输入，保留 IBus 路径并自动回退。

**Architecture:** 新增纯 Zig raw wire 协议客户端 `src/runtime/wayland_im.zig`（`std.Io.net.UnixAddress/Stream` + `std.posix.poll`/`system.read/write`，无新增依赖）；`postprocess.Pipeline` 的提交目标抽象为 `CommitBackend`；`app.run` 启动时按环境与 flag 选择后端，Wayland 路径跑独立事件循环线程。

**Tech Stack:** Zig 0.16、`std.Io`、`std.posix`、evdev 快捷键（不变）。

**Spec:** `docs/superpowers/specs/2026-09-26-wayland-input-method-design.md`

## Global Constraints

- 不新增第三方库或链接依赖；只使用 `std.posix`（AF_UNIX socket、非阻塞 read、poll）与现有 `std.Io`。
- 保留 IBus 路径，行为与代码不变；`--ibus`、`--ibus-xml`、`--once-pcm` 语义不变。
- 不改变快捷键读取（evdev）、录音、ASR、rectify、静音、提示音链路。
- object id 严格顺序分配（2,3,4,5…），不跳号不复用。
- `commit_string` 每段 ≤4000 字节，按 UTF-8 边界切分；单次提交的所有消息合并为一次 `write`（互斥锁内）。
- 提交状态字符串沿用 `"OK …"` / `"ERR …"` 前缀；Wayland 后端日志 domain 为 `wayland`。
- 命令统一用 `zig build test` 与 `zig build` 验证。

## Review Focus

1. 真实合成器 socket 行为（EOF/EPIPE/EAGAIN、半消息、一次 read 含多条消息）：期望连接失效时标记 dead 并返回 `ERR wayland_unavailable`，不得崩溃。解析与状态分支由 Task 1/2 单测覆盖；真实 IO 行为留 Task 8 手动验证。
2. 焦点在非 text-input-v3 应用（Chrome 未启用 `--enable-wayland-ime`、XWayland 应用）时提交：期望返回 `ERR no_text_input` 且不误写。状态判定由 Task 4 单测覆盖；真实应用覆盖由 Task 8 手动验证。
3. 恰好 4000 字节与多字节 UTF-8 边界切分：期望单段/合法边界，不切断字符。Task 4 单测覆盖。
4. `WAYLAND_DISPLAY` 缺失、绝对路径、无 compositor 时自动回退 IBus：期望路径解析正确、回退后 IBus 行为不变。路径解析由 Task 3 单测覆盖；回退行为由 Task 7 手动验证。
5. seat 上已有其它 IM 时的 `unavailable`：期望 `connect` 判定 `error.InputMethodUnavailable`，后续提交返回 `ERR wayland_unavailable`。Task 2 单测覆盖事件处理；真实互斥场景由 Task 8 手动验证。

---

### Task 1: 线协议编解码

**Files:**
- Create: `src/runtime/wayland_im.zig`
- Modify: `src/root.zig`（runtime 段加 `pub const wayland_im = @import("runtime/wayland_im.zig");`，test 块加 `_ = runtime.wayland_im;`）

**Interfaces:**
- Produces:
  - `pub const max_commit_bytes: usize = 4000;`
  - `pub fn appendMessage(allocator: std.mem.Allocator, buf: *std.ArrayList(u8), object_id: u32, opcode: u16, payload: []const u8) !void`
  - `pub fn appendString(allocator: std.mem.Allocator, buf: *std.ArrayList(u8), text: []const u8) !void`（长度含结尾 NUL，按 4 字节对齐补零）
  - `pub fn encodeCommitString(allocator: std.mem.Allocator, buf: *std.ArrayList(u8), im_id: u32, text: []const u8) !void`
  - `pub fn encodeCommit(allocator: std.mem.Allocator, buf: *std.ArrayList(u8), im_id: u32, serial: u32) !void`
  - `pub const Message = struct { object_id: u32, opcode: u16, payload: []const u8, total_size: usize };`
  - `pub fn extractMessage(buf: *const std.ArrayList(u8)) ?Message`（不足一条完整消息返回 null；payload 指向 buf 内部）
  - `pub fn consumeMessage(buf: *std.ArrayList(u8), total_size: usize) void`
  - `pub fn readU32(payload: []const u8) ?u32`
  - `pub fn readString(payload: []const u8, offset: *usize) ?[]const u8`

- [ ] **Step 1: 写失败测试**

```zig
test "appendString pads length-prefixed strings to four bytes" {
    var buf: std.ArrayList(u8) = .empty;
    defer buf.deinit(std.testing.allocator);
    try appendString(std.testing.allocator, &buf, "a");
    try std.testing.expectEqualSlices(u8, &.{ 0x02, 0x00, 0x00, 0x00, 'a', 0x00, 0x00, 0x00 }, buf.items);
}

test "encodeCommitString writes header and string payload" {
    var buf: std.ArrayList(u8) = .empty;
    defer buf.deinit(std.testing.allocator);
    try encodeCommitString(std.testing.allocator, &buf, 5, "hi");
    try std.testing.expectEqualSlices(u8, &.{
        0x05, 0x00, 0x00, 0x00, 0x00, 0x00, 0x10, 0x00, // object 5, size 16, opcode 0
        0x03, 0x00, 0x00, 0x00, 'h',  'i',  0x00, 0x00,
    }, buf.items);
}

test "encodeCommit writes serial argument" {
    var buf: std.ArrayList(u8) = .empty;
    defer buf.deinit(std.testing.allocator);
    try encodeCommit(std.testing.allocator, &buf, 5, 3);
    try std.testing.expectEqualSlices(u8, &.{
        0x05, 0x00, 0x00, 0x00, 0x03, 0x00, 0x0c, 0x00, 0x03, 0x00, 0x00, 0x00,
    }, buf.items);
}

test "extractMessage waits for the complete message" {
    var buf: std.ArrayList(u8) = .empty;
    defer buf.deinit(std.testing.allocator);
    try appendMessage(std.testing.allocator, &buf, 5, 3, &.{ 0x03, 0x00, 0x00, 0x00 });
    try buf.replaceRange(std.testing.allocator, 8, buf.items.len - 8, &.{}); // 只留前 8 字节 header
    try std.testing.expect(extractMessage(&buf) == null);
    try buf.appendSlice(std.testing.allocator, &.{ 0x03, 0x00, 0x00, 0x00 });
    const message = extractMessage(&buf).?;
    try std.testing.expectEqual(@as(u32, 5), message.object_id);
    try std.testing.expectEqual(@as(u16, 3), message.opcode);
    try std.testing.expectEqual(@as(u32, 3), readU32(message.payload).?);
}

test "readString returns unterminated-safe slices" {
    var offset: usize = 0;
    const payload = [_]u8{ 0x08, 0x00, 0x00, 0x00, 'w', 'l', '_', 's', 'e', 'a', 't', 0x00 };
    try std.testing.expectEqualStrings("wl_seat", readString(&payload, &offset).?);
    try std.testing.expectEqual(@as(usize, 12), offset);
    const truncated = [_]u8{ 0x08, 0x00, 0x00, 0x00, 'w', 'l' };
    offset = 0;
    try std.testing.expect(readString(&truncated, &offset) == null);
}
```

- [ ] **Step 2: 运行确认失败**

Run: `zig build test`
Expected: 编译失败（`appendString` / `extractMessage` 等未定义）

- [ ] **Step 3: 实现编解码**

用现有 `std.ArrayList(u8)` 风格实现。`appendMessage` 写 header：object id（u32 LE）、`(size << 16) | opcode`（size = 8 + payload.len，必须 4 字节对齐）。`extractMessage` 只读不消费，校验 `size >= 8`、`size % 4 == 0`、`size <= buf.items.len`。`consumeMessage` 用 `std.mem.copyForwards` 压缩后再 `buf.items.len -= total_size`。

- [ ] **Step 4: 运行确认通过**

Run: `zig build test`
Expected: PASS（含既有测试）

- [ ] **Step 5: Commit**

```bash
git add src/runtime/wayland_im.zig src/root.zig
git commit -m "feat: add wayland wire codec"
```

---

### Task 2: IM 事件状态机

**Files:**
- Modify: `src/runtime/wayland_im.zig`

**Interfaces:**
- Consumes: Task 1 的 `readU32` / `readString`。
- Produces:
  - `pub const Client = struct { allocator, io, stream: std.Io.net.Stream, mutex: std.Io.Mutex = .init, next_id: u32 = 2, registry_id: u32 = 0, callback_id: u32 = 0, seat_id: u32 = 0, manager_id: u32 = 0, im_id: u32 = 0, seat_global_name: u32 = 0, manager_global_name: u32 = 0, done_count: u32 = 0, active: bool = false, pending_active: bool = false, sync_done: bool = false, dead: bool = false, read_buf: std.ArrayList(u8) = .empty }`
  - `pub fn allocId(client: *Client) u32`（返回当前 `next_id` 后自增，只在 setup 单线程使用）
  - `pub fn applyMessage(client: *Client, object_id: u32, opcode: u16, payload: []const u8) !void`（持 `mutex` 修改状态；`wl_display.error` 置 `dead` 并返回 `error.DisplayError`）
  - `pub fn isActive(client: *Client) bool`（持锁读 `active`）

事件分派表（object/opcode）：

| object | opcode | 行为 |
| --- | --- | --- |
| 1 (wl_display) | 0 | `dead = true; return error.DisplayError` |
| 1 | 1 (delete_id) | 忽略 |
| `registry_id` | 0 | 读 name + interface；`"wl_seat"` → `seat_global_name`，`"zwp_input_method_manager_v2"` → `manager_global_name` |
| `registry_id` | 1 | 忽略 |
| `callback_id` | 0 | `sync_done = true` |
| `seat_id` | 任意 | 忽略 |
| `im_id` | 0 / 1 | `pending_active = true` / `false` |
| `im_id` | 2 / 3 / 4 | 忽略 |
| `im_id` | 5 (done) | `done_count += 1; active = pending_active` |
| `im_id` | 6 (unavailable) | `dead = true` |
| 其它 | 任意 | 忽略 |

- [ ] **Step 1: 写失败测试**

```zig
fn testClient() Client {
    return .{
        .allocator = std.testing.allocator,
        .io = std.testing.io,
        .stream = undefined,
        .registry_id = 2,
        .callback_id = 3,
        .seat_id = 4,
        .manager_id = 5,
        .im_id = 6,
    };
}

test "done events advance serial and apply pending active state" {
    var client = testClient();
    try client.applyMessage(6, 0, &.{}); // activate
    try std.testing.expect(!client.isActive());
    try client.applyMessage(6, 5, &.{}); // done
    try std.testing.expect(client.isActive());
    try std.testing.expectEqual(@as(u32, 1), client.done_count);
    try client.applyMessage(6, 1, &.{}); // deactivate
    try client.applyMessage(6, 5, &.{}); // done
    try std.testing.expect(!client.isActive());
    try std.testing.expectEqual(@as(u32, 2), client.done_count);
}

test "unavailable marks client dead" {
    var client = testClient();
    try client.applyMessage(6, 6, &.{});
    try std.testing.expect(client.dead);
}

test "display error is reported and marks dead" {
    var client = testClient();
    const payload = [_]u8{ 0, 0, 0, 0, 1, 0, 0, 0, 5, 0, 0, 0, 'o', 'o', 'p', 's', 0, 0, 0, 0 };
    try std.testing.expectError(error.DisplayError, client.applyMessage(1, 0, &payload));
    try std.testing.expect(client.dead);
}

test "registry globals record seat and manager names" {
    var client = testClient();
    var payload: std.ArrayList(u8) = .empty;
    defer payload.deinit(std.testing.allocator);
    try payload.appendSlice(std.testing.allocator, &.{ 40, 0, 0, 0 });
    try appendString(std.testing.allocator, &payload, "wl_seat");
    try payload.appendSlice(std.testing.allocator, &.{ 9, 0, 0, 0 });
    try client.applyMessage(2, 0, payload.items);
    try std.testing.expectEqual(@as(u32, 40), client.seat_global_name);
    payload.clearRetainingCapacity();
    try payload.appendSlice(std.testing.allocator, &.{ 24, 0, 0, 0 });
    try appendString(std.testing.allocator, &payload, "zwp_input_method_manager_v2");
    try payload.appendSlice(std.testing.allocator, &.{ 1, 0, 0, 0 });
    try client.applyMessage(2, 0, payload.items);
    try std.testing.expectEqual(@as(u32, 24), client.manager_global_name);
}

test "identifiers are allocated strictly sequentially" {
    var client = testClient();
    try std.testing.expectEqual(@as(u32, 2), client.allocId());
    try std.testing.expectEqual(@as(u32, 3), client.allocId());
    try std.testing.expectEqual(@as(u32, 6), client.allocId());
}
```

形态不确定的字符串拼接允许改写为等价的显式字节数组，但断言值必须保持。

- [ ] **Step 2: 运行确认失败**

Run: `zig build test`
Expected: 编译失败（`Client` / `applyMessage` 未定义）

- [ ] **Step 3: 实现 Client 与分派表**

`applyMessage` 在修改字段前 `lockUncancelable`、`defer unlock`；`isActive` 同样持锁。`allocId` 不加锁（仅 setup 单线程调用）。

- [ ] **Step 4: 运行确认通过**

Run: `zig build test`
Expected: PASS

- [ ] **Step 5: Commit**

```bash
git add src/runtime/wayland_im.zig
git commit -m "feat: add wayland input method state machine"
```

---

### Task 3: 连接与 setup

**Files:**
- Modify: `src/runtime/wayland_im.zig`

**Interfaces:**
- Consumes: Task 2 的 `Client`/`applyMessage`，Task 1 的 `appendMessage`/`appendString`/`extractMessage`/`consumeMessage`。
- Produces:
  - `pub const listen_display_default = "wayland-0";`
  - `pub const setup_timeout_ms: i64 = 2000;`
  - `pub const unavailable_probe_ms: i64 = 200;`
  - `pub const ConnectError = error{ MissingRuntimeDir, ConnectionFailed, InputMethodUnavailable, SetupTimeout, DisplayError };`
  - `pub fn resolveSocketPath(allocator: std.mem.Allocator, environ: std.process.Environ) ConnectError![]u8`
  - `pub fn connect(allocator: std.mem.Allocator, io: std.Io, environ: std.process.Environ) ConnectError!*Client`
  - `pub fn pump(client: *Client, timeout_ms: i32) !void`
  - `pub fn deinit(client: *Client) void`

setup 顺序（object id 必须按此顺序，全部经 `allocId()`）：`registry=2`，发 `wl_display.get_registry`（object 1, opcode 1）；`callback=3`，发 `wl_display.sync`（object 1, opcode 0）；pump 直到 `sync_done`（每轮 `pump(10)`，累计 > `setup_timeout_ms` → `error.SetupTimeout`）；缺任一 global → `error.InputMethodUnavailable`；`seat=4`，发 `registry.bind(seat_global_name, "wl_seat", 1)`；`manager=5`，发 `registry.bind(manager_global_name, "zwp_input_method_manager_v2", 1)`；`im=6`，发 `manager.get_input_method(seat_id)`。随后最多 `unavailable_probe_ms` 内 pump：`dead` → `error.InputMethodUnavailable`，无事件则视为绑定成功继续。

`pump`：`std.posix.poll` 一个 `POLL.IN` 的 fd（`client.stream.socket.handle`）；可读时循环 `std.posix.system.read` 追加进 `read_buf`，`EAGAIN` 结束，`0`/其它错误 → `dead = true; return error.ConnectionFailed`；然后 `extractMessage` + `applyMessage` + `consumeMessage` 直到取空。

- [ ] **Step 1: 写失败测试**

```zig
test "resolves socket path from runtime dir and display" {
    var env_map = std.process.Environ.Map.init(std.testing.allocator);
    defer env_map.deinit();
    try env_map.put("XDG_RUNTIME_DIR", "/run/user/1000");
    try env_map.put("WAYLAND_DISPLAY", "wayland-1");
    const block = try env_map.createPosixBlock(std.testing.allocator, .{});
    defer block.deinit(std.testing.allocator);
    const path = try resolveSocketPath(std.testing.allocator, .{ .block = block });
    defer std.testing.allocator.free(path);
    try std.testing.expectEqualStrings("/run/user/1000/wayland-1", path);
}

test "absolute wayland display path wins over runtime dir" {
    // WAYLAND_DISPLAY=/tmp/wayland-test 且 XDG_RUNTIME_DIR 缺失
    // 期望返回 "/tmp/wayland-test"
}

test "missing runtime dir fails" {
    // 无 XDG_RUNTIME_DIR 且 WAYLAND_DISPLAY 为非绝对路径
    // expectError(error.MissingRuntimeDir, resolveSocketPath(...))
}

test "default display name is used when unset" {
    // 只有 XDG_RUNTIME_DIR；期望 "<runtime>/wayland-0"
}
```

（Environ.Map / createPosixBlock 用法照 `src/runtime/ibus.zig` 的既有测试。）

- [ ] **Step 2: 运行确认失败**

Run: `zig build test`
Expected: 编译失败（`resolveSocketPath` 未定义）

- [ ] **Step 3: 实现路径解析与 setup**

`resolveSocketPath`：`WAYLAND_DISPLAY` 以 `/` 开头直接返回拷贝；否则 `XDG_RUNTIME_DIR` 缺失 → `error.MissingRuntimeDir`，否则 `"{runtime}/{display orelse listen_display_default}"`。`connect` 用 `std.Io.net.UnixAddress.init(path)` + `.connect(io)`，失败映射 `error.ConnectionFailed`；所有失败路径 errdefer 关闭 stream、释放 `read_buf`、`destroy(client)`。`deinit` 在未 dead 时发送 `im.destroy`（object `im_id`, opcode 6）+ `manager.destroy`（object `manager_id`, opcode 1），然后 `stream.close(io)`、释放 `read_buf`、`destroy`。

- [ ] **Step 4: 运行确认通过**

Run: `zig build test && zig build`
Expected: PASS，构建成功

- [ ] **Step 5: Commit**

```bash
git add src/runtime/wayland_im.zig
git commit -m "feat: connect to wayland input method protocol"
```

---

### Task 4: 提交路径

**Files:**
- Modify: `src/runtime/wayland_im.zig`

**Interfaces:**
- Consumes: Task 1/2/3 的编解码、`Client`、`max_commit_bytes`。
- Produces:
  - `pub fn nextChunk(text: []const u8, start: usize) []const u8`
  - `pub fn buildCommitMessages(allocator: std.mem.Allocator, im_id: u32, serial: u32, text: []const u8) ![]u8`
  - `pub fn commit(client: *Client, text: []const u8) []const u8`

`commit` 判定顺序：空白文本 → `"ERR empty_response"`；持锁后 `dead` → `"ERR wayland_unavailable"`；`!active` → `"ERR no_text_input"`；否则 `buildCommitMessages` → 一次 `writeAll`（`std.posix.system.write`，处理部分写与 `EINTR`）→ 写失败置 `dead` 返回 `"ERR wayland_unavailable"`，成功返回 `"OK committed"`。

`nextChunk`：`end = min(start + max_commit_bytes, text.len)`；若 `end < text.len` 则当 `(text[end] & 0xC0) == 0x80` 时向前回退到非 UTF-8 续字节。

- [ ] **Step 1: 写失败测试**

```zig
test "nextChunk does not split utf8 characters" {
    const text = ("a" ** 3999) ++ "你" ++ "b";
    const first = nextChunk(text, 0);
    try std.testing.expectEqual(@as(usize, 3999), first.len);
    const second = nextChunk(text, first.len);
    try std.testing.expectEqualStrings("你b", second);
    try std.testing.expectEqual(@as(usize, text.len), first.len + second.len);
}

test "nextChunk keeps exactly 4000 bytes as one chunk" {
    const text = "a" ** 4000;
    try std.testing.expectEqual(@as(usize, 4000), nextChunk(text, 0).len);
}

test "buildCommitMessages emits commit_string plus commit per chunk" {
    const bytes = try buildCommitMessages(std.testing.allocator, 5, 3, "hi");
    defer std.testing.allocator.free(bytes);
    try std.testing.expectEqualSlices(u8, &.{
        0x05, 0x00, 0x00, 0x00, 0x00, 0x00, 0x10, 0x00, 0x03, 0x00, 0x00, 0x00, 'h', 'i', 0x00, 0x00,
        0x05, 0x00, 0x00, 0x00, 0x03, 0x00, 0x0c, 0x00, 0x03, 0x00, 0x00, 0x00,
    }, bytes);
}

test "commit rejects empty and inactive states" {
    var client = testClient();
    try std.testing.expectEqualStrings("ERR empty_response", client.commit("   "));
    try std.testing.expectEqualStrings("ERR no_text_input", client.commit("hi"));
    client.dead = true;
    try std.testing.expectEqualStrings("ERR wayland_unavailable", client.commit("hi"));
}
```

- [ ] **Step 2: 运行确认失败**

Run: `zig build test`
Expected: 编译失败（`nextChunk` / `buildCommitMessages` / `commit` 未定义）

- [ ] **Step 3: 实现提交路径**

`buildCommitMessages` 用局部 `std.ArrayList(u8)` 逐段 `encodeCommitString` + `encodeCommit`，返回 `toOwnedSlice`。

- [ ] **Step 4: 运行确认通过**

Run: `zig build test`
Expected: PASS

- [ ] **Step 5: Commit**

```bash
git add src/runtime/wayland_im.zig
git commit -m "feat: commit text through wayland input method"
```

---

### Task 5: postprocess 抽象 CommitBackend

**Files:**
- Modify: `src/runtime/postprocess.zig`
- Modify: `src/runtime/app.zig`（仅调用点：`Pipeline.start(..., .{ .ibus = service }, ...)`）

**Interfaces:**
- Consumes: `wayland_im.Client.commit`。
- Produces:
  - `pub const CommitBackend = union(enum) { ibus: *ibus.gio_ibus.Service, wayland: *wayland_im.Client };`
  - `CommitBackend.commit(text: []const u8) []const u8`（转发 `commitStatus` / `commit`）
  - `CommitBackend.domain() []const u8`（`"ibus"` / `"wayland"`）
  - `Pipeline.start(allocator, io, logger, backend: CommitBackend, cfg: *const config.Config, provider: []const u8) !*Pipeline`；`Pipeline` 字段 `service` 改名 `backend`

- [ ] **Step 1: 写失败测试**

```zig
test "commit backend reports provider domain" {
    try std.testing.expectEqualStrings("ibus", (CommitBackend{ .ibus = undefined }).domain());
    try std.testing.expectEqualStrings("wayland", (CommitBackend{ .wayland = undefined }).domain());
}
```

- [ ] **Step 2: 运行确认失败**

Run: `zig build test`
Expected: 编译失败（`CommitBackend` 未定义）

- [ ] **Step 3: 实现抽象并更新调用点**

`commitWorker` 改为 `ctx.backend.commit(text)` / `ctx.backend.domain()`；日志格式与 `"OK "` 判定不变。`app.zig` 只把现有 `service` 参数包成 `. { .ibus = service }`，保持可编译。

- [ ] **Step 4: 运行确认通过**

Run: `zig build test && zig build`
Expected: PASS，构建成功

- [ ] **Step 5: Commit**

```bash
git add src/runtime/postprocess.zig src/runtime/app.zig
git commit -m "refactor: abstract commit backend in pipeline"
```

---

### Task 6: CLI flag

**Files:**
- Modify: `src/cli.zig`

**Interfaces:**
- Produces: `pub const WaylandMode = enum { auto, force, disabled };`；`Options` 新增 `wayland: WaylandMode = .auto`。
- 解析规则：`--wayland` → `.force`；否则 `--no-wayland` → `.disabled`；否则 `.auto`（两者同现时 `--wayland` 优先）。

- [ ] **Step 1: 写失败测试**

```zig
test "defaults to auto wayland selection" {
    const args = [_][:0]const u8{"asr"};
    try std.testing.expectEqual(WaylandMode.auto, optionsFromArgs(&args).wayland);
}

test "recognizes wayland flags" {
    const force = [_][:0]const u8{ "asr", "--wayland" };
    try std.testing.expectEqual(WaylandMode.force, optionsFromArgs(&force).wayland);
    const disabled = [_][:0]const u8{ "asr", "--no-wayland" };
    try std.testing.expectEqual(WaylandMode.disabled, optionsFromArgs(&disabled).wayland);
    const both = [_][:0]const u8{ "asr", "--wayland", "--no-wayland" };
    try std.testing.expectEqual(WaylandMode.force, optionsFromArgs(&both).wayland);
}
```

- [ ] **Step 2: 运行确认失败**

Run: `zig build test`
Expected: 编译失败（`WaylandMode` 未定义）

- [ ] **Step 3: 实现 flag 解析**

- [ ] **Step 4: 运行确认通过**

Run: `zig build test`
Expected: PASS

- [ ] **Step 5: Commit**

```bash
git add src/cli.zig
git commit -m "feat: add wayland backend selection flags"
```

---

### Task 7: app 启动选择与事件循环

**Files:**
- Modify: `src/runtime/app.zig`
- Modify: `src/main.zig`（app 模式传 `opts.wayland`）

**Interfaces:**
- Consumes: `wayland_im.connect` / `pump` / `deinit`，`postprocess.CommitBackend`，`cli.WaylandMode`。
- Produces:
  - `pub fn run(allocator, io, environ, debug: bool, engine_kind: engine.Kind, wayland: cli.WaylandMode) !void`
  - `const WaylandLoop = struct { client: *wayland_im.Client, io: std.Io, logger: output.Logger, running: std.atomic.Value(bool) };`
  - `fn runWaylandLoop(loop: *WaylandLoop) void`（`while running and !shutdown: client.pump(0) catch 记录并 return; shutdown.sleepUntilOr(io, 10)`）
  - `fn startIbusBackend(allocator, io, environ, logger) !*ibus.gio_ibus.Service`（现有 `initRuntime` + `startService` 原样搬入）

启动顺序：后端选择（`wayland == .disabled` → IBus；否则 `connect`，失败时 `.force` 直接返回、`.auto` 记录 `wayland unavailable: …; falling back to IBus` 后走 IBus）→ `Pipeline.start(..., backend, ...)` → 启动对应循环线程（沿用 `io.concurrent`，失败则 `std.Thread.spawn`；两个循环与 service/client 指针都声明在函数作用域，`running` 初值 false，defer 统一 cancel/join，`client.deinit()` 与 `service.stop()+destroy` 同样 defer）→ 仅 IBus 路径执行 `switchToAsrInputMethod` + `waitForServiceReady`（原逻辑不变）→ `runHotkeyLoop`。

- [ ] **Step 1: 实现后端选择与事件循环**

无新增单测；`zig build test` 只保证既有测试不回归。

- [ ] **Step 2: 运行确认编译通过**

Run: `zig build test && zig build`
Expected: PASS，构建成功

- [ ] **Step 3: 手动冒烟（有 niri 会话时）**

Run: `./zig-out/bin/asr --debug`（数秒后 Ctrl+C）
Expected: 日志出现 `[wayland] input method bound`，无 `wayland unavailable`；Ctrl+C 干净退出。若出现回退日志，记录原始错误并停止，回到设计确认。

- [ ] **Step 4: Commit**

```bash
git add src/runtime/app.zig src/main.zig
git commit -m "feat: select wayland input method backend at startup"
```

---

### Task 8: README 与端到端验证

**Files:**
- Modify: `README.md`

**Interfaces:**
- 无代码接口；记录 Wayland 使用方式与覆盖限制。

- [ ] **Step 1: 更新 README**

在"运行模式"附近新增 Wayland 说明：自动选择条件（`WAYLAND_DISPLAY` 且合成器提供 `zwp_input_method_manager_v2`）；`--wayland` / `--no-wayland`；仅支持 `zwp_text_input_v3` 的应用（GTK4/Qt6；Chrome 需 `--enable-wayland-ime` 或新版本默认支持；XWayland 不支持）；一个 seat 同时只能有一个 IM，与 fcitx5 等互斥；`--debug` 下 `ERR no_text_input` 的含义。同步修正文首"Ubuntu 26.04 + IBus"依赖描述为 IBus 或 Wayland IME 环境。

- [ ] **Step 2: 全量验证**

Run: `zig build test && zig build`
Expected: PASS，构建成功

- [ ] **Step 3: 手动端到端**

Run: `./zig-out/bin/asr --debug`
Expected:
- Ghostty（GTK4）中按住 RightAlt 说话，最终文本出现在输入位置；日志 `[kbd] down/up RightAlt`、`[wayland] ✅`。
- Chrome 中重复一次，记录实际结果：成功则文本出现；不支持则 `[wayland] ❌ ERR no_text_input` 且不误提交。
- 断开/退出场景：退出进程时无 panic。

- [ ] **Step 4: Commit**

```bash
git add README.md
git commit -m "docs: document wayland input method backend"
```
