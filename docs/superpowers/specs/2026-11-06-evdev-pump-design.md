# evdev 读泵设计（把 ENODEV 挡在 std.Io 之外）

## 目标

拔掉/休眠中的键盘返回 `ENODEV` 时，不再触发 Zig `std.Io` 的 `unexpectedErrno`（Debug 构建会打 25 行栈回溯、约 194ms/次），同时**保留** daemon 全局的 unexpected-errno 栈回溯诊断（撤销 `src/main.zig` 里临时加的 `unexpected_error_tracing = false`）。

## 现状与根因

- 事实：`src/runtime/keyboard.zig` 的 `deviceArmTask` 直接对 evdev 做 `std.Io.File.readStreaming`；内核 `evdev_read` 在设备被吊销后返回 `-ENODEV`。
- 事实：`std.Io.Threaded.fileReadStreamingPosix` 的 errno 表里没有 ENODEV，落到 `else => syscall.unexpectedErrno`（`std/Io/Threaded.zig:9977`），该函数在 `std.options.unexpected_error_tracing` 为真时打印 errno 并 `dumpCurrentStackTrace`（`std/posix.zig:1672`）。
- 事实：该开关只在 Debug 默认开启（`std/std.zig:195`），所以 Release 无此现象；但 Debug 是当前日常使用的构建。
- 事实：读取必须是可取消的（`Select.cancelDiscard` 会阻塞到所有臂结束，`std/Io.zig:1659`），而 `std.Io` 只提供 `file_read_streaming` 这类可取消的 fd 读，没有「可取消的 poll/epoll」。因此**不能**用裸 syscall 在 `Select` 臂里替换读操作，否则取消会挂死。

## 方案

每条设备加一个「泵」线程：阻塞读 evdev 的事搬到 `std.Io` 之外的普通线程，只用裸 syscall；泵把事件字节写进 pipe，`Select` 臂继续用 `readStreaming` 读 pipe（pipe 读到 0 字节是 std 能映射的 `error.EndOfStream`，不会 dump）。

```
evdev --poll+readv(裸 syscall, 自己判 ENODEV)--> pump 线程 --> pipe --> readStreaming(可取消) --> Select 臂 / 按住等待
```

被否掉的替代：

- 全局关掉诊断（已试，代价是全进程失去该诊断）。
- 臂里改用裸 `poll` + 非阻塞读：`Select.cancelDiscard` 无法打断裸 `poll`，会死锁；改成短超时轮询则给热键路径引入轮询延迟/空转（每设备 4~20 次/秒）。
- 单线程 epoll + 环形缓冲 + eventfd：能省线程，但要重写 `Select` 臂模型与缓冲并发，改动面远大于收益。

## 数据流与语义

1. `openAll` / `rescanAddsDevices`：打开 evdev → `pipe2(CLOEXEC)` → 写端设 `O_NONBLOCK` → `Pump.start(evdev_fd, pipe_write)`；`Device.file` = pipe 读端。
2. 泵线程（不碰 `std.Io`，不写日志）：`poll([evdev IN, stop IN])` → evdev 可读 → `readv` 最多 16 个事件 → 写 pipe（写满时 `poll([pipe OUT, stop IN])` 等待，可被 stop 打断）。evdev fd 在泵启动时设为 `O_NONBLOCK`：读永不阻塞（只有 `poll` 阻塞，而 stop 能打断它），并且 `POLLHUP/POLLERR` 之后补读一次可以区分「管道真 EOF（返回 0）」和「evdev 被吊销（ENODEV）」。pipe 容量尽力设成 4 KiB（`F.SETPIPE_SZ`，失败保持默认）。
3. 臂读 pipe：`readStreaming` 取消语义与现在完全一致；被取消时未读数据留在 pipe 里，不会丢。
4. 设备消失：泵看到 `POLLERR`/`POLLNVAL`/`POLLHUP` 或读返回 `ENODEV`/`ENXIO`/`EIO`/0 → 记录死因 → **关闭写端** → 关闭 evdev/stop → 线程退出。应用侧读到 EOF，且泵退出前写出的数据仍会先被读到（比现在「读失败即丢弃」更准）。
5. 死因：`Pump.death: std.atomic.Value(u8)`（`none / gone / end_of_stream / failed`），泵退出前 store(release)。Set 在 `error.EndOfStream` 之后 load(acquire) 细化日志：`gone → KeyboardDeviceDisconnected`、`failed → ReadFailed`、其余 `EndOfStream`。`DeviceReadError.KeyboardDeviceDisconnected` 由死代码变成实际使用的错误。注意：管道 EOF 本身是 `end_of_stream`，被吊销的 evdev 才会是 `gone`（靠 HUP/ERR 后的补读判定）。
6. `drainDevice` 不变，只是现在 drain 的是 pipe（原来是内核队列）：语义等价，都是「清掉非持有键盘的缓冲按键」。

## 生命周期与资源归属

- `Device{ path, file, pump: ?Pump, state, dead }`；`file` 永远是应用可读的那一端（pump 设备是 pipe 读端，`adopt` 的测试设备就是传入的 fd，`pump == null`）。
- 泵线程拥有：evdev fd、pipe 写端；在退出路径统一关闭。
- `stop_fd`（eventfd）归 `Pump` 结构即应用侧所有：`deinit` 写 1 后 join，再关闭它；泵线程只 poll 它。这样不会出现「向已关闭 fd 写」的竞态。
- Set 拥有：pipe 读端（`device.file`）、`Device.path`、`Pump` 句柄。
- `closeAll` / `killDevice`：先 `pump.stopAndJoin()`（写 eventfd + join，幂等），再关 `device.file`。**顺序不可颠倒**：读端不能先于 join 关闭。
- `stop` 用 `eventfd`（不是 pipe），因此不存在「向已关闭读端写」的 SIGPIPE 路径；数据 pipe 只有泵写、且读端只在 join 之后关闭，Zig 0.17 默认不忽略 SIGPIPE，这一点必须靠顺序保证。
- 泵线程用 `std.Thread` 默认栈（16 MiB 虚拟地址空间，RSS 仍是几 KiB）。不指定 `stack_size` 的原因：本机 glibc 2.44 + Zig 0.17 的 `pthread_create` 对显式小栈（64 KiB / 256 KiB 实测）返回 `EINVAL`，1 MiB 起才成功；泵只用几百字节栈，为这点差异去写死 1 MiB 没有意义。

## 错误处理

- `pipe2` / `eventfd` / `spawn` 失败：`add` 返回错误，设备跳过并记一行日志（与现在打不开设备同路径）；已建的 fd 全部关闭。
- 泵读 evdev：`INTR`/`EAGAIN` → 继续；其余 errno 按死因表处理；不向应用暴露 errno 细节，只暴露结尾的 EOF。
- 泵写 pipe：`EAGAIN` → 等 `POLLOUT` 或 stop；`EPIPE`（读端异常消失）→ 退出，不重试。
- 应用读 pipe 出错（非 EOF）：仍走现有 `mapReadStreamingError`。

## 不变约束

- 事件解析、按键语义（谁按谁松）、热键循环、重扫节奏、按住等待、录音/引擎/Wayland 链路均不改。
- 不引入第三方依赖，只用 `std.posix` / `std.os.linux` 裸 syscall 与现有 `std.Io`。
- 单元测试里的 `FakeDevice`（pipe 假键盘）路径不变。
- 撤销 `src/main.zig` 的 `unexpected_error_tracing = false`；README 对应说明改为描述泵。

## 验证

- 纯函数测试：`key.classifyPumpReadErrno` — `NODEV`/`NXIO` → `gone`，`INTR`/`AGAIN` → `keep`，`IO` → `failed`（ENODEV 无法在无 root 环境复现，必须靠这层测试锁住）。
- 线程测试（用 pipe 当假 evdev）：写入 2 个事件 → 应用侧依次读到；关闭假 evdev 写端 → 先读完残留事件再得到 `EndOfStream`，且 `death == .end_of_stream`。
- 线程测试：泵阻塞在 poll 时 `stopAndJoin` 能在毫秒级返回（不依赖设备事件）。
- 既有 175 个测试通过；`zig fmt --check` 通过。
- 手工（需真实键盘，本机 `/dev/uinput` 仅 root）：插拔一把键盘，预期只有一行 `[kbd] <path>: KeyboardDeviceDisconnected; removed`，无栈回溯；重新插入后 `[kbd] added <path>`。

## 风险与遗留

- 每条设备一个线程（上限 8）+ 64 KiB pipe 缓冲；空闲时无线程唤醒（阻塞在 `poll`），CPU 开销可忽略。
- 泵与 `endRecording` 的 drain 存在与现在同类的窗口：drain 之后才到的事件仍会开始新录音（现在也如此），不新增语义。
- 若未来有人在 `killDevice`/`closeAll` 之外关闭 `device.file`，会破坏 SIGPIPE 前提；由 `Device` 的注释与单一关闭入口约束。
- 死因原子量只用于日志细化，不参与控制流。
