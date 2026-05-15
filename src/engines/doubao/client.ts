// 语音识别客户端

import { readWavPcm, createAudioEncoder, splitPcmFrames } from "./audio.ts";
import { type Config, createConfig, getWsUrl, getHeaders, getSessionConfig, getToken, ensureCredentials } from "./config.ts";
import { ResponseType, FrameState, type ASRResponse } from "./types.ts";
import { ok, err, tryAsyncResult, isErr, ignoreError, type Result } from "../../util.ts";
import { buildStartTask, buildStartSession, buildFinishTask, buildFinishSession, buildAsrRequest, parseResponse } from "./proto.ts";
import { printTimedDomain } from "../../runtime/output.ts";
import {
    consumeReadableResponses,
    buildWebSocketInit,
    createSessionRetryDelayMs,
    isWsUrlSecure,
    normalizeWsError,
    shouldRetrySessionInit,
    sliceOrPad,
    waitForResponse,
    type ReadableResponseEvent,
} from "./client-helpers.ts";

const logDoubaoError = (enabled: boolean | undefined, message: string): void => {
    if (!enabled) return;
    printTimedDomain("doubao", `error ${message}`);
};

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
                if (controller !== null) {
                    controller.enqueue(result);
                }
            };
            const onError = (_e: Event) => {
                cleanup();
                errorReadableController(controller, new Error("WebSocket error"));
            };
            const onClose = () => {
                cleanup();
                closeReadableController(controller);
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

const errorReadableController = (
    controller: ReadableStreamDefaultController<Result<ASRResponse>> | null,
    error: Error,
): void => {
    if (controller === null) return;
    ignoreError(() => controller.error(error));
};

const closeReadableController = (controller: ReadableStreamDefaultController<Result<ASRResponse>> | null): void => {
    if (controller === null) return;
    ignoreError(() => controller.close());
};

export const wsCloseStreams = (streams: WebSocketStreams): void => {
    ignoreError(() => streams.ws.close());
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

export const createSessionStateForAttempt = (): SessionState => createSessionState();

// 将任意音频源转换为 PCM 帧流
const toPcmStream = async function* (
    source: AudioSource,
    encoder: ReturnType<typeof createAudioEncoder>,
): AsyncGenerator<Uint8Array> {
    const resolvedSource = await resolveAudioSource(source);
    if (isErr(resolvedSource)) return;
    yield* pcmStreamFromResolvedSource(resolvedSource.value, encoder);
};

const pcmStreamFromResolvedSource = async function* (
    source: AudioSource,
    encoder: ReturnType<typeof createAudioEncoder>,
): AsyncGenerator<Uint8Array> {
    if (!(source instanceof Uint8Array)) {
        yield* source as AsyncIterable<Uint8Array>;
        return;
    }
    yield* splitPcmFrameStream(source, encoder);
};

const splitPcmFrameStream = async function* (
    source: Uint8Array,
    encoder: ReturnType<typeof createAudioEncoder>,
): AsyncGenerator<Uint8Array> {
    const framesResult = await tryAsyncResult(() => splitPcmFrames(encoder, source));
    if (isErr(framesResult)) return;
    yield* framesResult.value;
};

const resolveAudioSource = async (source: AudioSource): Promise<Result<AudioSource>> => {
    if (typeof source !== "string") return ok(source);
    const pcmResult = await readWavPcm(source);
    if (isErr(pcmResult)) return err(pcmResult.error);
    return ok(pcmResult.value.pcmData);
};

// =============
// 核心识别逻辑
// =============

export const transcribeStream = async function* (
    client: Client,
    audio: AudioSource,
    options?: {
        realtime?: boolean;
        debugEnabled?: boolean;
    },
): AsyncGenerator<Result<ASRResponse>, void, unknown> {
    const resources = {
        streams: null as WebSocketStreams | null,
        writer: null as WritableStreamDefaultWriter<Uint8Array> | null,
    };

    try {
        yield* transcribeStreamUnchecked(client, audio, options, resources);
    } finally {
        closeTranscribeStreamResources(resources);
    }
};

const closeTranscribeStreamResources = (resources: {
    streams: WebSocketStreams | null;
    writer: WritableStreamDefaultWriter<Uint8Array> | null;
}): void => {
    if (resources.streams) wsCloseStreams(resources.streams);
    resources.writer?.releaseLock();
};

const transcribeStreamUnchecked = async function* (
    client: Client,
    audio: AudioSource,
    options: { realtime?: boolean; debugEnabled?: boolean } | undefined,
    resources: { streams: WebSocketStreams | null; writer: WritableStreamDefaultWriter<Uint8Array> | null },
): AsyncGenerator<Result<ASRResponse>, void, unknown> {
    const initResult = await initializeSessionWithRetry(client, options?.debugEnabled);
    if (isErr(initResult)) {
        yield err(initResult.error);
        return;
    }
    resources.streams = initResult.value.streams;
    resources.writer = resources.streams.writable.getWriter();
    const sendTask = runSender(
        client,
        resources.writer,
        toPcmStream(audio, client.encoder),
        initResult.value.state,
        options?.realtime,
        options?.debugEnabled,
    );

    const responseState = { complete: false };
    yield* consumeAsrResponses(resources.streams.readable, { stopOnSessionFinished: true }, responseState, options?.debugEnabled);

    const sendResult = await sendTask;
    if (isErr(sendResult)) yield err(sendResult.error);

    if (responseState.complete) return;
    yield* consumeAsrResponses(resources.streams.readable, { stopOnFinal: true }, responseState, options?.debugEnabled);
};

const consumeAsrResponses = async function* (
    readable: ReadableStream<Result<ASRResponse>>,
    options: { stopOnFinal?: boolean; stopOnSessionFinished?: boolean },
    state: { complete: boolean },
    debugEnabled: boolean | undefined,
): AsyncGenerator<Result<ASRResponse>, void, unknown> {
    const responses = consumeReadableResponses(readable, {
        ...options,
        onErrorResponse: (message) => logDoubaoError(debugEnabled, message),
    });
    yield* consumeAsrResponseIterator(responses[Symbol.asyncIterator](), state);
};

const consumeAsrResponseIterator = async function* (
    iterator: AsyncIterator<Result<ReadableResponseEvent>>,
    state: { complete: boolean },
): AsyncGenerator<Result<ASRResponse>, void, unknown> {
    const next = await iterator.next();
    if (next.done) return;
    if (isErr(next.value)) {
        yield err(next.value.error);
        return;
    }
    const { response, completed } = next.value.value;
    yield ok(response);
    state.complete = completed;
    if (completed) return;
    yield* consumeAsrResponseIterator(iterator, state);
};

export const initializeSessionWithRetry = async (
    client: Client,
    debugEnabled?: boolean,
): Promise<Result<{ streams: WebSocketStreams; state: SessionState }>> => {
    return initializeSessionAttempt(client, debugEnabled, 1, null);
};

const initializeSessionAttempt = async (
    client: Client,
    debugEnabled: boolean | undefined,
    attempt: number,
    lastError: Error | null,
): Promise<Result<{ streams: WebSocketStreams; state: SessionState }>> => {
    if (attempt > INITIAL_SESSION_RETRY_LIMIT) return err(lastError !== null ? lastError : new Error("StartSession 失败"));

    const streamsResult = await connectStreams(client);
    if (isErr(streamsResult)) return handleSessionConnectFailure(client, debugEnabled, attempt, streamsResult.error);

    const initialized = await initializeSessionAttemptStreams(client, debugEnabled, attempt, streamsResult.value);
    if (isRetrySessionAttemptResult(initialized)) {
        await sleep(createSessionRetryDelayMs(attempt, INITIAL_SESSION_RETRY_DELAY_MS));
        return initializeSessionAttempt(client, debugEnabled, attempt + 1, initialized.error);
    }
    return initialized.result;
};

const handleSessionConnectFailure = async (
    client: Client,
    debugEnabled: boolean | undefined,
    attempt: number,
    errorValue: Error,
): Promise<Result<{ streams: WebSocketStreams; state: SessionState }>> => {
    if (!shouldRetrySessionInit(attempt, INITIAL_SESSION_RETRY_LIMIT, errorValue.message)) return err(errorValue);
    await sleep(createSessionRetryDelayMs(attempt, INITIAL_SESSION_RETRY_DELAY_MS));
    return initializeSessionAttempt(client, debugEnabled, attempt + 1, errorValue);
};

type SessionAttemptResult =
    | { retry: true; error: Error }
    | { retry: false; result: Result<{ streams: WebSocketStreams; state: SessionState }> };

const isRetrySessionAttemptResult = (result: SessionAttemptResult): result is { retry: true; error: Error } => result.retry;

const initializeSessionAttemptStreams = async (
    client: Client,
    debugEnabled: boolean | undefined,
    attempt: number,
    streams: WebSocketStreams,
): Promise<SessionAttemptResult> => {
    const state = createSessionStateForAttempt();
    const initResult = await consumeSessionInit(client, streams, state, debugEnabled);
    if (!isErr(initResult)) return { retry: false, result: ok({ streams, state }) };

    wsCloseStreams(streams);
    if (shouldRetrySessionInit(attempt, INITIAL_SESSION_RETRY_LIMIT, initResult.error.message)) {
        return { retry: true, error: initResult.error };
    }
    return { retry: false, result: err(initResult.error) };
};

const consumeSessionInit = async (
    client: Client,
    streams: WebSocketStreams,
    state: SessionState,
    debugEnabled: boolean | undefined,
): Promise<Result<void>> => {
    const iterator = initializeSession(client, streams.ws, state, debugEnabled)[Symbol.asyncIterator]();
    return consumeSessionInitIterator(iterator);
};

const consumeSessionInitIterator = async (iterator: AsyncIterator<Result<ASRResponse>>): Promise<Result<void>> => {
    const next = await iterator.next();
    if (next.done) return ok(undefined);
    if (isErr(next.value)) return err(next.value.error);
    return consumeSessionInitIterator(iterator);
};

const readParsedResponse = async (
    ws: WebSocket,
    timeoutMs: number,
): Promise<Result<ASRResponse>> => {
    const responseResult = await tryAsyncResult(() => waitForResponse(ws, timeoutMs));
    if (isErr(responseResult)) return err(responseResult.error);

    const parsedResult = parseResponse(new Uint8Array(responseResult.value));
    if (isErr(parsedResult)) return err(parsedResult.error);

    return parsedResult;
};

// 文件识别，返回最终文本
export const transcribe = async (
    client: Client,
    audio: AudioSource,
    options?: {
        onInterim?: (text: string) => void;
    },
): Promise<Result<string>> => {
    return consumeTranscribeResponses(transcribeStream(client, audio), options?.onInterim, "");
};

const consumeTranscribeResponses = async (
    responses: AsyncIterable<Result<ASRResponse>>,
    onInterim: ((text: string) => void) | undefined,
    finalText: string,
): Promise<Result<string>> => {
    const iterator = responses[Symbol.asyncIterator]();
    return consumeTranscribeResponseIterator(iterator, onInterim, finalText);
};

const consumeTranscribeResponseIterator = async (
    iterator: AsyncIterator<Result<ASRResponse>>,
    onInterim: ((text: string) => void) | undefined,
    finalText: string,
): Promise<Result<string>> => {
    const next = await iterator.next();
    if (next.done) return ok<string>(finalText);
    if (isErr(next.value)) return err(next.value.error);
    const handled = handleTranscribeResponse(next.value.value, onInterim, finalText);
    if (isErr(handled)) return err(handled.error);
    return consumeTranscribeResponseIterator(iterator, onInterim, handled.value);
};

const handleTranscribeResponse = (
    response: ASRResponse,
    onInterim: ((text: string) => void) | undefined,
    finalText: string,
): Result<string> => {
    if (response.type === ResponseType.INTERIM_RESULT) {
        onInterim?.(response.text || "");
        return ok(finalText);
    }
    if (response.type === ResponseType.FINAL_RESULT) return ok(response.text || "");
    if (response.type === ResponseType.ERROR) return err(new Error(response.error_msg || "ASR Error"));
    return ok(finalText);
};

// 实时识别别名
export const transcribeRealtime = (
    client: Client,
    audioSource: AsyncIterable<Uint8Array>,
    options?: { debugEnabled?: boolean },
) => transcribeStream(client, audioSource, options);

export const formatSenderSummary = (frameCount: number, byteCount: number): string => {
    return `sender frames=${frameCount} bytes=${byteCount}`;
};

// =============
// 调试音频保存
// =============

const DEBUG_AUDIO_PATH = "/tmp/asr-debug.pcm";

const openDebugAudioFile = (): { file: any; path: string } => {
    printTimedDomain("doubao", `debug audio -> ${DEBUG_AUDIO_PATH}`);
    return { file: Bun.file(DEBUG_AUDIO_PATH).writer(), path: DEBUG_AUDIO_PATH };
};

const writeDebugAudio = (debugFile: { file: any; path: string }, chunk: Uint8Array): void => {
    ignoreError(() => debugFile.file.write(chunk));
};

const closeDebugAudioFile = (debugFile: { file: any; path: string }): void => {
    ignoreError(() => debugFile.file.end());
    printTimedDomain("doubao", `debug audio saved (play: ffplay -f s16le -ar 16000 -ac 1 ${debugFile.path})`);
};

// 发送任务实现
export const runSender = async (
    client: Client,
    writer: WritableStreamDefaultWriter<Uint8Array>,
    audioStream: AsyncIterable<Uint8Array>,
    state: SessionState,
    realtime?: boolean,
    debugEnabled?: boolean,
): Promise<Result<void>> => {
    const frameBytes = Math.floor((client.config.sampleRate * client.config.frameDurationMs) / 1000) * 2;
    const frameInterval = client.config.frameDurationMs;
    const senderState = { frameCount: 0, byteCount: 0 };
    const debugFile = debugEnabled ? openDebugAudioFile() : null;
    const audioResult = await sendAudioStream(client, writer, audioStream[Symbol.asyncIterator](), state, senderState, frameBytes, frameInterval, realtime, debugFile);
    if (isErr(audioResult)) return err(audioResult.error);

    if (debugFile) closeDebugAudioFile(debugFile);

    // 确保所有帧已刷新后再发送结束帧
    await writer.ready;
    const tokenResult = getToken(client.config);
    if (isErr(tokenResult)) return err(tokenResult.error);
    const token = tokenResult.value;
    const finishResult = await tryAsyncResult(() => writer.write(buildFinishSession(state.requestId, token)));
    if (isErr(finishResult)) return err(finishResult.error);

    if (debugEnabled) printTimedDomain("doubao", formatSenderSummary(senderState.frameCount, senderState.byteCount));
    return await tryAsyncResult(() => writer.close());
};

const sendAudioStream = async (
    client: Client,
    writer: WritableStreamDefaultWriter<Uint8Array>,
    iterator: AsyncIterator<Uint8Array>,
    sessionState: SessionState,
    senderState: { frameCount: number; byteCount: number },
    frameBytes: number,
    frameInterval: number,
    realtime: boolean | undefined,
    debugFile: ReturnType<typeof openDebugAudioFile> | null,
): Promise<Result<void>> => {
    const next = await iterator.next();
    if (next.done) return ok(undefined);
    const chunkResult = await sendAudioChunk(client, writer, next.value, sessionState, senderState, frameBytes, frameInterval, realtime, debugFile);
    if (isErr(chunkResult)) return err(chunkResult.error);
    return sendAudioStream(client, writer, iterator, sessionState, senderState, frameBytes, frameInterval, realtime, debugFile);
};

const sendAudioChunk = async (
    _client: Client,
    writer: WritableStreamDefaultWriter<Uint8Array>,
    chunk: Uint8Array,
    sessionState: SessionState,
    senderState: { frameCount: number; byteCount: number },
    frameBytes: number,
    frameInterval: number,
    realtime: boolean | undefined,
    debugFile: ReturnType<typeof openDebugAudioFile> | null,
): Promise<Result<void>> => {
    senderState.byteCount += chunk.length;
    if (debugFile) writeDebugAudio(debugFile, chunk);
    const frames = createAudioFrames(chunk, frameBytes);
    return sendAudioFrames(writer, frames, sessionState, senderState, frameInterval, realtime, 0);
};

const createAudioFrames = (chunk: Uint8Array, frameBytes: number): Uint8Array[] => {
    const frameCount = Math.ceil(chunk.length / frameBytes);
    return Array.from({ length: frameCount }, (_, index) => sliceOrPad(chunk, index * frameBytes, frameBytes));
};

const sendAudioFrames = async (
    writer: WritableStreamDefaultWriter<Uint8Array>,
    frames: Uint8Array[],
    sessionState: SessionState,
    senderState: { frameCount: number; byteCount: number },
    frameInterval: number,
    realtime: boolean | undefined,
    index: number,
): Promise<Result<void>> => {
    if (index >= frames.length) return ok(undefined);
    const frameResult = await sendAudioFrame(writer, frames[index]!, sessionState, senderState, frameInterval, realtime);
    if (isErr(frameResult)) return err(frameResult.error);
    return sendAudioFrames(writer, frames, sessionState, senderState, frameInterval, realtime, index + 1);
};

const sendAudioFrame = async (
    writer: WritableStreamDefaultWriter<Uint8Array>,
    frame: Uint8Array,
    sessionState: SessionState,
    senderState: { frameCount: number; byteCount: number },
    frameInterval: number,
    realtime: boolean | undefined,
): Promise<Result<void>> => {
    const frameState = senderState.frameCount === 0 ? FrameState.FRAME_STATE_FIRST : FrameState.FRAME_STATE_MIDDLE;
    await writer.ready;
    const writeResult = await tryAsyncResult(() => writer.write(buildAsrRequest(frame, sessionState.requestId, frameState, Date.now())));
    if (isErr(writeResult)) return err(writeResult.error);
    senderState.frameCount++;
    if (realtime) await sleep(frameInterval);
    return ok(undefined);
};

// 辅助：切片或补零
// 建立 WebSocket 连接
export const connectStreams = async (client: Client): Promise<Result<WebSocketStreams>> => {
    const wsUrlResult = getWsUrl(client.config);
    if (isErr(wsUrlResult)) return err(wsUrlResult.error);

    const wsUrl = wsUrlResult.value;

    if (!isWsUrlSecure(wsUrl)) {
        return err(new Error(`Insecure WebSocket URL rejected: ${wsUrl}`));
    }
    const wsInit = buildWebSocketInit(getHeaders(client.config));
    // Bun WebSocket constructor accepts headers via the second argument
    // eslint-disable-next-line @typescript-eslint/no-explicit-any
    const ws = new WebSocket(wsUrl, wsInit as any);
    let connectTimer: ReturnType<typeof setTimeout> | null = null;
    let cleaned = false;
    let onError: ((event: Event) => void) | null = null;
    const cleanup = (): void => {
        if (cleaned) return;
        cleaned = true;
        if (connectTimer !== null) {
            clearTimeout(connectTimer);
            connectTimer = null;
        }
        ws.onopen = null;
        if (onError) {
            ws.removeEventListener("error", onError);
            onError = null;
        }
    };

    const connectResult = await tryAsyncResult(() => new Promise<void>((resolve, reject) => {
        connectTimer = setTimeout(() => {
            cleanup();
            reject(new Error(`WebSocket connection timeout after ${WEBSOCKET_CONNECT_TIMEOUT_MS}ms`));
        }, WEBSOCKET_CONNECT_TIMEOUT_MS);

        onError = (e: Event) => {
            cleanup();
            const error = (e as Event & { error?: unknown }).error;
            reject(normalizeWsError(error));
        };
        ws.onopen = () => {
            cleanup();
            resolve();
        };
        ws.addEventListener("error", onError);
    }).finally(() => {
        cleanup();
    }));
    if (isErr(connectResult)) {
        ignoreError(() => ws.close());
        return err(connectResult.error);
    }

    return ok(createWebSocketStreams(ws));
};

// 初始化会话
export const initializeSession = async function* (
    client: Client,
    ws: WebSocket,
    state: SessionState,
    debugEnabled?: boolean,
): AsyncGenerator<Result<ASRResponse>, void, unknown> {
    const tokenResult = getToken(client.config);
    if (isErr(tokenResult)) {
        yield err(tokenResult.error);
        return;
    }
    const token = tokenResult.value;

    ws.send(buildStartTask(state.requestId, token));
    const startTaskResult = await readParsedResponse(ws, INITIAL_SESSION_RESPONSE_TIMEOUT_MS);
    if (isErr(startTaskResult)) {
        logDoubaoError(debugEnabled, startTaskResult.error.message);
        yield err(startTaskResult.error);
        return;
    }
    if (startTaskResult.value.type === ResponseType.ERROR) {
        logDoubaoError(debugEnabled, startTaskResult.value.error_msg || "Unknown error");
        yield err(new Error(`StartTask 失败: ${startTaskResult.value.error_msg}`));
        return;
    }
    yield ok(startTaskResult.value);

    const sessionConfigResult = getSessionConfig(client.config);
    if (isErr(sessionConfigResult)) {
        ws.send(buildFinishTask(state.requestId, token));
        yield err(sessionConfigResult.error);
        return;
    }
    const sessionConfig = sessionConfigResult.value;
    sessionConfig.audio_info.format = "pcm";

    ws.send(buildStartSession(state.requestId, token, sessionConfig));
    const startSessionResult = await readParsedResponse(ws, INITIAL_SESSION_RESPONSE_TIMEOUT_MS);
    if (isErr(startSessionResult)) {
        logDoubaoError(debugEnabled, startSessionResult.error.message);
        ws.send(buildFinishTask(state.requestId, token));
        yield err(startSessionResult.error);
        return;
    }
    if (startSessionResult.value.type === ResponseType.ERROR) {
        logDoubaoError(debugEnabled, startSessionResult.value.error_msg || "Unknown error");
        ws.send(buildFinishTask(state.requestId, token));
        yield err(new Error(`StartSession 失败: ${startSessionResult.value.error_msg}`));
        return;
    }
    yield ok(startSessionResult.value);
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
    const ensureResult = await ensureCredentials(client.config);
    if (isErr(ensureResult)) return err(ensureResult.error);

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
    const ensureResult = await ensureCredentials(client.config);
    if (isErr(ensureResult)) {
        yield err(ensureResult.error);
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
    const ensureResult = await ensureCredentials(client.config);
    if (isErr(ensureResult)) {
        yield err(ensureResult.error);
        return;
    }
    yield* transcribeStream(client, audioSource);
};

export {
    buildWebSocketInit,
    createSessionRetryDelayMs,
    isRetryableSessionInitError,
    isWsUrlSecure,
    normalizeWsError,
    shouldRetrySessionInit,
    sliceOrPad,
    waitForResponse,
} from "./client-helpers.ts";

export { ResponseType, FrameState };
