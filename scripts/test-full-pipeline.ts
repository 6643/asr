import { readFileSync } from 'fs';
import { randomUUID } from 'crypto';

// --- Protobuf encoding ---
function encodeVarint(value: number): Uint8Array {
  const bytes: number[] = [];
  while (value > 0x7f) {
    bytes.push((value & 0x7f) | 0x80);
    value >>>= 7;
  }
  bytes.push(value);
  return new Uint8Array(bytes);
}

function concatBytes(arrays: Uint8Array[]): Uint8Array {
  const total = arrays.reduce((s, a) => s + a.length, 0);
  const r = new Uint8Array(total);
  let offset = 0;
  for (const a of arrays) { r.set(a, offset); offset += a.length; }
  return r;
}

function encodeStringField(fieldNumber: number, value: string): Uint8Array {
  const tag = encodeVarint((fieldNumber << 3) | 2);
  const strBytes = new TextEncoder().encode(value);
  const len = encodeVarint(strBytes.length);
  return concatBytes([tag, len, strBytes]);
}

function encodeBytesField(fieldNumber: number, value: Uint8Array): Uint8Array {
  const tag = encodeVarint((fieldNumber << 3) | 2);
  const len = encodeVarint(value.length);
  return concatBytes([tag, len, value]);
}

function encodeVarintField(fieldNumber: number, value: number): Uint8Array {
  const tag = encodeVarint((fieldNumber << 3) | 0);
  const val = encodeVarint(value);
  return concatBytes([tag, val]);
}

function buildRequest(data: { token?: string; service?: string; method?: string; payload?: string; audio?: Uint8Array; requestId?: string; frameState?: number }): Uint8Array {
  const parts: Uint8Array[] = [];
  if (data.token) parts.push(encodeStringField(2, data.token));
  if (data.service) parts.push(encodeStringField(3, data.service));
  if (data.method) parts.push(encodeStringField(5, data.method));
  if (data.payload) parts.push(encodeStringField(6, data.payload));
  if (data.audio) parts.push(encodeBytesField(7, data.audio));
  if (data.requestId) parts.push(encodeStringField(8, data.requestId));
  if (data.frameState !== undefined) parts.push(encodeVarintField(9, data.frameState));
  return concatBytes(parts);
}

// --- Parse response ---
function decodeVarint(data: Uint8Array, offset: number): { value: number; bytesRead: number } {
  let result = 0, shift = 0, read = 0;
  while (offset < data.length) {
    const byte = data[offset]; offset++; read++;
    result |= (byte & 0x7f) << shift;
    if (!(byte & 0x80)) return { value: result, bytesRead: read };
    shift += 7;
    if (shift >= 32) break;
  }
  return { value: result, bytesRead: read };
}

function decodeString(data: Uint8Array, offset: number): { value: string; bytesRead: number } {
  const { value: len, bytesRead: lenBytes } = decodeVarint(data, offset);
  const strBytes = data.slice(offset + lenBytes, offset + lenBytes + len);
  return { value: new TextDecoder().decode(strBytes), bytesRead: lenBytes + len };
}

function parseResponse(data: Uint8Array): { msgType: string; status: string; resultJson: string } {
  let offset = 0;
  let msgType = '', status = '', resultJson = '';
  while (offset < data.length) {
    const { value: tag, bytesRead } = decodeVarint(data, offset);
    offset += bytesRead;
    const fieldNum = tag >>> 3;
    const wireType = tag & 0x7;
    if (fieldNum === 4 && wireType === 2) {
      const r = decodeString(data, offset);
      msgType = r.value; offset += r.bytesRead;
    } else if (fieldNum === 6 && wireType === 2) {
      const r = decodeString(data, offset);
      status = r.value; offset += r.bytesRead;
    } else if (fieldNum === 7 && wireType === 2) {
      const r = decodeString(data, offset);
      resultJson = r.value; offset += r.bytesRead;
    } else {
      if (wireType === 0) { const r = decodeVarint(data, offset); offset += r.bytesRead; }
      else if (wireType === 2) { const r = decodeVarint(data, offset); offset += r.bytesRead + r.value; }
      else offset += wireType === 1 ? 8 : 4;
    }
  }
  return { msgType, status, resultJson };
}

// --- Config ---
const config = JSON.parse(readFileSync('/home/_/._/asr/config/doubao.json', 'utf-8'));
const TOKEN = config.token;
const SAMI_TOKEN = config.sami_token;
const DEVICE_ID = config.device_id;
const AID = 401734;
const REQUEST_ID = randomUUID().replace(/-/g, '');
const FRAME_BYTES = 3200; // 100ms at 16kHz 16-bit mono
const WS_URL = `wss://frontier-audio-ime-ws.doubao.com/ocean/api/v1/ws?aid=${AID}&device_id=${DEVICE_ID}`;
const API_HOST = 'https://ime.oceancloudapi.com';
const USER_AGENT = 'Mozilla/5.0 (Linux; Android 16; Pixel 7 Pro) AppleWebKit/537.36';

async function callAPI(endpoint: string, body: any): Promise<void> {
  const response = await fetch(`${API_HOST}${endpoint}`, {
    method: 'POST',
    headers: {
      'Content-Type': 'application/json',
      'sami_token': SAMI_TOKEN,
      'X-Device-Id': DEVICE_ID,
      'User-Agent': USER_AGENT,
    },
    body: JSON.stringify(body),
  });
  const text = await response.text();
  let pretty: string;
  try { pretty = JSON.stringify(JSON.parse(text), null, 2); } catch { pretty = text; }
  console.log(`--- ${endpoint} ---`);
  console.log(pretty);
}

async function main() {
  console.log(`request_id: ${REQUEST_ID}`);
  console.log(`device_id: ${DEVICE_ID}`);
  console.log(`token: ${TOKEN.substring(0, 8)}...`);
  console.log(`sami_token: ${SAMI_TOKEN.substring(0, 20)}...\n`);

  // --- Step 1: Establish WS session ---
  console.log('Connecting to WS...');
  const ws = new WebSocket(WS_URL, {
    headers: {
      'User-Agent': USER_AGENT,
      'proto-version': 'v2',
      'X-Custom-Keepalive': 'true',
      'X-Device-Id': DEVICE_ID,
    },
  });

  // Wait for connection
  await new Promise<void>((resolve, reject) => {
    ws.onopen = () => resolve();
    ws.onerror = () => reject(new Error('WS connection failed'));
    const timeout = setTimeout(() => reject(new Error('WS timeout')), 10000);
    ws.addEventListener('open', () => { clearTimeout(timeout); resolve(); });
  });
  console.log('WS connected.\n');

  // Set up message handling
  const messageQueue: Uint8Array[] = [];
  let messageResolve: ((msg: Uint8Array) => void) | null = null;

  ws.onmessage = (event: MessageEvent) => {
    const data = new Uint8Array(event.data as ArrayBuffer);
    if (messageResolve) {
      messageResolve(data);
      messageResolve = null;
    } else {
      messageQueue.push(data);
    }
  };

  async function waitForMessage(): Promise<Uint8Array> {
    if (messageQueue.length > 0) return messageQueue.shift()!;
    return new Promise(resolve => { messageResolve = resolve; });
  }

  // --- Step 2: StartTask ---
  console.log('Sending StartTask...');
  ws.send(buildRequest({ token: TOKEN, service: 'ASR', method: 'StartTask', requestId: REQUEST_ID }));
  const taskResp = parseResponse(await waitForMessage());
  console.log(`Response: msgType=${taskResp.msgType}\n`);

  // --- Step 3: StartSession ---
  console.log('Sending StartSession...');
  const sessionPayload = JSON.stringify({
    audio_info: { channel: 1, format: 'pcm', sample_rate: 16000 },
    enable_punctuation: true,
    enable_speech_rejection: false,
    extra: {
      app_name: 'com.android.chrome',
      cell_compress_rate: 8,
      did: DEVICE_ID,
      enable_asr_threepass: true,
      enable_asr_twopass: true,
      input_mode: 'tool',
    },
  });
  ws.send(buildRequest({ token: TOKEN, service: 'ASR', method: 'StartSession', requestId: REQUEST_ID, payload: sessionPayload }));
  const sessResp = parseResponse(await waitForMessage());
  console.log(`Response: msgType=${sessResp.msgType}\n`);

  // --- Step 4: Send minimum audio (one frame of silence, then finish) ---
  const silence = new Uint8Array(FRAME_BYTES);
  console.log(`Sending audio frame (${FRAME_BYTES} bytes of silence)...`);
  ws.send(buildRequest({
    service: 'ASR',
    method: 'TaskRequest',
    requestId: REQUEST_ID,
    payload: JSON.stringify({ extra: {}, timestamp_ms: Date.now() }),
    audio: silence,
    frameState: 9, // first + last (only one frame)
  }));

  // --- Step 5: FinishSession ---
  console.log('Sending FinishSession...');
  ws.send(buildRequest({ token: TOKEN, service: 'ASR', method: 'FinishSession', requestId: REQUEST_ID }));

  console.log('Waiting for responses...\n');
  let finalText = '';
  let sessionFinished = false;

  while (!sessionFinished) {
    const resp = parseResponse(await waitForMessage());
    console.log(`Response: msgType=${resp.msgType}`);

    if (resp.msgType === 'SessionFinished') {
      sessionFinished = true;
    }
    if (resp.resultJson) {
      try {
        const json = JSON.parse(resp.resultJson);
        const text = json.text || (json.results && json.results[0]?.text) || (json.result?.text) || '';
        if (text) {
          finalText = text;
          console.log(`  Result text: "${text}"`);
        }
        // Also check for nonstream_result
        if (json.extra?.nonstream_result) {
          console.log(`  Full JSON: ${resp.resultJson.substring(0, 200)}`);
        }
      } catch (e) {
        console.log(`  Raw result: ${resp.resultJson.substring(0, 200)}`);
      }
    }
    if (resp.status) console.log(`  Status: ${resp.status}`);
  }

  ws.close();
  console.log(`\n=== Final ASR Result: "${finalText}" ===\n`);

  // --- Step 6: Test post-ASR APIs with context ---
  const testText = finalText || '呃然后呢那个我觉得吧就是嗯这个方案挺好的';

  // Try rectify_text
  await callAPI('/api/v1/rectify_text', {
    text: testText,
    request_id: REQUEST_ID,
    rectify_type: 'asr_correct',
    scene: 'asr',
    session_id: REQUEST_ID,
  });

  // Try asr/fmt
  await callAPI('/api/v1/asr/fmt', {
    text: testText,
    request_id: REQUEST_ID,
    scene: 'asr',
    did: DEVICE_ID,
  });

  // Try ailab/transform with polish
  await callAPI('/api/v1/ailab/transform', {
    text: testText,
    target: 'polish',
    scene: 'im',
    did: DEVICE_ID,
    source: 'ime_asr',
  });

  // Try with the filler-word text specifically for rectify
  await callAPI('/api/v1/rectify_text', {
    text: '呃然后呢那个我觉得吧就是嗯这个方案挺好的',
    request_id: REQUEST_ID,
    rectify_type: 'asr_correct',
    scene: 'asr',
  });

  console.log('\nDone.');
}

main().catch(console.error);
