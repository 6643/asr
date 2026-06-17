# rectify_text API 文档

## 请求

```
POST https://ime.oceancloudapi.com/api/v1/rectify_text
Content-Type: application/json
sami_token: <SAMI_TOKEN>
X-Device-Id: <DEVICE_ID>
```

### 请求体

```typescript
interface RectifyTextRequest {
  text: string;        // ASR 识别文本, 包含可能的错误
  scene?: string;      // 场景标识, 固定 "asr"
  rectify_type: string; // 纠错类型, 固定 "asr_correct" (必填, 不传返回空)
  request_id?: string; // 请求 ID, 可选
}
```

## 响应

```typescript
interface RectifyTextResponse {
  code: number;   // 状态码, 0=成功
  msg: string;    // 状态消息, "success"
  data: {
    correct_word_info: CorrectWordInfo[];
  };
}

interface CorrectWordInfo {
  source_word: string;     // 原始错误词, 如 "qù"
  predict_word: string;    // 建议修正词, 如 "去"
  word_idx_in_text: number; // 错误词在原文中的字符偏移 (0-based)
  confidence: number;      // 置信度, 固定 0.9
}
```

## 说明

- **不做去口水**: 口水词 (呃/啊/那个等) 不被视为错误, 不返回
- **不做润色**: 只纠正 ASR 错别字, 不改写句子
- **替换方式**: 客户端需根据 `word_idx_in_text` 从右向左逐个替换
- **rectify_type 必填**: 不传返回空数组
