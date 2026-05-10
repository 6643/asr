// 语音识别客户端

import { readWavPcm, createAudioEncoder, splitPcmFrames } from "./audio.ts";
import { type Config, createConfig, getWsUrl, getHeaders, getSessionConfig, getToken, ensureCredentials } from "./config.ts";
import { ResponseType, FrameState, type ASRResponse } from "./types.ts";
import { ok, err, tryResult, type Result } from "../../util.ts";
import { buildStartTask, buildStartSession, buildFinishSession, buildAsrRequest, parseResponse } from "./proto.ts";

// =============
// 会话状态接口
// =============

export interface SessionState {
    requestId: string;
    finalText: string;
    isFinished: boolean;
    error: ASRResponse | null;
}

export const createSessionState = (): SessionState => ({
    requestId: crypto.randomUUID(),
    finalText: "",
    isFinished: false,
    error: null,
});

// =============
// WebSocket 标准流接口
// =============

export interface WebSocketStreams {
    ws: WebSocket;
    readable: ReadableStream<Result<ASRResponse>>;
    writable: WritableStream<Uint8Array>;
}

export const createWebSocketStreams = (ws: WebSocket): WebSocketStreams => {
    let controller: ReadableStreamDefaultController<Result<ASRResponse>> | null = null;

    const readable = new ReadableStream<Result<ASRResponse>>({
        start(ctrl) {
            controller = ctrl;

            const onMessage = (event: MessageEvent) => {
                const data = event.data as ArrayBuffer;
                const result = parseResponse(new Uint8Array(data));
                controller!.enqueue(result);
            };
            const onError = (e: Event) => {
                cleanup();
                tryResult(() => controller!.error(new Error(`WebSocket error: ${JSON.stringify(e)}`)));
            };
            const onClose = () => {
                cleanup();
                tryResult(() => controller!.close());
            };

            const cleanup = () => {
                ws.removeEventListener("message", onMessage);
                ws.removeEventListener("error", onError);
                ws.removeEventListener("close", onClose);
            };

            ws.addEventListener("message", onMessage);
            ws.addEventListener("error", onError);
            ws.addEventListener("close", onClose);
        },
    });

    const writable = new WritableStream<Uint8Array>({
        write(chunk) {
            ws.send(chunk);
        },
        close() {
            // WritableStream 关闭时不自动关闭 WebSocket
        },
    });

    return { ws, readable, writable };
};

export const wsCloseStreams = (streams: WebSocketStreams): void => {
    try {
        streams.ws.close();
    } catch {
        /* ignore */
    }
};

// =============
// Client 接口
// =============

export interface Client {
    config: Config;
    encoder: ReturnType<typeof createAudioEncoder>;
}

export const createClient = (config?: Config): Client => {
    const cfg = config || createConfig();
    return {
        config: cfg,
        encoder: createAudioEncoder(cfg),
    };
};

// =============
// 统一音频源
// =============

export type AudioSource = string | Uint8Array | AsyncIterable<Uint8Array>;

const INITIAL_SESSION_RETRY_LIMIT = 3;
const INITIAL_SESSION_RETRY_DELAY_MS = 300;
const INITIAL_SESSION_RESPONSE_TIMEOUT_MS = 5000;
const WEBSOCKET_CONNECT_TIMEOUT_MS = 30000;

const sleep = (ms: number): Promise<void> => new Promise((resolve) => setTimeout(resolve, ms));

const isRetryableSessionInitError = (message: string): boolean => {
    return /WebSocket connection failed|WebSocket error|StartTask 失败|StartSession 失败|ECONNREFUSED|ECONNRESET|ENOENT|ERR timeout/.test(
        message,
    );
};

// 将任意音频源转换为 PCM 帧流
const toPcmStream = async function* (
    source: AudioSource,
    encoder: ReturnType<typeof createAudioEncoder>,
): AsyncGenerator<Uint8Array> {
    if (typeof source === "string") {
        const [pcmData, pcmError] = await tryResult(readWavPcm(source).then((r) => r.pcmData));
        if (pcmError !== null) return;
        source = pcmData;
    }

    if (source instanceof Uint8Array) {
        const [frames, framesError] = await tryResult(splitPcmFrames(encoder, source));
        if (framesError !== null) return;
        for (const frame of frames) {
            yield frame;
        }
        return;
    }

    // AsyncIterable: 直接透传
    yield* source as AsyncIterable<Uint8Array>;
};

// =============
// 核心识别逻辑
// =============

export const transcribeStream = async function* (
    client: Client,
    audio: AudioSource,
    options?: {
        realtime?: boolean;
    },
): AsyncGenerator<Result<ASRResponse>, void, unknown> {
    const streams = await connectStreams(client);
    const writer = streams.writable.getWriter();

    try {
        // 1. 初始化会话（失败时重试，避免冷启动竞态）
        const [state, initError] = await initializeSessionWithRetry(client, streams.ws);
        if (initError !== null) {
            yield err(initError);
            return;
        }

        // 2. 发送音频
        const sendTask = runSender(client, writer, toPcmStream(audio, client.encoder), state, options?.realtime);

        // 3. 读取响应
        for await (const [response, responseError] of streams.readable) {
            if (responseError !== null) {
                yield err(responseError);
                break;
            }
            if (response.type === ResponseType.HEARTBEAT) continue;
            yield ok(response);
            if (response.type === ResponseType.ERROR || response.type === ResponseType.SESSION_FINISHED) break;
        }

        await sendTask;
    } finally {
        wsCloseStreams(streams);
    }
};

const initializeSessionWithRetry = async (
    client: Client,
    ws: WebSocket,
): Promise<Result<SessionState>> => {
    let lastError: Error | null = null;

    for (let attempt = 1; attempt <= INITIAL_SESSION_RETRY_LIMIT; attempt++) {
        const state = createSessionState();
        let shouldRetry = false;

        for await (const [, initError] of initializeSession(client, ws, state)) {
            if (initError !== null) {
                lastError = initError;
                if (attempt < INITIAL_SESSION_RETRY_LIMIT && isRetryableSessionInitError(initError.message)) {
                    shouldRetry = true;
                    break;
                }
                return err(initError);
            }
        }

        if (shouldRetry) {
            await sleep(INITIAL_SESSION_RETRY_DELAY_MS * attempt);
            continue;
        }

        return ok<SessionState>(state);
    }

    return err(lastError !== null ? lastError : new Error("StartSession 失败"));
};

// 非流式识别，返回最终文本
export const transcribe = async (
    client: Client,
    audio: AudioSource,
    options?: {
        onInterim?: (text: string) => void;
    },
): Promise<Result<string>> => {
    let finalText = "";
    for await (const [response, responseError] of transcribeStream(client, audio)) {
        if (responseError !== null) return err(responseError);

        if (response.type === ResponseType.INTERIM_RESULT && options?.onInterim) {
            options.onInterim(response.text || "");
        } else if (response.type === ResponseType.FINAL_RESULT) {
            finalText = response.text || "";
        } else if (response.type === ResponseType.ERROR) {
            return err(new Error(response.error_msg || "ASR Error"));
        }
    }
    return ok<string>(finalText);
};

// 实时识别别名
export const transcribeRealtime = (client: Client, audioSource: AsyncIterable<Uint8Array>) =>
    transcribeStream(client, audioSource);

// 发送任务实现
const runSender = async (
    client: Client,
    writer: WritableStreamDefaultWriter<Uint8Array>,
    audioStream: AsyncIterable<Uint8Array>,
    state: SessionState,
    realtime?: boolean,
): Promise<Result<void>> => {
    const frameBytes = Math.floor((client.config.sampleRate * client.config.frameDurationMs) / 1000) * 2;
    const frameInterval = client.config.frameDurationMs;
    let frameCount = 0;

    for await (const chunk of audioStream) {
        for (let i = 0; i < chunk.length; i += frameBytes) {
            const frame = sliceOrPad(chunk, i, frameBytes);
            const frameState = frameCount === 0 ? FrameState.FRAME_STATE_FIRST : FrameState.FRAME_STATE_MIDDLE;

            await writer.ready;
            const [, writeError] = await tryResult(writer.write(buildAsrRequest(frame, state.requestId, frameState, Date.now())));
            if (writeError !== null) return err(writeError);
            frameCount++;

            if (realtime) {
                await new Promise((resolve) => setTimeout(resolve, frameInterval));
            }
        }
    }

    // 确保所有帧已刷新后再发送结束帧
    await writer.ready;
    const [token, tokenError] = getToken(client.config);
    if (tokenError !== null) return err(tokenError);
    const [, finishError] = await tryResult(writer.write(buildFinishSession(state.requestId, token)));
    if (finishError !== null) return err(finishError);

    return tryResult(writer.close());
};

// 辅助：切片或补零
const sliceOrPad = (source: Uint8Array, start: number, length: number): Uint8Array => {
    const slice = source.slice(start, start + length);
    if (slice.length < length) {
        const padded = new Uint8Array(length);
        padded.set(slice);
        return padded;
    }
    return slice;
};

export const buildWebSocketInit = (headers: Record<string, string>): { headers: Record<string, string> } => ({ headers });

// 建立 WebSocket 连接
const connectStreams = async (client: Client): Promise<WebSocketStreams> => {
    const [wsUrl, wsUrlError] = getWsUrl(client.config);
    if (wsUrlError !== null) throw wsUrlError;

    if (!wsUrl.startsWith("wss://")) {
        throw new Error(`Insecure WebSocket URL rejected: ${wsUrl}`);
    }
    const ws = new WebSocket(wsUrl, buildWebSocketInit(getHeaders(client.config)) as unknown as string[]);

    await new Promise<void>((resolve, reject) => {
        const connectTimer = setTimeout(() => {
            reject(new Error(`WebSocket connection timeout after ${WEBSOCKET_CONNECT_TIMEOUT_MS}ms`));
        }, WEBSOCKET_CONNECT_TIMEOUT_MS);

        const onError = (e: Event) => {
            clearTimeout(connectTimer);
            const error = (e as Event & { error?: unknown }).error;
            reject(error instanceof Error ? error : new Error(`WebSocket connection failed: ${JSON.stringify(error ?? e)}`));
        };
        ws.onopen = () => {
            clearTimeout(connectTimer);
            ws.removeEventListener("error", onError);
            resolve();
        };
        ws.addEventListener("error", onError);
    });

    return createWebSocketStreams(ws);
};

// 初始化会话
const initializeSession = async function* (
    client: Client,
    ws: WebSocket,
    state: SessionState,
): AsyncGenerator<Result<ASRResponse>, void, unknown> {
    const [token, tokenError] = getToken(client.config);
    if (tokenError !== null) {
        yield err(tokenError);
        return;
    }

    ws.send(buildStartTask(state.requestId, token));
    const [resp, respError] = await tryResult(waitForResponse(ws, INITIAL_SESSION_RESPONSE_TIMEOUT_MS));
    if (respError !== null) {
        yield err(respError);
        return;
    }
    const [parsedResponse, parsedError] = parseResponse(new Uint8Array(resp));
    if (parsedError !== null) {
        yield err(parsedError);
        return;
    }
    if (parsedResponse.type === ResponseType.ERROR) {
        yield err(new Error(`StartTask 失败: ${parsedResponse.error_msg}`));
        return;
    }
    yield ok(parsedResponse);

    const [sessionConfig, sessionConfigError] = getSessionConfig(client.config);
    if (sessionConfigError !== null) {
        yield err(sessionConfigError);
        return;
    }
    sessionConfig.audio_info.format = "pcm";

    ws.send(buildStartSession(state.requestId, token, sessionConfig));
    const [resp2, resp2Error] = await tryResult(waitForResponse(ws, INITIAL_SESSION_RESPONSE_TIMEOUT_MS));
    if (resp2Error !== null) {
        yield err(resp2Error);
        return;
    }
    const [parsedResponse2, parsedError2] = parseResponse(new Uint8Array(resp2));
    if (parsedError2 !== null) {
        yield err(parsedError2);
        return;
    }
    if (parsedResponse2.type === ResponseType.ERROR) {
        yield err(new Error(`StartSession 失败: ${parsedResponse2.error_msg}`));
        return;
    }
    yield ok(parsedResponse2);
};

// 等待响应
const waitForResponse = (ws: WebSocket, timeoutMs = 0): Promise<ArrayBuffer> => {
    return new Promise((resolve, reject) => {
        let timer: ReturnType<typeof setTimeout> | null = null;

        const onMessage = (event: MessageEvent) => {
            ws.removeEventListener("message", onMessage);
            ws.removeEventListener("error", onError);
            if (timer) clearTimeout(timer);
            resolve(event.data as ArrayBuffer);
        };
        const onError = (e: Event) => {
            ws.removeEventListener("error", onError);
            ws.removeEventListener("message", onMessage);
            if (timer) clearTimeout(timer);
            reject(new Error(`WebSocket error: ${JSON.stringify(e)}`));
        };
        ws.addEventListener("message", onMessage);
        ws.addEventListener("error", onError);

        if (timeoutMs > 0) {
            timer = setTimeout(() => {
                ws.removeEventListener("message", onMessage);
                ws.removeEventListener("error", onError);
                reject(new Error("ERR timeout"));
            }, timeoutMs);
        }
    });
};

// =============
// 便捷函数（独立调用，不需要创建 Client 实例）
// =============

export const transcribeStandalone = async (
    audio: AudioSource,
    options?: {
        config?: Config;
        onInterim?: (text: string) => void;
    },
): Promise<Result<string>> => {
    const client = createClient(options?.config);
    const [, ensureError] = await ensureCredentials(client.config);
    if (ensureError !== null) return err(ensureError);

    return transcribe(client, audio, {
        onInterim: options?.onInterim,
    });
};

export const transcribeStreamStandalone = async function* (
    audio: AudioSource,
    options?: {
        config?: Config;
        realtime?: boolean;
    },
): AsyncGenerator<Result<ASRResponse>, void, unknown> {
    const client = createClient(options?.config);
    const [, ensureError] = await ensureCredentials(client.config);
    if (ensureError !== null) {
        yield err(ensureError);
        return;
    }
    yield* transcribeStream(client, audio, { realtime: options?.realtime });
};

export const transcribeRealtimeStandalone = async function* (
    audioSource: AsyncIterable<Uint8Array>,
    options?: {
        config?: Config;
    },
): AsyncGenerator<Result<ASRResponse>, void, unknown> {
    const client = createClient(options?.config);
    const [, ensureError] = await ensureCredentials(client.config);
    if (ensureError !== null) {
        yield err(ensureError);
        return;
    }
    yield* transcribeStream(client, audioSource);
};

export { ResponseType, FrameState };
