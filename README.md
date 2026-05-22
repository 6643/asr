# ASR Zig

Zig 0.16 implementation of the ASR runtime.

## Run

```bash
zig build test
zig build
zig build install-ibus
./zig-out/bin/asr
```

默认会自动发现键盘设备并输出完整日志。按住 `RightAlt` 开始录音, 松开触发识别并提交到当前 IBus 输入焦点。
如果自动发现失败, 再显式指定:

```bash
ASR_KEYBOARD_DEVICE=/dev/input/event2 ./zig-out/bin/asr
```

仅验证豆包识别链路时可用:

```bash
./zig-out/bin/asr --once-pcm /tmp/asr-debug.pcm
```

`--once-pcm` 需要 16kHz 单声道 `s16le` PCM 数据。

## Runtime Notes

- 提示音: 使用 `pw-play` 播放 `/usr/share/sounds/freedesktop/stereo/bell.oga`。
- 录音静音: 使用 `wpctl set-mute @DEFAULT_AUDIO_SINK@ 1/0`。
- `pw-play` 或 `wpctl` 不可用时会自动跳过, 不影响主流程识别与 IBus 提交。
