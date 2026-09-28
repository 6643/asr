# 单后端化与健壮性加固设计

## 目标

把 ASR 收敛为"只支持当前 PC 环境"：提交后端只有 Wayland 输入法（`zwp_input_method_manager_v2`），录音只有 PipeWire 的 `pw-record`；删掉上一平台（IBus + arecord）的全部代码与开关。同时落实代码审查中用户确认的健壮性改进项。

上一阶段（`2026-09-26-wayland-input-method-design.md`）保留了 IBus 路径并做自动回退，本设计把它删除。

## 背景与现状

- 现状：两套提交后端（Wayland IM 优先 / IBus 回退），两套录音器（`arecord` → `pw-record` 回退），CLI 有 `--ibus`、`--ibus-xml`、`--wayland`、`--no-wayland`、`WaylandMode`。
- 实际环境：umbriel 合成器（Wayland，支持 `zwp_input_method_manager_v2`）、PipeWire、没有 alsa-utils、没有 IBus。
- 代价：约 1,300 行死代码；一条"回退到不存在的 IBus → `error: FileNotFound` + Zig 调用栈退出"的失败路径（实测）；`CommitBackend` 联合体与 `WaylandMode` 都是为多后端存在的抽象。
- 另一类问题来自代码审查：Wayland IM 连接失效后会静默（日志打 ✅ 但合成器不再收字）、畸形消息会让客户端永久耳聋、`writeAll` 把 EAGAIN 当致命、录音中被强杀会把系统留在静音、键盘权限问题被报成"找不到键盘"、空采集静默通过、`finish` 超时可能丢尾句。

## 用户决定（固定本次范围）

1. 凭证继续写在 `config/doubao.json`，**不**迁移到 XDG state，不视为机密 → 审查项 P1-4 撤销。
2. 提交失败**不做**兜底（不写剪贴板、不发通知），只记日志 → 审查项 P1-2 撤销。
3. 录音期间静音**保留**（外放会被麦克风收进去）→ 仅新增"崩溃/被强杀后恢复静音"。审查项 P1-3 收窄为此。
4. 删除上一平台代码：IBus 全部、`arecord` 路径；只支持当前 PC 环境。
5. 保留：`doubao`/`baidu` 两个识别引擎、`--once-pcm`、`pw-record`、`wpctl`、`pw-play`、`curl`（凭证刷新与纠错）。

## 目标架构

```
main.zig ─ cli.Options
   └── runtime/app.zig            热键循环 + 一轮听写编排
        ├── key.zig               evdev 按下/松手（权限诊断、最大按住时长）
        ├── mic.zig               pw-record 采流 → 分块
        │    └── recorder.zig     只有 pw-record
        ├── engine.zig            doubao / baidu 会话
        └── postprocess.zig       纠错（可选）→ 提交
             └── wayland_im.Client   唯一提交后端
```

- 提交后端只有一个：`wayland_im.Client`；`postprocess.CommitBackend` 联合体删除。
- 启动：`WAYLAND_DISPLAY` 缺失或 IM 绑定失败 → **一行 `ERR ...` + 非零退出**，不再回退。
- 运行中：IM 连接失效 → 一行错误 + 非零退出；不允许"提交成功但合成器收不到"的静默状态。
- CLI 最终形态：`--doubao`（默认）/`--baidu`、`--debug`、`--once-pcm <path>`、`--help`，新增 `--no-rectify`、`--max-hold-ms <n>`、`--log-file <path>`。

## 删除清单

| 文件/内容 | 规模 | 说明 |
|---|---|---|
| `src/runtime/ibus.zig` | 162 行 / 1 测试 | 组件安装、`ibus-daemon` 拉起、输入法切换 |
| `src/runtime/gio_ibus.zig` | 525 行 / 4 测试 | IBus D-Bus 引擎（旧 `commitStatus` 提交路径） |
| `src/runtime/gio_dbus.zig` | 597 行 / 2 测试 | 仅被 gio_ibus 使用 |
| `src/install.zig` + `build.zig` 的 `install-ibus` 步骤与 `asr-install` 可执行文件 | 10 行 | 安装 IBus component XML |
| `recorder.Kind.arecord`、候选链、`spawnFirstWith`/`SpawnFn`/`Spawned`、`-D` 设备映射 | `recorder.zig` 约 60 行 / 3~4 测试 | 只留 `pw-record` |
| `CaptureOptions.device` | 3 处 | 无任何 CLI/config 填充的死字段 |
| CLI：`--ibus`、`--ibus-xml`、`--wayland`、`--no-wayland`、`cli.WaylandMode`、`Mode.ibus_*` | `cli.zig` 约 15 行 / 4 测试 | 单后端后失去意义 |
| `postprocess.CommitBackend` 联合体 | `postprocess.zig` 约 20 行 / 1 测试 | 单后端后是死重量 |
| `app.zig` 的 `startIbusBackend`、`ServiceLoop`、`service`/`service_loop`、`switchToAsrInputMethod`、`waitForServiceReady`、回退分支 | 约 100 行 | 同时删掉 `wayland` 参数与选择逻辑 |
| README 的 IBus/arecord 段落 | 11 处命中 | 依赖改写为 Wayland IM + PipeWire |

## 健壮性需求

| 编号 | 现状 | 期望 | 验收 |
|---|---|---|---|
| R1（P1-1） | `pump` 失败/EOF 时不置 `dead`；`WaylandLoop` 只记一行就退出线程；此后 `commit()` 仍可能返回 `OK committed` | 任何 pump 失败都置 `dead`；编排层发现后端死亡 → 一行 `ERR wayland_im_disconnected` → 非零退出（不做重连） | 单测：pump 读到 EOF / poll 失败后 `client.dead == true`、`commit()` 返回 `ERR wayland_unavailable`；真机：`kill` 合成器 IM 后进程退出非零 |
| R2（P2-4） | 非法头（`size < 8` 或非 4 对齐）→ `extractMessage` 返回 null，垃圾永久留在缓冲区头部，此后所有消息都解析不出；`size` 巨大时缓冲无限增长 | 非法头 → 置 `dead`；`read_buf` 上限 1 MiB，超限置 `dead`；连续 N 次解析无进展也置 `dead` | 单测：注入非法头后 `dead == true`；注入 `size = 0xFFFF0000` 且缓冲已超限 → `dead == true` |
| R3（P2-5） | socket 非阻塞，`writeAll` 只处理 SUCCESS/INTR，EAGAIN 直接判死并丢字 | EAGAIN 时 `poll(POLLOUT)` 重试到截止时间（默认 500ms），超时才判死 | 单测（注入假 write/poll）：EAGAIN→成功 重试通过；一直 EAGAIN → 超时返回错误 |
| R4（P1-3） | 录音中静音是全局 sink 状态；进程被 SIGKILL/SIGHUP 时不解除，系统永久静音 | 静音时写 marker `$XDG_RUNTIME_DIR/asr-muted`，正常解除时删除；启动时 marker 存在 → 解除静音并删 marker；SIGHUP 走正常关机（解除静音） | 单测：marker 读写/恢复判定；真机：录音中 `kill -9`，重启 ASR 后 `wpctl get-volume` 不再是 `[MUTED]` |
| R5（P2-2） | `isUsableInputDevice` 只返回 bool，EACCES 被报成 `KeyboardDeviceNotFound` | 区分"不存在"与"无权限"：无权限时 `error.KeyboardPermissionDenied`，日志提示加入 `input` 组 | 单测：`classifyDeviceOpenError(error.AccessDenied) == .denied`；对 0o000 临时文件打开失败被识别 |
| R6（P2-3） | 录音器立刻退出时 `start_signal` 已通知"started"，采到 0 字节也照常走完，日志只有 `stopped: 0 chunks` | 0 字节采集 → `ERR no_audio_captured …`（检查麦克风/PipeWire），不再进入 finish | 单测：`noAudioCaptured(.{.byte_count = 0}) == true`、`byte_count = 1` 为 false；真机：`pw-record` 不可用时看到该错误 |
| R7（P2-6，复核后收窄） | `finish_timeout_ms = 5000` 超时返回 `.none`。复核代码后修正：`takeResolvedResult()` 会在截止时刻取回**已到达**的 final（`currentStreamingResolution` 判 `final_text != null` → `.final`），所以真正丢的只有"晚于 5s 才到达"的尾句 | 超时且会话仍存活（`reader_closed == false`、无错误）→ 再等一个 grace（默认 2000ms）后取一次结果；grace 由纯判定函数控制，便于单测 | 单测：`shouldWaitGrace(grace_ms, reader_closed, has_error)` 四个分支；真机：长句松手后尾句照常上屏 |
| R8（P2-9） | 静音探测匹配字面量 `"[MUTED]"` | 大小写不敏感匹配 `MUTED`；无法解析时按"未静音"处理并记 debug 日志 | 单测：`"volume: 0.45 [muted]"` 判定为静音 |
| R9（P2-10） | 提示音路径硬编码 `/usr/share/sounds/freedesktop/stereo/bell.oga`；实测该路径在本机不存在，而 `/run/current-system/sw/share/sounds/freedesktop/stereo/bell.oga` 存在（system profile 的 sound-theme-freedesktop）→ 提示音**实际上从未响过** | 候选路径探测（`$ASR_BELL` → `/run/current-system/sw/share/...` → `/usr/share/...` → `~/.local/share/...`），都缺失则跳过且不报错 | 单测：候选选择函数在"第二个存在"时返回第二个；真机：按住说话时能听到提示音 |
| R10（P2-11） | 每次最终文本都跑一次 `curl` 纠错（1.5s 超时）；baidu 引擎共享同一 pipeline，token 为空时发注定失败的请求 | `--no-rectify` 关闭；`sami_token`/`device_id` 为空时跳过；README 说明"松手到上屏最多约 1.5s" | 单测：`shouldRectify(flag=false)` 为 false；空 token 为 false |
| R11（P2-12） | 只等松手或关机，键松开事件丢失时会话可无限跑 | `--max-hold-ms <n>`（默认 120000，0 = 不限）；到点按正常松手处理（仍 finish 并提交已识别内容） | 单测：对空管道 fd 调用"等松手 + 截止时间"在超时后返回 `.timeout` |
| R12（P3） | `Logger` 每次写都新建 writer，重定向到普通文件时从头覆盖；超长行被静默丢弃 | `--log-file <path>` 追加写入（进程内保持文件与 writer）；行缓冲 1024 保持不变 | 单测：对同一路径写两行后文件包含两行 |
| R13（P3） | `zig fmt --check` 在 `src/baidu/proto.zig`、`src/doubao/rectify.zig` 失败；无 CI/门禁 | `zig fmt` 干净；新增 `zig build check`（fmt --check + test） | 命令：`zig build check` 通过 |
| R14（P3） | `main.zig` 的 `--once-pcm` 与 `app.run` 各有约 20 行相同的凭证刷新逻辑 | 抽成一个函数（返回是否已刷新），两边各自记日志 | 单测：现有凭证测试保持通过；`grep -c refreshFile` 只剩实现处 |

## 非目标

- 不迁移凭证文件、不做提交兜底、不取消录音静音（用户决定）。
- 不做静音端点检测（VAD 自动停）、不做连接池、不做常驻/toggle 模式。
- 不做 IM 断线重连：断开即清晰报错退出。
- 多键盘同时监听 + `app.zig` 拆分另立计划（第二阶段）。

## 行为变化（用户可见）

| 场景 | 现在 | 之后 |
|---|---|---|
| 合成器不支持 IM / 未运行在 Wayland | 回退 IBus → 无 IBus 时吐 Zig 调用栈 | 一行 `ERR wayland_im_unavailable …` + 非零退出 |
| IM 连接中断 | 日志继续打 ✅，文字不再上屏 | 一行 `ERR wayland_im_disconnected` + 非零退出 |
| `--ibus` / `--ibus-xml` / `--wayland` / `--no-wayland` | 支持 | 不再存在（未知参数报错并提示 `--help`） |
| 录音中被强杀 | 系统一直静音 | 下次启动自动解除静音 |
| 键盘无权限 | `error: KeyboardDeviceNotFound` | `ERR keyboard_permission_denied: 用户需加入 input 组` |
| 录音器无输出 | 静默走完，只有 `stopped: 0 chunks` | `ERR no_audio_captured …` |
| 日志重定向到文件 | 从 offset 0 覆盖 | `--log-file` 追加 |

## 验收

1. `zig build test --summary all` 全绿（删除约 7 个 IBus 测试与 arecord 测试，新增约 15 个）。
2. `zig build check` 通过；`zig fmt --check src build.zig` 干净。
3. `grep -ri "ibus" src build.zig README.md` 无命中；`grep -ri arecord src` 无命中。
4. 真机冒烟：`./zig-out/bin/asr --debug` → 绑定成功 → 按住说话 → 松手 → 文字上屏；`[wayland] ✅` 且无异常日志。
5. 错误场景：清除 `WAYLAND_DISPLAY` 运行 → 一行 ERR + 退出码非 0。
6. 真机验证 R4：录音中 `kill -9`，重启后 `wpctl get-volume @DEFAULT_AUDIO_SINK@` 无 `[MUTED]`。
7. 真机验证 R11：`--max-hold-ms 3000` 按住 5 秒 → 3 秒时自动结束并提交。

## 风险

- 删除 IBus 后没有回退：合成器不支持 IM 时工具直接不可用。当前环境已实测支持；用清晰错误替代静默回退。
- `--max-hold-ms` 到点后要杀掉录音器并走正常 finish，需真机验证不会漏字。
- SIGHUP 语义改变（以前进程直接死，现在走正常关机），可能影响"关终端即退出"的习惯用法；关机路径会额外做一次 unmute 与 WS 收尾。
