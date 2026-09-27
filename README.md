# ASR (Zig)

当前仓库仅保留 Zig 0.16 实现。

## 依赖

- Linux 桌面: IBus 环境 (Ubuntu 等) 或提供 `zwp_input_method_manager_v2` 的 Wayland 合成器 (niri 等)
- `zig` 0.16
- `arecord`
- IBus 环境需要: `ibus`, `ibus-daemon`
- 可选: `pw-play` (提示音), `wpctl` (录音期间静音)
- 需要可读键盘输入设备 (`/dev/input/event*`)

## 配置

默认使用 Baidu WebSocket ASR, 配置读取 `config/baidu.json`:

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

使用 `--doubao` 可显式切回 Doubao, 其凭证仍读取 `config/doubao.json`。

## 构建与运行

```bash
zig build test
zig build
zig build install-ibus
./zig-out/bin/asr
```

默认会自动发现键盘设备与提交后端: 设置了 `WAYLAND_DISPLAY` 且合成器提供 `zwp_input_method_manager_v2` 时使用 Wayland 输入法协议, 否则回退 IBus。按住 `RightAlt` 开始录音并实时识别, 松开后等待最终结果并提交到当前输入焦点。

若自动发现失败, 显式指定键盘设备:

```bash
ASR_KEYBOARD_DEVICE=/dev/input/event2 ./zig-out/bin/asr
```

## 运行模式

- 正常模式: `./zig-out/bin/asr`
- Doubao 模式: `./zig-out/bin/asr --doubao`
- 强制 Wayland 输入法: `./zig-out/bin/asr --wayland`
- 禁用 Wayland (仅 IBus): `./zig-out/bin/asr --no-wayland`
- 仅 IBus 服务: `./zig-out/bin/asr --ibus`
- 输出 IBus XML: `./zig-out/bin/asr --ibus-xml`
- 离线 PCM 识别测试:

  ```bash
  ./zig-out/bin/asr --once-pcm /tmp/asr-debug.pcm
  ```

`--once-pcm` 默认使用 Baidu, 需要 16kHz 单声道 `s16le` PCM 数据; 加 `--doubao` 可使用 Doubao。

## Wayland 输入法

- 后端选择: 默认自动。设置 `WAYLAND_DISPLAY` 且合成器暴露 `zwp_input_method_manager_v2` 时, ASR 绑定为 seat 输入法并通过 `commit_string` 提交; 绑定失败自动回退 IBus。`--wayland` 强制使用 (失败直接报错), `--no-wayland` 禁用。
- 提交只覆盖实现 `zwp_text_input_v3` 的应用: GTK4 / Qt6 等原生应用可用; Chrome 需要 `--enable-wayland-ime` (新版本可能默认支持); XWayland 应用收不到提交。
- 焦点应用不支持 text-input-v3 时 `--debug` 下会看到 `[wayland] ❌ ERR no_text_input`, 文本被丢弃且不会误提交。
- 一个 seat 同时只能有一个输入法: 若同时运行 fcitx5 等 IME, 后启动的一方会得到 `unavailable`。
- 不需要 `grab_keyboard`, 也没有新增图形库依赖; 与 evdev 热键读取互不影响。

## 发布构建

```bash
zig build -Doptimize=ReleaseSmall
```

产物路径: `zig-out/bin/asr`。

## 日志格式

日志时间戳格式为毫秒级:

`YYYY-MM-DD HH:MM:SS.mmm [domain] message`

## 说明

- 提示音使用 `pw-play /usr/share/sounds/freedesktop/stereo/bell.oga`。
- 录音期间静音使用 `wpctl set-mute @DEFAULT_AUDIO_SINK@ 1/0`。
- `pw-play` 或 `wpctl` 不可用时会自动跳过, 不影响识别与 IBus 提交链路。
- 录音仅走流式路径 (`arecord` stdout → WebSocket), 不再写 `/tmp` 临时 PCM 文件。
- 会话握手前的语音缓冲与 fallback 音频均有 64MiB 上限, 超限后丢弃后续字节, 避免无界增长。
- `SIGINT` / `SIGTERM` 走协作式关闭: 主循环与重试 sleep 通过 `shutdown.sleepMs` 可取消, 便于尽快退出。
- IBus 引擎生命周期: 每次 `CreateEngine` 会先注销并释放旧引擎对象; `Destroy` 同样会清掉当前 active engine, 避免 DBus 注册与堆分配只增不减。
- 最终识别结果经后处理队列异步 rectify + 最终文本提交, 不阻塞热键循环。
- 提交后端抽象为 `CommitBackend`: IBus 走 `gio_ibus.commitStatus`, Wayland 走 `src/runtime/wayland_im.zig` 的原生 `zwp_input_method_v2` 客户端 (纯 `std.posix` socket, 无 libwayland 依赖)。
