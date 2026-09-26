# Wayland 输入法后端设计

## 目标

在 Wayland 平台上增加原生文本提交后端：ASR 进程作为 seat 的输入法绑定 `zwp_input_method_manager_v2`，最终识别文本通过 `commit_string` + `commit` 送入焦点文本输入，替代该平台上不可用的 IBus/DBus 提交链路。仅支持实现 `zwp_text_input_v3` 的应用（纯 IM 方案，不做 wtype 兜底）。

## 背景与现状

- 目标平台为 niri（Wayland/Smithay），环境中没有运行 ibus/fcitx，现有 `gio_ibus` 提交链路不可用。
- 已用一次性探针在 niri 26.04 上实测：registry 暴露 `zwp_input_method_manager_v2` v1 与 `zwp_text_input_manager_v3` v1；绑定 manager → `get_input_method(seat)` 成功，无 `unavailable`；观察到位 `activate` / `content_type` / `done` / `deactivate` 事件流。
- 实测硬约束：raw Wayland 客户端必须严格按 2、3、4、5… 顺序分配 object id，跳号会被合成器以 `invalid arguments` 断开连接。
- 协议事实（wlr `input-method-unstable-v2`，接口版本 1）：
  - `zwp_input_method_manager_v2`：`get_input_method(seat, id)`、`destroy()`。
  - `zwp_input_method_v2` 请求：`commit_string(s)`、`set_preedit_string(sii)`、`delete_surrounding_text(uu)`、`commit(u)`、`get_input_popup_surface(no)`、`grab_keyboard(n)`、`destroy()`。
  - 事件：`activate`、`deactivate`、`surrounding_text(suu)`、`text_change_cause(u)`、`content_type(uu)`、`done`、`unavailable`。
  - `commit(serial)` 的 `serial` 必须等于已收到的 `done` 事件数（收到第 1 个 `done` 后为 1，以此类推）；`commit_string` 单条上限 4000 字节。
  - `activate`/`deactivate` 是双缓冲状态，在紧随其后的 `done` 时生效；inactive 状态下请求被接受但不产生效果。
  - 本实现不调用 `grab_keyboard`、不创建 popup surface，因此不需要 xkbcommon、keymap 与 fd 传递。

## 不变约束

- 保留 IBus 路径，行为与代码不变；`--ibus`、`--ibus-xml`、`--once-pcm` 语义不变。
- 不新增第三方库或链接依赖；只使用 `std.posix`（AF_UNIX socket、非阻塞 read、poll）与现有 `std.Io`。
- 不改变快捷键读取（evdev）、录音、ASR、rectify、静音、提示音链路。
- 单次提交的所有 Wayland 消息合并为一次 `write`（互斥锁内），避免并发写入交错。
- Wayland 后端不处理 preedit、interim 文本、密码框过滤、多 seat、断线重连。

## 架构与组件边界

- 新增 `src/runtime/wayland_im.zig`：
  - `Client.connect(allocator, io, environ) !*Client`：解析 `WAYLAND_DISPLAY`（默认 `wayland-0`）与 `XDG_RUNTIME_DIR`，连接 AF_UNIX socket；`get_registry` + `sync`；在 2 秒内收集 globals（超时 → `error.SetupTimeout`）；缺少 `wl_seat` 或 `zwp_input_method_manager_v2` → `error.InputMethodUnavailable`。随后顺序绑定 seat（v1）与 manager（v1），`get_input_method(seat)`；随后最多 200ms 内 pump 事件以捕获立即到达的 `unavailable`（收到 → `error.InputMethodUnavailable`）；若期间无任何事件（超时）视为绑定成功并继续，后续事件由事件循环处理。
  - `dispatch() !void`：非阻塞读取并解析消息，处理 `wl_display.error`、`wl_display.delete_id`、registry/seat 事件（忽略）、`activate`/`deactivate`/`done`/`unavailable` 与其余 IM 事件（记录后忽略）。`done` 使 `done_count += 1` 并应用 pending 的 active 状态。
  - `commit(text) []const u8`：返回现有 `"OK …"` / `"ERR …"` 字符串。空白文本 → `ERR empty_response`；连接失效/`unavailable` → `ERR wayland_unavailable`；当前 inactive → `ERR no_text_input`；否则按 UTF-8 边界切分为 ≤4000 字节的分段，逐段发送 `commit_string` + `commit(done_count)`，写入失败（EPIPE/EOF）→ 标记失效并返回 `ERR wayland_unavailable`。
  - object id 由 `nextId()` 严格递增分配（从 2 开始），不跳号、不复用。
  - `Client` 持有 `write_mutex`（提交路径串行化）、`done_count`、`active`、`pending_active`、`dead`。
- 修改 `src/runtime/postprocess.zig`：`Pipeline` 的 `service: *gio_ibus.Service` 改为 `CommitBackend`：

  ```zig
  pub const CommitBackend = union(enum) {
      ibus: *gio_ibus.Service,
      wayland: *wayland_im.Client,
  };
  ```

  在同一文件内为 `CommitBackend` 提供 `commit(text) []const u8` 与 `domain() []const u8`（`"ibus"` / `"wayland"`）辅助方法；`commitWorker` 改用这两个方法，日志格式与 `OK`/`ERR` 判定逻辑不变。
- 修改 `src/runtime/app.zig`：启动时选择后端；Wayland 路径跳过 IBus 的 component XML 安装、daemon 拉起与 `ibus engine` 切换，也不需要 GIO 服务线程；启动 Wayland 事件循环线程（复制现有 `ServiceLoop` 模式：`dispatch()` + `shutdown.sleepUntilOr(10ms)`，退出时置 `running=false` 并 cancel/join）。
- 修改 `src/cli.zig`：新增 `--wayland`（强制）与 `--no-wayland`（禁用）；两者同时出现时 `--wayland` 优先。
- 修改 `src/root.zig` 导出 `runtime.wayland_im`；`build.zig` 不变。

## 数据流

1. 启动（app 模式）：
   - 若 `--no-wayland`：走 IBus 路径。
   - 否则若设置了 `WAYLAND_DISPLAY`（或 `--wayland` 强制，此时未设置也算失败）：尝试 `wayland_im.Client.connect`。
     - 成功：`CommitBackend = .{ .wayland = client }`，启动事件循环，记录 `wayland` 已绑定。
     - 失败且 `--wayland`：直接返回错误。
     - 失败且非强制：`warn` 记录原因，回退 IBus 路径。
   - 若未设置 `WAYLAND_DISPLAY` 且非强制：走 IBus 路径。
2. 事件循环：`dispatch()` 解析事件；`activate` / `deactivate` 置 pending 状态，`done` 时应用并递增 `done_count`；`activate`/`deactivate` 变化在 `debug` 级别记录。
3. 提交：rectify 后的最终文本进入现有 commit 队列，commit worker 调用 `backend.commit(text)`；Wayland 后端在 active 时立即写入 `commit_string + commit(done_count)` 并返回 `OK committed`，成功/失败沿用现有 `✅` / `❌` 日志。
4. 退出：`deinit` 发送 `im.destroy` + `manager.destroy`，关闭 socket。

## 错误处理

- 连接失败、缺少协议 global、registry 收集超时、立即 `unavailable`：`connect` 返回错误；非强制模式下回退 IBus，强制模式下进程报错退出。
- `wl_display.error` 或 socket EOF/EPIPE：标记 `dead`，事件循环记录一次错误后退出；后续提交返回 `ERR wayland_unavailable`。
- `unavailable` 事件：与 `dead` 同等处理。
- inactive 时提交：丢弃并向 commit 队列返回 `ERR no_text_input`，日志明确标注文本未送达。
- 超过 4000 字节的文本：按 UTF-8 边界切段提交，不产生截断的中间字符。

## 验证

- 单元测试（无需合成器）：
  - 消息编码：header 长度/opcode、string padding（长度 4n / 4n+1 / 4n+2 / 4n+3）、`commit` 的 serial 字段。
  - 事件解析：合成 `activate`/`content_type`/`done`/`deactivate`/`unavailable`/`wl_display.error` 字节流（含跨多次 read 的拆分），断言 `done_count`、active 状态与错误返回。
  - `commit` 决策：空文本 → `ERR empty_response`；inactive → `ERR no_text_input`；dead → `ERR wayland_unavailable`。
  - 分段：≤4000 字节单段；>4000 字节多段且不在多字节 UTF-8 字符中间切断。
  - `nextId()` 严格递增、不跳号。
- `zig build test`、`zig build` 通过。
- niri 手动验证：运行 `./zig-out/bin/asr --debug`，在支持 text-input-v3 的应用（GTK4/Qt6，如 Ghostty）中按住 RightAlt 说话，确认文本提交；观察 activate/deactivate 日志。再在 Chrome 中实测一次实际覆盖情况：提交成功则记录成功，不支持则确认得到 `ERR no_text_input` 且不误提交。
- README 增补 Wayland 使用说明（自动选择、两个 flag、text-input-v3 覆盖限制、与其它输入法互斥）。

## 非目标

- 不做 wtype / 虚拟键盘兜底。
- 不做 preedit 与 interim 实时显示、输入法弹窗、键盘 grab。
- 不做密码框/敏感内容过滤与 `content_type` 语义处理。
- 不做多 seat、断线重连、object id 复用。
