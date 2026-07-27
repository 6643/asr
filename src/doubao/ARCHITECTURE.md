# 架构设计与策略文档

## 设计哲学

本 ASR 客户端的设计遵循以下原则：

1. **无原生依赖** — 不使用字节跳动的 SAMI Core SDK，纯手工实现协议
2. **零账号** — 匿名设备级认证，无需真实用户
3. **单次连接** — 不实现连接池，每次语音输入独立建连
4. **原始 PCM** — 不进行 Opus 编码，发送原始音频数据
5. **竞态安全** — 使用 `Io.Select` 处理并发等待，避免死锁

---

## 模块职责

### `client.zig` — ASR 客户端

**核心结构：`StreamingSession`**

```
StreamingSession
├── 读线程 (readLoopThread)
│   ├── 读取 WebSocket 消息
│   ├── 解析 Protobuf 响应
│   ├── 分发到 handleResponse()
│   └── 处理关闭/错误
│
├── 写接口 (sendChunk / finish)
│   ├── 缓冲音频 → 拼帧 → 发送
│   └── 互斥锁保护写操作
│
├── 状态机 (StreamingResultState)
│   ├── pending（等待中）
│   ├── final（已收到最终结果）
│   ├── session_finished（会话结束）
│   └── err（错误）
│
└── 等待机制 (waitForFinish)
    ├── Io.Select 竞态
    ├── 条件变量等待状态变更
    └── 超时回退
```

**两种使用模式：**

| 模式 | 函数 | 场景 |
|------|------|------|
| 一次性 | `transcribePcmFile` / `transcribePcmBytes` | 处理完整 PCM 文件 |
| 流式 | `StreamingSession` | 实时麦克风输入 |

### `proto.zig` — Protobuf 协议

**手动实现 protobuf 的编码/解码**，不依赖任何 protobuf 库。

**编码：** 标准的 protobuf varint + length-delimited 格式

| 函数 | 用途 |
|------|------|
| `buildStartTask` | 构建 StartTask 请求 |
| `buildStartSession` | 构建 StartSession 请求（含 JSON payload） |
| `buildAudioRequest` | 构建音频帧请求 |
| `buildFinishSession` | 构建 FinishSession 请求 |
| `parseResponse` | 解析服务端响应 |
| `encodeVarint` | 编码变长整数 |
| `decodeVarint` | 解码变长整数 |

**结果解析策略：** 按优先级尝试多种 JSON 格式

```
parseResponse()
  ├── 匹配 message_type → 返回 TaskStarted/SessionStarted 等
  ├── 匹配 err 类型 → 返回错误
  ├── 没有 result_json → 返回 unknown
  └── parseResultJson()
      ├── extra.vad_start=true → VAD 事件
      ├── 顶层 text 字段 → 最终结果
      ├── results[] 数组 → parseResultsArray()
      │   ├── is_interim=false + is_vad_finished=true → 最终结果
      │   └── 其他 → 中间结果
      └── result.text 字段 → 最终结果
```

### `credentials.zig` — 匿名认证

**认证策略：** 设备级匿名认证，非用户账号体系

```
静态常量（硬编码）：
├── aid = "401734"
├── app_name = "oime"
├── app_version = "1.1.2"
├── sami_app_key = "SYlxZr6LnvBaIVmF"
├── user_agent（模拟 Android Pixel 7 Pro）
└── 认证 URL（is.snssdk.com / oceancloudapi.com）

动态生成：
├── device_id ← 随机 16 字节
├── cdid ← 随机设备标识
├── token ← 从 settings API 获取
└── sami_token ← 从 config API 获取
```

**x-ss-stub 机制：** 字节跳动内部 API 的请求完整性校验

| API | 算法 | 输入 |
|-----|------|------|
| Settings (`is.snssdk.com`) | MD5 大写十六进制 | 请求体字符串 |
| Config (`oceancloudapi.com`) | SHA256 大写十六进制 | 请求体字符串 |

注意：`x-ss-stub` 不是签名，不包含密钥。它只是请求体的哈希校验和，防止传输中被篡改。

### `rectify.zig` — 结果纠错

**纠错策略：**

1. **竞态超时：** 使用 `Io.Select` 在 curl 请求和 1500ms 超时之间竞态
2. **从后往前替换：** 按 `word_idx_in_text` 从大到小排序，避免偏移量错位
3. **UTF-8 安全：** 使用 `codePointToByteOffset` 按字符索引而非字节索引定位
4. **容错：** 源词不匹配时跳过，不中断整个纠错流程

---

## 并发模型

### 流式会话的线程模型

```
┌─ 主线程 ───────────────────────┐
│  session.sendChunk()           │
│  session.finish()              │
│    ├─ flushTrailingFrame()     │
│    ├─ sendFinishRequest()      │
│    └─ waitForFinish()          │
│       └─ Io.Select             │
│          ├─ waitUntilResolved  │
│          └─ timeout            │
└────────────────────────────────┘

┌─ 读线程 ───────────────────────┐
│  readLoopThread()              │
│    ├─ client.read()            │
│    ├─ serverMessage()          │
│    │   └─ handleResponse()     │
│    │       └─ recordEvent()    │
│    │           └─ cond.broadcast│
│    ├─ serverClose()            │
│    └─ close()                  │
└────────────────────────────────┘
```

### 同步原语

| 原语 | 用途 |
|------|------|
| `write_mutex` | 保护 WebSocket 写操作（防止 sendChunk 和 sendFinishRequest 冲突） |
| `state_mutex` | 保护共享状态（StreamingResultState） |
| `state_cond` | 状态变更通知（读线程 → 主线程） |
| `stop_requested` | 原子标志，通知读线程退出 |

---

## 音频帧策略

### 帧大小计算

```zig
fn frameBytes(cfg: anytype) u32 {
    return (sample_rate * duration / 1000) * channels * 2;
    // 默认: (16000 * 100 / 1000) * 1 * 2 = 3200 字节/帧
}
```

### 帧发送逻辑

```
sendChunk(data)
  → 追加到 pending_audio 缓冲区
  → flushReadyFrames()
     → 每当缓冲区 >= frame_bytes，切出一帧发送
     → 第一帧标记 frame_state=first
     → 后续帧标记 frame_state=middle

finish()
  → flushTrailingFrame()
     → 缓冲区中不足一帧的剩余数据，补零到 frame_bytes
     → 发送（仍然标记为 first/middle，由 frame_count 决定）
  → sendFinishRequest()
```

### 时间戳

每帧附带 `timestamp_ms`（Unix 毫秒时间戳），服务端可能用于延迟计算和音频对齐。

---

## 状态机设计

### StreamingResultState

```
                         收到 final
  ┌──────┐ ─────────────────────► ┌──────┐
  │pending│                        │final │
  └──┬───┘                        └──┬───┘
     │                                │
     │ 收到 error                     │
     ├─────────────────────────────► ┌───┐
     │                               │err│
     │                               └───┘
     │
     │ session_finished
     ├─────────────────────────────► ┌─────────────────┐
     │                               │session_finished │
     │                               │或 reader_closed │
     │                               └─────────────────┘
     │
     │ interim/vad → 不改变状态，只触发回调
```

### 关键设计决策：`final_seen` vs `final_text`

- `final_seen` — 标记是否通过 `on_final` 回调交付了结果（多轮说话场景）
- `final_text` — 保存未通过回调交付的最终文本（等待 `finish()` 主动拉取）

**多轮说话场景（按住说话连续识别）：**
```
用户： "今天天气怎么样" ← VAD 检测到停顿
       → final_seen=true（通过 on_final 回调）
用户： "明天呢"         ← 继续说
       → final 覆盖
用户松手 → FinishSession → SessionFinished
         → waitForFinish 返回
```

---

## 连接生命周期管理

### 当前策略：单次连接，用完即关

```
connect() → WebSocket 握手 → 语音会话 → FinishSession → 关闭
```

Zig 实现每次语音输入都创建全新的连接，不保留任何状态。

### 官方连接池策略（Android/macOS）

官方 SDK 使用 `SAMIConnectPoolService` 管理连接池，目的是在短时间内复用连接，减少握手延迟。

#### 连接池的完整生命周期

```
用户点语音按钮
  │
  ▼
(1) InitConnectPool
  │   └─ 首次使用时初始化连接池
  │
  ▼
(2) AddConnectPoolClient
  │   └─ 从池中获取或创建 WebSocket 连接
  │   └─ 发送 StartTask + StartSession
  │
  ▼
(3) 发送音频帧 (TaskRequest)
  │   └─ frame_state = first / middle / last
  │
  ▼
(4) FinishSession
  │   └─ 发送 FinishSession 请求
  │   └─ 收到 SessionFinished
  │
  ▼
(5) 空闲超时等待
  │   ├─ pool_shutdown_timer_start（启动定时器，~30s）
  │   │
  │   ├─ 用户再次说话 → pool_shutdown_timer_cancel
  │   │   └─ 回到步骤(2)，复用连接，新的 request_id
  │   │
  │   └─ 超时 → pool_shutdown_timer_fire
  │       └─ RemoveConnectPoolClient
  │       └─ ShutDownConnectPool
  │
  ▼
(6) 连接关闭
```

#### 连接池的核心优势

```
无连接池（Zig）：
  第一次：TCP(1RTT) + TLS(2RTT) + WS 握手 = ~300ms
  第二次：TCP(1RTT) + TLS(2RTT) + WS 握手 = ~300ms  ← 重新来一遍

有连接池（Android）：
  第一次：TCP(1RTT) + TLS(2RTT) + WS 握手 = ~300ms
  第二次：直接从池子里拿现成连接 = ~0ms  ← 省掉了！
```

### 为什么 Zig 实现不需要连接池

| 因素 | Zig 实现 | Android IME |
|------|---------|-------------|
| 使用场景 | 处理单个 PCM 文件 | 用户一天说几十次语音 |
| 进程生命周期 | 执行完就退出 | 常驻后台，运行数天 |
| 复用机会 | 无（一次执行一次语音） | 多（每次语音间隔短） |
| 握手开销 | 可以接受 | 每次等待 300ms 体验差 |
| 复杂度成本 | 0（不需要） | 需要心跳/重连/泄漏防护 |

### 如果将来需要加连接池

核心改动点：

```
// 1. 拆分 WebSocket 连接与会话
const Connection = struct { client: websocket.Client };
const Session = struct { request_id, ... };

// 2. Connection 保持长连，Session 每次新建
var conn = try pool.acquire();       // 从池中拿连接
defer pool.release(conn);            // 用完归还
var session = try Session.init(conn); // 在已有连接上建会话

// 3. 添加空闲超时和心跳
// - 30s 无活动自动关闭
// - 每 10s 发 ping
```

但当前场景下加连接池属于过度设计，保持简单即可。

---

## 性能考虑

| 方面 | 当前实现 | 优化方向 |
|------|---------|---------|
| 音频编码 | 原始 PCM（约 256kbps） | Opus 编码（约 32kbps），减少带宽和延迟 |
| 连接复用 | 每次新建 | 连接池，减少握手延迟 |
| 并发 | 单连接 | 多路复用 |
| 缓冲区 | 3 帧预分配 | 自适应缓冲区 |
| 超时 | 5s 固定 | 可配超时 |

---

## 与官方 SDK 差异

| 特性 | 本实现 | 官方 SAMI SDK |
|------|--------|--------------|
| 连接池 | ❌ | ✅ 支持多路复用 |
| Opus 编码 | ❌ PCM | ✅ `SAMICoreOpusAudioEncoder` |
| QUIC 传输 | ❌ | ✅ Cronet/Frontier |
| 心跳保活 | ❌ | ✅ 内置 |
| 离线模型 | ❌ | ✅ ONNX Runtime |
| A/B 实验 | ❌ | ✅ AB Config |
| 崩溃报告 | ❌ | ✅ Parfait |
| 复杂度 | ~3000 行 Zig | ~百万级 C++/ObjC/Swift |

---

## 测试策略

模块包含内置单元测试（使用 Zig 的 `test` 块）：

- `proto.zig` — protobuf 编码/解码、JSON 解析、字段构建
- `client.zig` — 状态机转换、超时处理、错误恢复
- `credentials.zig` — JSON 凭证操作、MD5/SHA256 签名
- `rectify.zig` — 超时常量验证

运行测试：
```bash
zig test src/main.zig
```
