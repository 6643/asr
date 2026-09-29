# 计划：架构/内存审计后的修复（2026-09-29）

来源：本次审计报告（架构与内存审计）里的"建议"清单，用户指令「fix all」。审计结论：无真实内存泄漏；本计划修的是**契约成文**与几个 P3 级可改项。

## Global Constraints

- T1/T4/T5 是纯注释或等价改写：日志文本、`pub` 面、行为逐字不变。
- T2 只改 `--once-pcm` 失败时的**输出形式**（一行 `asr: <ErrorName>`），退出码保持 1；成功路径输出与退出码不变。
- T3 是唯一新增行为：文本队列加上限，溢出丢**最旧**并记 err 日志。
- 不新增依赖；`git add` 只写具体路径；提交前缀 `fix:` / `feat:` / `refactor:` / `docs:`。
- 每任务收尾：`zig build test --summary all` 与 `zig build` 均成功（`task-done` 传 `zig build check --summary all`）。
- 真机验证：`--baidu --once-pcm`（远端错误路径）应打一行并 exit 1；`--once-pcm`（Doubao 静音）仍 exit 0。

## 任务

### Task 1: 把回调生命周期与 Select arm 规则写成不变量

- **Files**：`src/runtime/capture.zig`（文件头契约注释）、`src/runtime/app.zig`（`runHotkeyLoop` 里引用契约）、`src/runtime/keyboard.zig`（`readNextOrShutdown` 的 arm 规则）。
- **内容**：①capture.zig 顶部写明：`CaptureStartedState`/`StreamCaptureState`/`EngineCallbacks` 都是在一次录音的栈帧内构造，所有 `?*anyopaque` ctx 只在该录音内有效；任何 future/thread（提示音、会话建立、会话读线程）必须在本次迭代结束前 await/cancel/join 完毕。②app.zig 在创建这些结构处引用该契约。③keyboard.zig 的 `readNextOrShutdown` 写明三条 arm 规则：每次 return 前 `cancelDiscard`；被忽略/中断的 arm 必须重投递；录音归属由 `endRecording` 结束（release 被采集循环消费）。
- **提交**：`docs: spell out the callback and select arm invariants`

### Task 2: `--once-pcm` 失败只打一行

- **Files**：`src/main.zig`
- **Steps**：把 `.once_pcm` 分支的函数体整段搬进 `fn runOncePcm(allocator, io, opts, pcm_path, stdout) !void`（纯搬移，不改逻辑）；分支处 `runOncePcm(...) catch |err| { std.debug.print("asr: {s}\n", .{@errorName(err)}); std.process.exit(1); }`，与 `.app` 分支一致。
- **验证**：`--baidu --once-pcm /tmp/silence.pcm` → 一行 `asr: RemoteAsrError`、exit 1；`--once-pcm`（Doubao）→ exit 0。
- **提交**：`fix: report once pcm failures on one line`

### Task 3: 给文本队列加上限（TDD）

- **Files**：`src/runtime/postprocess.zig`
- **Steps**：① 先写失败测试：连续入队 `max_pending_texts + 6` 条，断言队列里最旧的那几条已被丢弃、保留最新 `max_pending_texts` 条且顺序正确；② 实现：`pub const max_pending_texts: usize = 64;`，`enqueueDup` 在超出时弹出并释放最旧的一条并记 err 日志（`queue full; dropping oldest`）；③ 让测试与既有 158 条测试全绿。
- **提交**：`feat: cap the postprocess text queues`

### Task 4: 让日志模块不再依赖 `key.Event`

- **Files**：`src/runtime/output.zig`
- **Steps**：删除 `@import("../key.zig")`，在 output.zig 内定义 `pub const KeyEvent = enum { press, release };`，`keyEvent` 改用它。调用点传的都是 `.press`/`.release` 字面量，无需改动。
- **提交**：`refactor: drop the key dependency from the logger`

### Task 5: 删除零引用符号

- **Files**：`src/key.zig`（`findKeyboardDevice`、`waitForDeviceRelease`、`waitNextDeviceEventOrShutdown`）、`src/runtime/shutdown.zig`（`sleepMs`）、`src/config.zig`（`AudioParams`）。
- **Steps**：逐个确认零引用（含测试）后删除；`zig build` 必须仍成功（exe 构建会做惰性分析）。
- **提交**：`refactor: delete unreferenced helpers`

### Task 6: 收尾验证与同步

- **Steps**：`zig build check`；`zig build`；真机冒烟一轮（自动发现两把键盘 + 一次 FIFO 触发 + 一次 `--once-pcm` 错误路径）；README 无需改动（本批无用户可见行为变化，除 once-pcm 报错更短）；`git push origin main` 并确认 CI 通过；ledger 收尾。
- **提交**：无（或如有文档改动则 `docs: …`）

## Self-Review（审计建议 → 任务）

| 审计建议 | 任务 |
|---|---|
| P2 回调 ctx 生命周期成文 | T1 |
| P2 Select arm 规则成文 | T1 |
| P3 once-pcm 单行报错 | T2 |
| P3 TextQueue 上限 | T3 |
| P3 output.zig 反向依赖 | T4 |
| P3 零引用符号清理 | T5 |

不修（有意）：`orderedRemove(0)` 的 O(n)（上限落地后 n ≤ 64，代价可忽略）、并发 fuzz、websocket 内部审计（属盲区声明，不在本批范围）。
