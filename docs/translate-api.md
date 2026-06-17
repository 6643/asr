# translate API 文档

## 请求

```
POST https://ime.doubao.com/api/v1/translate
Content-Type: application/json
sami_token: <SAMI_TOKEN>
X-Device-Id: <DEVICE_ID>
```

备用网关: `ime.oceancloudapi.com` / `ime-gw.oceancloudapi.com`

### 请求体

```typescript
interface TranslateRequest {
  text_list: string[];          // 待翻译文本列表, 每项独立翻译
  source_language: number;      // 源语言枚举, 0=自动检测
  target_language: number;      // 目标语言枚举
}
```

### 语言枚举 (部分)

| 值   | 语言 |
|------|------|
| 185  | 中文 |
| 38   | English |
| 30   | English (备用) |
| 4    | Deutsch |
| 40   | Español |
| 60   | Hrvatski / Srpski |
| 85   | 한국어 |
| 100  | Latviešu |

## 响应

```typescript
interface TranslateResponse {
  code: number;   // 状态码, 0=成功
  msg: string;    // 状态消息
  data: {
    translation_list: TranslationItem[];
  };
}

interface TranslationItem {
  detected_source_language: number;  // 检测到的源语言枚举
  translation: string;               // 翻译结果
}
```

## 示例

### 中译英

```bash
curl -X POST https://ime.doubao.com/api/v1/translate \
  -H 'content-type: application/json' \
  -H 'sami_token: <SAMI_TOKEN>' \
  -H 'X-Device-Id: <DEVICE_ID>' \
  -d '{"text_list":["你好世界"],"source_language":0,"target_language":38}'
```

```json
{"code":0,"data":{"translation_list":[{"detected_source_language":185,"translation":"Hello world"}]}}
```

### 英译中

```bash
curl -X POST https://ime.doubao.com/api/v1/translate \
  -H 'content-type: application/json' \
  -H 'sami_token: <SAMI_TOKEN>' \
  -H 'X-Device-Id: <DEVICE_ID>' \
  -d '{"text_list":["hello"],"source_language":0,"target_language":185}'
```

```json
{"code":0,"data":{"translation_list":[{"detected_source_language":38,"translation":"你好"}]}}
```

### 批量翻译

```bash
curl -X POST https://ime.doubao.com/api/v1/translate \
  -H 'content-type: application/json' \
  -H 'sami_token: <SAMI_TOKEN>' \
  -H 'X-Device-Id: <DEVICE_ID>' \
  -d '{"text_list":["hello","world","dog"],"source_language":0,"target_language":185}'
```

```json
{"code":0,"data":{"translation_list":[{"translation":"你好"},{"translation":"世界"},{"translation":"狗"}]}}
```

## 说明

- `text_list` 接受数组, 可一次性翻译多条文本
- `source_language=0` 自动检测源语言, 也可显式指定枚举值
- `detected_source_language=0` 表示显式指定了源语言 (未自动检测)
- 语言枚举值不连续, 需要完整的语言映射表可遍历发现
