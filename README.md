# ASR TypeScript 客户端

TypeScript 实现 ASR 语音识别客户端，基于 WebSocket 协议。

## 安装

```bash
bun install
```

## 依赖

- `bun` 运行时
- `dbus-next` (IBus D-Bus 服务导出)

## 使用

### 实时识别（麦克风）

```bash
bun run index.ts
```

按下 **右 Alt** 键开始说话，松开结束。

> 需要访问 `/dev/input` 设备，如遇权限问题：
> ```bash
> sudo chmod o+r /dev/input/event*
> ```

### IBus 上屏

如果你希望识别结果直接作为输入法内容提交到当前焦点输入框, 需要启用仓库内置的 `IBusEngine`. 当前实现为纯 TypeScript, 通过 `bun + dbus-next` 运行.

1. 安装 IBus 组件:

```bash
./bin/asr-install
```

这一步会把 component 写入系统 IBus 目录并刷新缓存. 如果没有权限, 会提示提权.

2. 在系统输入法里添加并切换到 `ASR`.

3. 启动 ASR 主程序:

```bash
bun run index.ts
```

识别成功后, 程序会通过 IBus engine 直接上屏. 如果 engine 未启动, 未聚焦或当前未切到 `ASR`, 提交会失败并返回错误信息。

验证方式:

```bash
ibus engine
test -S /tmp/asr_ibus.sock && echo socket-ok
```

已知约束:

- 必须把当前输入法切到 `ASR`, 否则 engine 不会拿到焦点, 无法直接提交文本.
- 这是 IBus 架构限制. 外部脚本不能直接对任意应用的当前 `InputContext` 发起方法调用完成上屏.
- 需要本机已安装 `bun` 和 D-Bus 可用的 `ibus`.

### 非流式识别

```typescript
import { transcribeStandalone } from "./src/doubao/client.ts";
import { createConfig, ensureCredentials } from "./src/doubao/config.ts";

const config = createConfig({ credentialPath: "./config/doubao.json" });
await ensureCredentials(config);

const result = await transcribeStandalone("./audio.wav", { config });
if (result.ok) console.log(result.value);
```

### 流式识别

```typescript
import { transcribeStreamStandalone } from "./src/doubao/client.ts";
import { ResponseType } from "./src/doubao/types.ts";

for await (const result of transcribeStreamStandalone("./audio.wav", { config })) {
    if (!result.ok) break;
    const resp = result.value;
    if (resp.type === ResponseType.INTERIM_RESULT) {
        console.log("中间结果:", resp.text);
    } else if (resp.type === ResponseType.FINAL_RESULT) {
        console.log("最终结果:", resp.text);
    }
}
```

## 示例

```bash
bun examples/basic.ts
bun examples/stream.ts ./audio.wav
bun examples/file_transcribe.ts
```

## 测试

```bash
bun test
```

## 注意事项

1. **音频格式**：支持 16-bit PCM WAV 文件（16kHz 单声道）。
2. **凭据**：首次使用会自动注册设备，凭据保存到 `config/doubao.json`。
3. **实时识别**：依赖系统 `arecord` 命令捕获麦克风音频（Linux）。

## 项目结构

```
src/
├── engines/
│   └── doubao/     # 豆包 ASR 引擎本体
└── runtime/        # 公共运行时, IBus, 键盘, 麦克风, 静音, 提交
```

## License

MIT
