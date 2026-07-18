# 百度语音识别引擎 (Baidu ASR)

## 概述

该模块实现与百度语音识别 WebSocket API 的对接，用于实时语音识别。协议分析基于百度首页（https://www.baidu.com/）搜索框语音输入功能逆向而来。

## 架构

```
麦克风音频 (PCM 16kHz 16-bit mono)
    │
    ▼
baidu/client.zig  ──WebSocket──►  wss://vse.baidu.com/ws_api?sn=<uuid>
    │                                   │
    │  JSON: START                      │
    │  Binary: PCM 音频帧               │
    │  JSON: FINISH                     │
    │                                   │
    │                                   │  JSON: MID_TEXT (中间结果)
    │                                   │  JSON: FIN_TEXT (最终结果)
    │                                   │  JSON: HEARTBEAT
    │                                   │  JSON: SESSION_FINISH
    ▼                                   ▼
baidu/proto.zig (JSON 协议编解码)
```

## 文件说明

| 文件 | 用途 |
|------|------|
| `proto.zig` | Baidu WebSocket JSON 协议的消息构建与解析 |
| `client.zig` | 流式会话客户端 + 一次性 PCM 转录 |
| `README.md` | 本文档 |

## 协议详情

### WebSocket 端点

```
wss://vse.baidu.com/ws_api?sn=<random-uuid>
```

- TLS (WSS) 加密连接
- `sn` 参数为随机 UUID，用于标识会话

### 消息类型

#### 客户端 → 服务器

| 消息 | 类型 | 说明 |
|------|------|------|
| `START` | JSON 文本帧 | 初始化识别会话，携带音频参数 |
| PCM 音频 | 二进制帧 | 裸 PCM 音频数据 (16kHz, 16-bit, 单声道) |
| `FINISH` | JSON 文本帧 | 结束当前识别会话 |
| `HEARTBEAT` | JSON 文本帧 | 心跳保活（可选） |

#### 服务器 → 客户端

| 消息 | 类型 | 说明 |
|------|------|------|
| `MID_TEXT` | JSON 文本帧 | 中间识别结果（实时更新） |
| `FIN_TEXT` | JSON 文本帧 | 最终识别结果（语音段结束） |
| `SESSION_FINISH` | JSON 文本帧 | 会话结束 |
| `HEARTBEAT` | JSON 文本帧 | 心跳响应 |
| `Error` | JSON 文本帧 | 错误信息（`err_no` 非零时） |

### START 消息格式

```json
{
  "type": "START",
  "data": {
    "user": "baidu_pc",
    "dev_key": "com.baidu.searchbox.fangyan",
    "dev_pid": 8068,
    "cuid": "baidu_pc",
    "sample": 16000,
    "format": "pcm",
    "type": 1,
    "role_num": 1,
    "vad_type": 1,
    "vad_mode": 0,
    "channels": 1,
    "need_session_finish": true,
    "punc": true,
    "start_timestamp": 1700000000000
  }
}
```

#### 参数说明

| 参数 | 默认值 | 说明 |
|------|--------|------|
| `user` | `baidu_pc` | 用户标识 |
| `dev_key` | `com.baidu.searchbox.fangyan` | 开发者 key（百度首页使用） |
| `dev_pid` | `8068` | 语音识别产品 ID |
| `sample` | `16000` | 采样率 (Hz) |
| `format` | `pcm` | 音频编码格式 |
| `type` | `1` | 音频类型（1=实时语音） |
| `role_num` | `1` | 说话人数 |
| `vad_type` | `1` | VAD 类型（1=服务端 VAD） |
| `vad_mode` | `0` | VAD 模式 |
| `channels` | `1` | 声道数（1=单声道） |
| `need_session_finish` | `true` | 是否需要 SESSION_FINISH |
| `punc` | `true` | 是否自动添加标点 |
| `start_timestamp` | 当前时间戳 | 开始时间戳 (ms) |

### 服务器响应格式

**中间结果：**
```json
{
  "type": "MID_TEXT",
  "err_no": 0,
  "err_msg": "",
  "result": "今天天气"
}
```

**最终结果：**
```json
{
  "type": "FIN_TEXT",
  "err_no": 0,
  "err_msg": "",
  "result": "今天天气怎么样。"
}
```

**会话结束：**
```json
{
  "type": "SESSION_FINISH"
}
```

**心跳：**
```json
{
  "type": "HEARTBEAT"
}
```

**错误响应：**
```json
{
  "type": "MID_TEXT",
  "err_no": -3005,
  "err_msg": "语音识别错误",
  "result": ""
}
```

## 使用方法

### 配置

配置文件路径：`config/baidu.json`

```json
{
  "url": "wss://vse.baidu.com/ws_api",
  "sample_rate": 16000,
  "channels": 1,
  "frame_duration_ms": 100,
  "user": "baidu_pc",
  "dev_key": "com.baidu.searchbox.fangyan",
  "dev_pid": 8068,
  "vad_type": 1,
  "vad_mode": 0,
  "enable_punctuation": true
}
```

Baidu 语音识别为公开接口，**无需认证 token**，配置文件中的参数均有合理默认值。

### 代码示例

#### 流式识别（StreamingSession）

```zig
const std = @import("std");
const baidu = @import("baidu/client.zig");
const config = @import("config.zig");

const allocator = ...;
const io = ...;
const baidu_cfg = try config.loadBaiduConfig(allocator, io, "config/baidu.json");

// 创建会话（同时建立 WebSocket 连接并发送 START）
var session = try baidu.StreamingSession.init(allocator, io, baidu_cfg, .{
    .debug = true,
    .on_interim = myInterimCallback,
    .interim_ctx = myCtx,
    .on_final = myFinalCallback,
    .final_ctx = myCtx,
});
defer session.deinit();

// 启动读取线程
try session.start();

// 发送音频数据
while (有音频数据) {
    try session.sendChunk(chunk);
}

// 结束识别，等待结果
const finish = try session.finish();
switch (finish) {
    .text => |text| { /* 识别结果: text */ },
    .err => |msg| { /* 错误: msg */ },
    .none => { /* 无结果 */ },
}
```

#### 一次性 PCM 转录

```zig
const result = try baidu.transcribePcmFile(allocator, io, baidu_cfg, .{
    .pcm_path = "/tmp/audio.pcm",
    .debug = true,
    .on_interim = myInterimCallback,
    .interim_ctx = myCtx,
});

if (result) |text| {
    // 使用识别结果
    defer allocator.free(text);
}
```

## 与 Doubao 引擎对比

| 特性 | Doubao | Baidu |
|------|--------|-------|
| WebSocket 协议 | Protobuf (二进制) | JSON 文本帧 + 裸 PCM 二进制 |
| 握手流程 | StartTask → StartSession → 音频 | START 一条消息搞定 |
| 认证 | 需要 token（定期刷新） | **无需认证，开箱即用** |
| 结果格式 | 嵌套 JSON（results 数组） | 简洁 JSON（type + result） |
| 心跳 | 无 | HEARTBEAT 支持 |
| VAD | 客户端+服务端 | 服务端 VAD |
| 标点恢复 | ✅ | ✅ |
| 中间结果 | ✅ | ✅ (MID_TEXT) |

## 已知限制

- 目前 Baidu 引擎仅作为独立模块提供，尚未集成到 `app.zig` 主循环中
- 需要通过 CLI 参数 `--baidu` 或配置文件切换引擎（待实现）
- 无自动凭证刷新机制（Baidu 接口不需要 token，故不需要）
- 音频后处理（rectify/纠错）尚未对接
