# ASR (Zig)

当前仓库仅保留 Zig 0.16 实现。

## 依赖

- Ubuntu 26.04 + IBus 桌面环境
- `zig` 0.16
- `ibus`, `ibus-daemon`, `arecord`
- 可选: `pw-play` (提示音), `wpctl` (录音期间静音)
- 需要可读键盘输入设备 (`/dev/input/event*`)

## 配置

默认读取 `config/doubao.json`:

```json
{
  "device_id": "your_device_id",
  "token": "your_token",
  "cdid": "optional_cdid"
}
```

`device_id` 和 `token` 为空时会报 `MissingCredentials`。

## 构建与运行

```bash
zig build test
zig build
zig build install-ibus
./zig-out/bin/asr
```

默认会自动发现键盘设备。按住 `RightAlt` 开始录音, 松开触发识别并提交到当前 IBus 输入焦点。

若自动发现失败, 显式指定键盘设备:

```bash
ASR_KEYBOARD_DEVICE=/dev/input/event2 ./zig-out/bin/asr
```

## 运行模式

- 正常模式: `./zig-out/bin/asr`
- 仅 IBus 服务: `./zig-out/bin/asr --ibus`
- 输出 IBus XML: `./zig-out/bin/asr --ibus-xml`
- 离线 PCM 识别测试:

  ```bash
  ./zig-out/bin/asr --once-pcm /tmp/asr-debug.pcm
  ```

`--once-pcm` 需要 16kHz 单声道 `s16le` PCM 数据。

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
