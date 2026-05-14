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

识别成功后, 程序会通过 IBus engine 直接上屏. 程序启动时会自动切换到 ASR 输入法并激活 engine.

验证方式:

```bash
ibus engine
test -S /tmp/asr_ibus.sock && echo socket-ok
```

配置选项:

- `ASR_AUTO_SWITCH`: 控制是否自动切换到 ASR 输入法 (默认: `true`). 设置为 `false` 或 `0` 可禁用自动切换.
- `ASR_IBUS_RPC_TIMEOUT`: IBus RPC 调用超时时间，单位毫秒 (默认: `1500`). 在慢速系统上可以适当增加.
- `ASR_DEBUG`: 启用调试日志输出 (默认: `false`). 设置为 `1` 或 `true` 启用.
- `ASR_KEYBOARD_DEVICE`: 覆盖键盘设备路径 (默认: 自动检测). 例如 `/dev/input/event3`.
- `ASR_IBUS_COMPONENT_PATH`: 覆盖 IBus 组件安装路径 (默认: `~/.local/share/ibus/component/asr.xml`).
- `ASR_SAMI_APP_KEY`: SAMI 服务认证密钥 (生产环境必需).
- `ASR_HKDF_INFO`: HKDF 密钥派生信息 (默认: `4e30514609050cd3`).

已知约束:

- 程序启动时会自动切换到 `ASR` 输入法. 如果切换失败, 程序会终止启动.
- 可以通过设置 `ASR_AUTO_SWITCH=false` 禁用自动切换, 但需要手动切换到 ASR 输入法.
- 这是 IBus 架构限制: engine 必须被激活（收到 Enable 和 FocusIn 信号）才能提交文本.
- 需要本机已安装 `bun` 和 D-Bus 可用的 `ibus`.

### 文件识别

```typescript
import { transcribeStandalone } from "./src/engines/doubao/client.ts";
import { createConfig, ensureCredentials } from "./src/engines/doubao/config.ts";
import { isErr } from "./src/util.ts";

const config = createConfig({ credentialPath: "./config/doubao.json" });
const ensureResult = await ensureCredentials(config);
if (isErr(ensureResult)) throw ensureResult;

const result = await transcribeStandalone("./audio.wav", { config });
if (isErr(result)) {
    console.error(result.message);
} else {
    console.log(result);
}
```

### 流式识别

```typescript
import { transcribeStreamStandalone } from "./src/engines/doubao/client.ts";
import { ResponseType } from "./src/engines/doubao/types.ts";
import { createConfig, ensureCredentials } from "./src/engines/doubao/config.ts";
import { isErr } from "./src/util.ts";

const config = createConfig({ credentialPath: "./config/doubao.json" });
const ensureResult = await ensureCredentials(config);
if (isErr(ensureResult)) throw ensureResult;

for await (const result of transcribeStreamStandalone("./audio.wav", { config })) {
    if (isErr(result)) break;
    const resp = result;
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
2. **凭据**：首次使用会自动注册设备, 默认保存到 `config/doubao.json`。也可以通过 `credentialPath` 指定自定义路径。
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
