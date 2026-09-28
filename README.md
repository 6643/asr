# ASR (Zig)

当前仓库仅保留 Zig 0.16 实现，且只支持当前 PC 环境：**Wayland 输入法提交 + PipeWire 采集**。

## 依赖

- 提供 `zwp_input_method_manager_v2` 的 Wayland 合成器（本机 umbriel 已支持）
- `pipewire`：`pw-record`（采集）、可选 `wpctl`（录音期间静音）、可选 `pw-play`（提示音）
- `curl`（刷新凭证、结果纠错）
- `zig` 0.16
- 可读的键盘输入设备（`/dev/input/event*`）：加入 `input` 组后重新登录即可
  （`NixOS`: `users.users.<name>.extraGroups = [ "input" ];`）

没有备用后端、也没有备用录音器：缺依赖时会直接报错退出。

## 配置

默认使用 Doubao，凭证与参数读取 `config/doubao.json`（每次启动刷新 token 并写回该文件）。

使用 `--baidu` 切换到 Baidu，读取 `config/baidu.json`：

```json
{
  "url": "wss://vse.baidu.com/ws_api",
  "sample_rate": 16000,
  "channels": 1,
  "frame_duration_ms": 100,
  "user": "baidu_pc",
  "dev_key": "com.baidu.searchbox.fangyan",
  "dev_pid": 8068
}
```

## 构建与运行

```bash
zig build test     # 单元测试
zig build check    # zig fmt --check + 测试
zig build
./zig-out/bin/asr
```

按住 `RightAlt` 开始录音并实时识别，松开后等待最终结果并提交到当前输入焦点。按 `--help` 查看全部选项：

```
--doubao              use the doubao engine (default)
--baidu               use the baidu engine
--once-pcm <path>     transcribe one raw PCM file and exit
--debug               verbose logging
--no-rectify          skip result rectification
--max-hold-ms <n>     stop capture after n ms (0 = unlimited, default 120000)
--log-file <path>     append logs to a file instead of the terminal
--help                show this message
```

键盘设备自动发现失败时可显式指定：

```bash
ASR_KEYBOARD_DEVICE=/dev/input/event2 ./zig-out/bin/asr
```

离线 PCM 识别测试（16kHz 单声道 `s16le`）：

```bash
./zig-out/bin/asr --once-pcm /tmp/asr-debug.pcm          # Doubao
./zig-out/bin/asr --baidu --once-pcm /tmp/asr-debug.pcm  # Baidu
```

## Wayland 输入法

- ASR 启动时绑定为 seat 输入法，通过 `commit_string` + `commit` 提交识别结果；绑定失败打印一行错误并以非零码退出（`unavailable: InputMethodUnavailable: another ASR instance may already hold the seat input method` 通常意味着已经有一个 ASR 在跑）。
- 一个 seat 同时只能有一个输入法：同时运行 fcitx5 等 IME 时，后启动的一方会拿到 `unavailable`。
- 连接在运行中断开会打印 `disconnected: …` 并退出非零码，不会静默丢弃文本。
- 提交只覆盖实现 `zwp_text_input_v3` 的应用：GTK4 / Qt6 等原生应用可用；Chrome 需要 `--enable-wayland-ime`（新版本可能默认支持）；XWayland 应用收不到提交。
- 焦点应用不支持 text-input-v3 时 `--debug` 下会看到 `[wayland] ❌ ERR no_text_input`，文本被丢弃且不会误提交。
- 提交失败只记日志（`[wayland] ❌ …`），不做剪贴板兜底。
- 不需要 `grab_keyboard`，也没有新增图形库依赖；与 evdev 热键读取互不影响。

## 日志格式

`HH:MM:SS.mmm [domain] message`（仅时间，不含日期）。`--log-file <path>` 以追加方式写入文件；不指定时写到终端。

## 说明

- 采集只有 `pw-record`（`--debug` 下会打印 `[mic] recorder pw-record`），参数为 `--rate <采样率> --channels <声道> --format s16 -`。
- 录音期间会静音默认输出（`wpctl set-mute @DEFAULT_AUDIO_SINK@ 1/0`），避免外放被麦克风收进去：录音前先探测，若输出本来就静音则不动它；静音时写 `$XDG_RUNTIME_DIR/asr-speaker-muted` 标记，正常结束时删除；进程被强杀后下次启动会自动恢复。
- `wpctl` 不可用时静音链路整体跳过，不影响识别。
- 提示音在候选路径中取第一个存在的文件（`/run/current-system/sw/share/sounds/freedesktop/stereo/bell.oga` → `/usr/share/sounds/...`），都不存在时静默跳过。可用 `pw-play` 手工验证。
- 采集到 0 字节时打印 `ERR no_audio_captured` 并跳过本次会话，而不是静默走完。
- 键盘设备不可读时报 `ERR KeyboardPermissionDenied`，不会伪装成"找不到设备"。
- 会话握手前的语音缓冲与 fallback 音频均有 64MiB 上限，超限后丢弃后续字节，避免无界增长。
- 默认最长按住 120 秒（`--max-hold-ms 0` 取消限制）；到点按"松手"处理，仍会提交已识别的内容。
- 最终识别结果经后处理队列异步 rectify（`--no-rectify` 关闭；缺少 token 时自动跳过）后提交，不阻塞热键循环。松手到文本上屏之间最多会多等约 1.5 秒（纠错请求超时）。
- `SIGINT` / `SIGTERM` / `SIGHUP` 走协作式关闭：主循环与重试 sleep 通过 `shutdown.sleepMs` 可取消，尽快退出并解除静音。
- `postprocess` 直接持有 `src/runtime/wayland_im.zig` 的输入法客户端（纯 `std.posix` socket，无 libwayland 依赖）。

## 发布构建

```bash
zig build -Doptimize=ReleaseSmall
```

产物路径: `zig-out/bin/asr`。
