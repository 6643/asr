# 豆包输入法语音识别流式 API — Zig 实现

## 概述

本模块实现了字节跳动豆包输入法（Doubao IME）的流式语音转文字（ASR）WebSocket 协议。基于对 Android APK v1.3.15 和 macOS IME v0.9.4 的反向工程实现，支持匿名设备级认证，无需真实用户账号。

## 目录结构

```
doubao/
├── README.md          ← 本文档：API 文档
├── ARCHITECTURE.md    ← 架构设计文档
├── client.zig         ← ASR 客户端（流式 + 一次性）
├── proto.zig          ← Protobuf 序列化/反序列化
├── credentials.zig    ← 匿名设备认证
└── rectify.zig        ← 识别结果纠错
```

---

## 协议概览

```
┌──────────┐     WebSocket      ┌──────────────┐
│  Client   │ ◄──────────────► │   Doubao ASR  │
│  (Zig)   │     Protobuf     │    Server     │
└──────────┘                   └──────────────┘
```

### WebSocket 端点

```
wss://frontier-audio-ime-ws.doubao.com/ocean/api/v1/ws
    ?aid=401734
    &device_id=<device_id>
```

### 连接头信息

```
Host: frontier-audio-ime-ws.doubao.com
User-Agent: com.bytedance.android.doubaoime/100102018 ...
proto-version: v2
x-custom-keepalive: true
X-Device-Id: <device_id>
```

---

## 认证流程（匿名设备级）

无需真实账号。通过随机生成的设备标识获取临时 token。

```
┌──────────┐                    ┌──────────────┐
│  Client   │  1. POST + 设备ID  │   is.snssdk  │
│          │ ──────────────────► │  .com/setting│
│          │                    │  s/v3/       │
│          │ ◄────────────────── │              │
│          │     返回 app_key    └──────────────┘
│          │
│          │  2. POST + app_key  ┌──────────────┐
│          │ ──────────────────► │ ime.oceancloud│
│          │                    │ api.com/      │
│          │ ◄────────────────── │ user/get_conf │
│          │   返回 sami_token   │ ig           │
│          │                    └──────────────┘
│          │
│          │  3. WebSocket      ┌──────────────┐
│          │ ──────────────────► │  ASR Server  │
│          │   sami_token 认证   │              │
└──────────┘                    └──────────────┘
```

### 步骤 1：获取 ASR Token

```
POST https://is.snssdk.com/service/settings/v3/
    ?device_platform=android
    &os=android
    &ssmix=a
    &_rticket=<当前时间戳 ms>
    &cdid=<随机 CDID>
    &channel=official
    &aid=401734
    &app_name=oime
    &version_code=100102018
    &version_name=1.1.2
    &device_id=<随机设备 ID>

Header: Content-Type: application/json
Header: x-ss-stub: <MD5("body=null") 大写十六进制>

Body: body=null

→ 返回 JSON，解析路径: data.settings.asr_config.app_key
```

### 步骤 2：获取 SAMI Token

```
POST https://ime.oceancloudapi.com/api/v1/user/get_config
    ?device_platform=android
    &os=android
    &ssmix=a
    &_rticket=<当前时间戳 ms>
    &cdid=<同上 CDID>
    &channel=official
    &aid=401734
    &app_name=oime
    &version_code=100102018
    &version_name=1.1.2
    &device_type=Pixel 7 Pro
    &device_brand=google
    &language=zh
    &os_api=34
    &os_version=16

Header: Content-Type: application/json
Header: app_version: 1.1.2
Header: app_id: 401734
Header: os_type: Android
Header: x-ss-stub: <SHA256(body) 大写十六进制>

Body: {"sami_app_key":"SYlxZr6LnvBaIVmF"}

→ 返回 JSON，解析路径: data.sami_token
```

### 凭据文件格式

```json
{
    "device_id": "随机16位数字",
    "token": "asr_app_key",
    "cdid": "随机设备标识",
    "sami_token": "sami会话token"
}
```

---

## ASR 会话生命周期

```
单次语音输入的完整流程：

客户端                                  ASR 服务器
  │                                        │
  │──── StartTask ────────────────────────►│
  │       {token, service="ASR",           │
  │        method="StartTask",             │
  │        request_id="随机UUID"}           │
  │◄──── TaskStarted ─────────────────────│
  │                                        │
  │──── StartSession ────────────────────►│
  │       {token, service="ASR",           │
  │        method="StartSession",          │
  │        request_id="同上",               │
  │        payload={audio_info, ...}}       │
  │◄──── SessionStarted ──────────────────│
  │                                        │
  │──── TaskRequest (first) ─────────────►│
  │       {service="ASR",                  │
  │        method="TaskRequest",           │
  │        audio_data=<第一帧 PCM>,         │
  │        request_id="同上",               │
  │        frame_state=first,              │
  │        payload={timestamp_ms}}          │
  │◄──── interim result ──────────────────│
  │       {text="识别中..."}                │
  │                                        │
  │──── TaskRequest (middle) ────────────►│
  │       {audio_data=<中间帧 PCM>,         │
  │        frame_state=middle}              │
  │◄──── interim result ──────────────────│
  │◄──── vad event ───────────────────────│
  │       {extra.vad_start=true}           │
  │                                        │
  │──── TaskRequest (last) ──────────────►│
  │       {audio_data=<最后一帧>,           │
  │        frame_state=last}                │
  │                                        │
  │──── FinishSession ───────────────────►│
  │       {token, service="ASR",           │
  │        method="FinishSession",         │
  │        request_id="同上"}               │
  │◄──── final result ────────────────────│
  │       {text="最终识别结果"}              │
  │◄──── SessionFinished ─────────────────│
  │                                        │
```

---

## 连接策略

### 当前策略：单次连接

```
每次语音输入：
  → 创建 TCP 连接
  → TLS 握手
  → WebSocket 握手
  → StartTask / StartSession
  → 发送音频帧
  → FinishSession
  → 关闭 WebSocket
  → 关闭 TCP

用完即关，不保留任何状态。
```

### 为什么不复用连接？

| 原因 | 说明 |
|------|------|
| **场景简单** | Zig 实现处理单次 PCM 文件，一次用完就退出 |
| **逻辑清晰** | 无状态，不存在断线重连、连接泄漏等问题 |
| **无复杂依赖** | 不需要心跳保活、连接池管理等基础设施 |

### 如果需要复用连接

参考 Android/macOS 的连接池策略：

```
第一次语音：
  → 创建 WebSocket 连接
  → StartTask(request_id="A") / StartSession("A")
  → 音频帧（frame_state=first/middle）
  → FinishSession("A")
  → 收到 SessionFinished
  → 启动空闲超时定时器（~30s）

用户 5 秒后再次说话（定时器未触发）：
  → **复用同一个 WebSocket 连接**
  → StartTask(request_id="B") / StartSession("B")  ← 新的 request_id！
  → 音频帧（frame_state=first！）  ← 重新标记为 first
  → FinishSession("B")
  → 收到 SessionFinished
  → 重置空闲定时器

30 秒内没有说话：
  → 定时器触发，关闭 WebSocket
```

关键点：
1. **连接可以复用，但每轮语音都是独立会话**（新的 `request_id`）
2. **每轮的第一帧必须标记 `frame_state=first`**，告诉服务端这是新语音，不是续流
3. **空闲超时**通常为 15-60 秒，超时后释放连接

### 本实现 vs 官方连接池

| 特性 | 本实现（Zig） | Android APK / macOS IME |
|------|-------------|------------------------|
| 连接创建 | 每次新建 | `SAMIConnectPoolService` 管理 |
| 连接复用 | ❌ 不复用 | ✅ 空闲窗口内复用 |
| 空闲超时 | 无（用完即关） | `pool_shutdown_timer`（~30s） |
| 心跳保活 | ❌ | ✅ 内置 |
| QUIC 回退 | ❌ | ✅ Frontier 客户端 |
| 并发连接 | 1 个 | 可配置多路复用 |

---

## Protobuf 协议

### 请求字段编号

| 字段 | 编号 | 类型 | 说明 |
|------|------|------|------|
| token | 2 | string | ASR token |
| service | 3 | string | 固定为 `"ASR"` |
| method | 5 | string | `StartTask` / `StartSession` / `TaskRequest` / `FinishSession` |
| payload | 6 | string | JSON 配置（UTF-8 字符串） |
| audio_data | 7 | bytes | PCM 音频帧 |
| request_id | 8 | string | 随机 UUID（无连字符） |
| frame_state | 9 | varint | 0=unspecified, 1=first, 3=middle, 9=last |

### 响应字段编号

| 字段 | 编号 | 类型 | 说明 |
|------|------|------|------|
| message_type | 4 | string | `TaskStarted` / `SessionStarted` / `SessionFinished` / `TaskFailed` / `SessionFailed` |
| status_msg | 6 | string | 错误描述 |
| result_json | 7 | string | 识别结果 JSON |

### FrameState 枚举

```zig
pub const FrameState = enum(u64) {
    unspecified = 0,
    first = 1,    // 每轮语音输入的第一帧（关键！）
    middle = 3,   // 中间音频帧
    last = 9,     // 最后一帧
};
```

### 响应类型

| 类型 | 说明 |
|------|------|
| `TaskStarted` | StartTask 成功 |
| `SessionStarted` | StartSession 成功 |
| `SessionFinished` | 本轮 ASR 会话正常结束 |
| `TaskFailed` / `SessionFailed` | 服务端错误 |
| result_json（中间结果） | 流式识别结果 |
| result_json（最终结果） | 最终识别结果 |

---

## StartSession 配置 JSON

```json
{
    "audio_info": {
        "channel": 1,
        "format": "pcm",
        "sample_rate": 16000
    },
    "enable_punctuation": true,
    "enable_speech_rejection": false,
    "extra": {
        "app_name": "com.android.chrome",
        "cell_compress_rate": 8,
        "did": "<device_id>",
        "enable_asr_threepass": true,
        "enable_asr_twopass": true,
        "input_mode": "tool"
    }
}
```

---

## TaskRequest 音频帧 Payload JSON

```json
{
    "extra": {},
    "timestamp_ms": 1234567890
}
```

---

## 识别结果 JSON 格式

### 流式中间结果（results 数组）

```json
{
    "results": [
        {
            "text": "今天的天气",
            "is_interim": true,
            "is_vad_finished": false
        },
        {
            "text": "今天的天气怎么样",
            "is_interim": true,
            "is_vad_finished": false
        }
    ]
}
```

### VAD 事件

```json
{
    "extra": {
        "vad_start": true
    }
}
```

### 最终结果

```json
{
    "results": [
        {
            "text": "今天的天气怎么样。",
            "is_interim": false,
            "is_vad_finished": true
        }
    ]
}
```

或简写格式：

```json
{
    "text": "今天的天气怎么样。"
}
```

或 `result` 对象格式：

```json
{
    "result": {
        "text": "今天的天气怎么样。"
    }
}
```

---

## 使用方式

### 一次性识别（文件）

```zig
const text = try doubao.client.transcribePcmFile(allocator, io, cfg, .{
    .pcm_path = "audio.pcm",
    .debug = true,
    .on_interim = struct {
        fn cb(ctx: ?*const anyopaque, text: []const u8) void {
            std.log.info("interim: {s}", .{text});
        }
    }.cb,
});
```

### 流式识别

```zig
var session = try StreamingSession.init(allocator, io, cfg, .{
    .on_interim = interim_cb,
    .on_final = final_cb,
});
try session.start();

// 实时发送音频块
try session.sendChunk(chunk1);
try session.sendChunk(chunk2);

// 结束并等待结果
const result = try session.finish();
```

---

## 错误处理

| 错误类型 | 说明 |
|----------|------|
| `RemoteAsrQuotaExceeded` | 并发配额超限（`"concurrency quota exceeded"`） |
| `RemoteAsrError` | 其他服务端错误 |
| `CredentialRefreshAsrHttpFailed` | ASR token 获取失败 |
| `CredentialRefreshSamiHttpFailed` | SAMI token 获取失败 |
| `SessionStreamClosed` | 流已关闭（错误或手动中断） |
| `UnexpectedResponse` | 服务端返回了意外的消息类型 |

---

## 参数配置

| 参数 | 默认值 | 说明 |
|------|--------|------|
| `sample_rate` | 16000 | 音频采样率 |
| `channels` | 1 | 声道数 |
| `frame_duration_ms` | 100 | 每帧时长 |
| `frame_bytes` | 3200 | 每帧字节数 = `sample_rate * duration / 1000 * channels * 2` |
| `finish_timeout_ms` | 5000 | 等待最终结果的超时时间 |

---

## 纠错（Rectify）

ASR 结果可通过单独的 HTTP API 进行纠错：

```
POST https://ime.oceancloudapi.com/api/v1/rectify_text

Header: content-type: application/json
Header: sami_token: <sami_token>
Header: X-Device-Id: <device_id>

Body: {"text":"识别文本","rectify_type":"asr_correct","scene":"asr"}

Response:
{
    "code": 0,
    "data": {
        "correct_word_info": [
            {
                "source_word": "原词",
                "predict_word": "纠正词",
                "word_idx_in_text": 3,
                "confidence": 0.95
            }
        ]
    }
}
```

纠错超时：1500ms，超时则返回原始文本。
