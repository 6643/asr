# 启动时刷新 Doubao 凭证设计

## 目标

普通 ASR 进程启动时，使用现有设备标识刷新 `token` 和 `sami_token`，缓解服务端凭证过期或并发配额归属问题。

## 不变约束

- 保留 `device_id`、`install_id`、`cdid`、`openudid`、`clientudid`、`wave_session` 及未知 JSON 字段。
- 只在两个新 token 都成功获取后写回配置。
- 刷新失败不覆盖旧配置，继续使用旧凭证启动。
- 不为刷新流程引入第三方库。
- `--ibus` 和 `--ibus-xml` 不触发网络刷新。

## 数据流

1. 读取 `config/doubao.json`，解析并校验已有 `device_id` 与 `cdid`。
2. 使用固定设备标识请求 ASR settings API，获取新的 ASR token。
3. 使用同一 `cdid` 请求 SAMI config API，获取新的 SAMI token。
4. 两个请求成功后，在原 JSON 文档上仅替换 `token` 与 `sami_token`。
5. 通过临时文件加 rename 写回，避免进程中断产生半份配置。
6. 重新加载刷新后的凭证进入 ASR；失败则继续使用启动前读取的旧值。

## 组件边界

- `config`：负责凭证文件读取、刷新请求、最小字段更新和持久化。
- `main`：在普通 ASR 与 `--once-pcm` 模式完成配置加载后触发刷新；非凭证模式跳过。
- 网络请求：沿用当前无 shell 的 `curl` 子进程方式，设置有限超时并检查 HTTP/JSON 响应。

## 错误处理

- 缺少 `device_id` 或 `cdid`：跳过刷新并保留旧配置；若旧 ASR token 也缺失，则按现有 `MissingCredentials` 失败。
- 任一 HTTP 请求失败、响应字段缺失或 JSON 无效：不写配置，记录脱敏错误。
- 临时文件写入或 rename 失败：不替换原配置，继续使用内存中的旧凭证。
- 不打印 token、SAMI token 或完整请求 URL。

## 验证

- 单元测试证明 JSON 更新只改变 `token` 和 `sami_token`。
- 单元测试证明刷新失败不会改变原 JSON。
- 单元测试证明设备标识和未知字段完整保留。
- `zig build test`、`zig build` 通过。
- 手动启动 `./zig-out/bin/asr --debug`，确认启动阶段出现脱敏刷新结果，并观察新的 session 初始化结果。
